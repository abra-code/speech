// ParakeetLiveSession.swift - live mode for `fluid.parakeet-v3`.
//
// This is the row live mode needed. The two Apple modules stream, and so do two
// `ggml` families, but between them they cover English plus one row that lost
// to Apple in every language spike 2 measured. Parakeet v3 streams 25 languages
// including Polish, which is the claim the whole product rests on.
//
// FluidAudio's sliding-window manager is a third streaming shape, different
// again from Apple's callback and from transcribe.cpp's committed/tentative
// split, and the difference is worth stating because it is the easiest of the
// three to map: it emits updates that say `isConfirmed`, so `segment.partial`
// and `segment.final` are handed to us rather than inferred. No sentence rule,
// no watermark, no interpolated timings - the window decides, and it decides
// from the audio.
//
// Two things about the library's API drove the code below and neither is
// obvious from its signatures.
//
// `transcriptionUpdates` is a *computed property* that builds a fresh
// `AsyncStream` and overwrites the manager's continuation every time it is
// read. Reading it twice silently orphans the first stream: the reader is still
// there, awaiting a continuation nothing will ever yield to again. It is read
// exactly once, in `make`, and stored.
//
// `SlidingWindowAsrManager` deliberately does not conform to FluidAudio's own
// `StreamingAsrManager` protocol - its own documentation says so, because it
// runs an offline encoder over overlapping windows rather than a cache-aware
// streaming one. So none of the other fluid managers' shapes apply here, and a
// future `fluid.parakeet-unified` live session will not be able to share this
// file's structure.

import AVFoundation
import Foundation
import FluidAudio
import SpeechCore

actor ParakeetLiveSession: LiveSession {
    nonisolated let events: AsyncStream<LiveEvent>
    /// nil: `streamAudio` takes any format and resamples internally, so asking
    /// the pump to convert first would resample the same audio twice.
    nonisolated var preferredFormat: AVAudioFormat? { nil }

    private let manager: SlidingWindowAsrManager
    private let catalogID: String
    private let language: String?
    private let wantWords: Bool
    private let continuation: AsyncStream<LiveEvent>.Continuation

    private var reader: Task<Void, Never>?
    private var readerFinished = false
    private var lastPartialText = ""
    /// The end of the last confirmed window, so a partial has a plausible span
    /// rather than a fabricated one.
    private var lastConfirmedEnd: Double = 0
    /// Seconds of audio handed to the manager. The library reports no clock of
    /// its own for the volatile hypothesis or for `finish()`'s tail, and a
    /// segment with no span at all is worse on the wire than an approximate
    /// one, so this is what those two are dated by.
    private var fedSeconds: Double = 0
    private var lastPollAt: ContinuousClock.Instant?
    private var finals: [Segment] = []
    private var nextID = 0
    private var finishing = false
    private var finished = false

    static func make(
        models: AsrModels,
        catalogID: String,
        language: String?,
        wantWords: Bool
    ) async throws -> ParakeetLiveSession {
        // `.streaming` rather than `.default`: one-second hypothesis chunks and
        // a 0.80 confirmation threshold, against `.default`'s two seconds and
        // 0.85. The difference is how long a word sits volatile before it is
        // confirmed, which is exactly the thing live mode is for.
        var config = SlidingWindowAsrConfig.streaming
        if let hint = FluidLanguage.parakeet(language) {
            // The hint only reaches the v3 joint decoder's script filter. It
            // exists because a streaming window carries far less acoustic
            // context than an offline chunk, which makes the model prone to
            // decoding into the wrong script - the failure this row cannot
            // afford, since its whole argument is the languages Apple lacks.
            config = config.applying(language: hint)
        }
        // Cheap insurance against a future config edit: the assembled window
        // must fit the model's fixed 15-second input, and the library enforces
        // that inside `startStreaming` where the error would arrive after the
        // microphone was already open.
        try config.validate()

        let manager = SlidingWindowAsrManager(config: config)
        do {
            try await manager.loadModels(models)
        } catch {
            throw SpeechError.runtime(
                "cannot start live mode for '\(catalogID)': \(error.localizedDescription)")
        }

        let session = ParakeetLiveSession(
            manager: manager, catalogID: catalogID, language: language, wantWords: wantWords)
        try await session.start()
        return session
    }

    private init(
        manager: SlidingWindowAsrManager, catalogID: String, language: String?, wantWords: Bool
    ) {
        self.manager = manager
        self.catalogID = catalogID
        self.language = language
        self.wantWords = wantWords
        let (events, continuation) = AsyncStream<LiveEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    private func start() async throws {
        // Read the update stream exactly once, and before streaming starts, so
        // no update can be produced before there is somewhere to put it.
        do {
            // `.microphone` is a label on the source, not a request for one:
            // this session never opens a device, it is fed by `LivePump`.
            try await manager.startStreaming(source: .microphone)
        } catch {
            reader?.cancel()
            reader = nil
            finishing = true
            finished = true
            await manager.cancel()
            continuation.finish()
            throw SpeechError.runtime(
                "'\(catalogID)' could not start live analysis: \(error.localizedDescription)")
        }
        let updates = await manager.transcriptionUpdates
        reader = Task { [weak self] in await self?.consume(updates) }
    }

    func feed(_ audio: CapturedAudio) async throws {
        guard !finishing else { return }
        let buffer = audio.buffer
        let seconds = buffer.format.sampleRate > 0
            ? Double(buffer.frameLength) / buffer.format.sampleRate
            : 0
        await manager.streamAudio(buffer)
        fedSeconds += seconds
        await pollVolatile()
    }

    /// Publish the manager's volatile hypothesis as a partial.
    ///
    /// Polled rather than received, because the update stream does not carry
    /// it. Measured on `fluid.parakeet-v3@int8`: unconfirmed updates *are*
    /// yielded, but their `text` is empty every time - the growing hypothesis
    /// lives only in `volatileTranscript`, which is a property. Waiting for a
    /// volatile update to arrive with text in it would mean waiting forever,
    /// and a live mode with no partials is a recorder with a delay.
    /// How often the volatile hypothesis is read.
    ///
    /// Not every buffer. `SlidingWindowAsrManager` is an actor that runs an
    /// *offline* encoder over 15-second windows, so it is busy for long
    /// stretches, and every property read has to wait its turn behind that
    /// work - alongside the `streamAudio` calls that actually matter. Polling
    /// at the 85 ms buffer rate measurably starved the feed: a 20-second
    /// dictation delivered 8.6 seconds of audio and one segment. Four times a
    /// second is faster than a person can read a changing line anyway.
    private static let volatilePollInterval: Duration = .milliseconds(250)

    private func pollVolatile() async {
        let now = ContinuousClock().now
        if let lastPollAt, now - lastPollAt < Self.volatilePollInterval { return }
        lastPollAt = now
        await emitVolatile()
    }

    private func emitVolatile() async {
        guard !finishing else { return }
        let volatileText = await manager.volatileTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !volatileText.isEmpty, volatileText != lastPartialText else { return }
        lastPartialText = volatileText
        emit(
            text: volatileText, words: nil, confidence: nil, isConfirmed: false,
            start: lastConfirmedEnd, end: fedSeconds)
    }

    func finish() async throws -> [Segment] {
        guard !finished else { return finals }
        finishing = true
        var failure: String?
        do {
            // The return value is NOT discarded, and treating it as redundant
            // was a real defect. `finish()` returns what is left *unconfirmed*,
            // not the whole transcript - measured: a four-sentence dictation
            // ended with `finish()` returning only "One to be sure." while
            // `confirmedTranscript` was empty, because confirmed text is
            // drained as it is emitted. Ignoring it silently dropped the last
            // thing the user said, on every run.
            let tail = try await manager.finish()
            let remaining = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                emit(
                    text: remaining, words: nil, confidence: nil, isConfirmed: true,
                    start: lastConfirmedEnd, end: fedSeconds)
            }
        } catch {
            failure = error.localizedDescription
        }
        await joinReader()
        finished = true
        continuation.finish()
        if let failure {
            throw LiveSessionFailure(
                segments: finals,
                message: "'\(catalogID)' could not finish the live stream: \(failure)")
        }
        return finals
    }

    func cancel() async {
        guard !finished else { return }
        finishing = true
        finished = true
        reader?.cancel()
        reader = nil
        await manager.cancel()
        continuation.finish()
    }

    // MARK: - Updates

    private func consume(_ updates: AsyncStream<SlidingWindowTranscriptionUpdate>) async {
        defer { readerFinished = true }
        for await update in updates {
            if Task.isCancelled { return }
            absorb(update)
        }
    }

    private func absorb(_ update: SlidingWindowTranscriptionUpdate) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let words = Self.words(from: update.tokenTimings, wanted: wantWords)
        // The window's own span where it has one. `timestamp` is a wall clock
        // `Date` and says nothing about position in the audio, so it is not a
        // substitute: a segment with no token timings gets the previous
        // segment's end for both bounds rather than a fabricated range.
        let start = words?.first?.start ?? finals.last?.end ?? 0
        let end = max(start, words?.last?.end ?? start)

        emit(
            text: text, words: words, confidence: update.confidence,
            isConfirmed: update.isConfirmed, start: start, end: end)
    }

    /// One place that builds a segment and puts it on the wire, so `finish`'s
    /// tail and a confirmed window cannot number or bound themselves
    /// differently.
    private func emit(
        text: String,
        words: [Word]?,
        confidence: Float?,
        isConfirmed: Bool,
        start: Double? = nil,
        end: Double? = nil
    ) {
        let from = start ?? finals.last?.end ?? 0
        let to = max(from, end ?? from)
        let segment = Segment(
            id: nextID,
            start: from,
            end: to,
            text: text,
            words: words,
            confidence: confidence,
            speaker: nil,
            language: language.map(Language.primarySubtag))
        if isConfirmed {
            finals.append(segment)
            nextID += 1
            lastConfirmedEnd = to
            lastPartialText = ""
            continuation.yield(.final(segment))
        } else {
            continuation.yield(.partial(segment))
        }
    }

    /// Token timings to word timings, through FluidAudio's own grouper.
    ///
    /// The same call the batch path makes, so a word boundary means the same
    /// thing live as it does in an eval run.
    private static func words(from timings: [TokenTiming], wanted: Bool) -> [Word]? {
        guard wanted, !timings.isEmpty else { return nil }
        let built = buildWordTimings(from: timings)
        guard !built.isEmpty else { return nil }
        return built.map { Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }

    /// Waits for the update reader, but not forever.
    ///
    /// Polled rather than raced in a task group, for the reason the Apple
    /// session records: a task group waits for every child before returning, so
    /// racing the reader against a sleep still hangs if the reader ignores
    /// cancellation - which is the failure being defended against.
    private func joinReader() async {
        guard let reader else { return }
        self.reader = nil
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !readerFinished {
            if Task.isCancelled {
                reader.cancel()
                return
            }
            if ContinuousClock().now >= deadline {
                reader.cancel()
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
