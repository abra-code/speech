// AppleLiveSession.swift - `speech stream --model apple.transcriber|apple.dictation`.
//
// SpeechAnalyzer's live shape is a push sequence: you hand it an
// `AsyncStream<AnalyzerInput>` up front, then yield buffers into it for as long
// as the microphone runs, and close the stream to finish. The results arrive on
// a separate async sequence that has to be read from the moment analysis
// starts - it is not replayed, so a consumer attached late loses the first
// words of the session.
//
// Two Apple-specific facts shape everything here.
//
// The audio format is not ours to choose. `bestAvailableAudioFormat` names one
// per module set, and `AnalyzerInput` will not take anything else - which is
// exactly why `LiveSession` grew `preferredFormat` rather than each session
// resampling for itself.
//
// Volatile results are revisions, not additions. Apple emits a growing volatile
// hypothesis and then one final result covering the same span. Numbering
// therefore advances on finals only, and every volatile result carries the id
// the next final will have: that is the contract `segment.refined` relies on,
// and it is what lets a transcript view overwrite a row instead of appending.

import AVFoundation
import Foundation
import SpeechCore

#if canImport(Speech)
import Speech

@available(macOS 26, *)
actor AppleLiveSession: LiveSession {
    nonisolated let events: AsyncStream<LiveEvent>
    /// Whatever `SpeechAnalyzer` said it wants. Never nil in practice; nil
    /// would mean Apple named no format for these modules, and the microphone
    /// would then feed hardware buffers that `AnalyzerInput` rejects, so the
    /// session refuses to be built in that case rather than failing per buffer.
    nonisolated let preferredFormat: AVAudioFormat?

    private let continuation: AsyncStream<LiveEvent>.Continuation
    private let module: any SpeechModule
    private let analyzer: SpeechAnalyzer
    private let inputs: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let languageTag: String
    private nonisolated let kind: AppleEngineKind

    private var reader: Task<Void, Never>?
    private var finals: [Segment] = []
    private var nextID = 0
    private var failure: String?
    /// Set the moment `finish` begins, so `feed` stops accepting audio.
    private var finishing = false
    /// Set by `consume` on its way out, so `joinReader` can wait on something
    /// bounded rather than on the reader task itself.
    private var readerFinished = false
    /// How many buffers the analyzer may fall behind by. At Apple's live format
    /// this is several seconds - long enough to ride out a hiccup, short enough
    /// that a stall is bounded.
    private static let inputQueueDepth = 64
    /// Buffers the analyzer never got, reported once at the end.
    private var droppedInputs = 0
    /// Set once the session is really over. Kept separate from `finishing`
    /// because `finish` has two long awaits in it, and a `cancel` arriving
    /// during either of them has to be able to interrupt - a single flag would
    /// make `cancel` a no-op exactly when it is most needed.
    private var finished = false

    /// Builds and starts the analyzer. Async because both the format lookup and
    /// `start(inputSequence:)` are, and because a session that has not started
    /// analyzing would silently swallow the first buffers fed to it.
    static func make(
        module: any SpeechModule,
        kind: AppleEngineKind,
        locale: Locale,
        context: AnalysisContext?
    ) async throws -> AppleLiveSession {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        else {
            throw SpeechError.unavailable(
                "\(kind.displayName) names no live audio format on this system")
        }
        let session = AppleLiveSession(module: module, kind: kind, locale: locale, format: format)
        try await session.start(context: context)
        return session
    }

    private init(
        module: any SpeechModule, kind: AppleEngineKind, locale: Locale, format: AVAudioFormat
    ) {
        self.module = module
        self.preferredFormat = format
        self.languageTag = locale.identifier
        self.analyzer = SpeechAnalyzer(modules: [module])

        let (events, eventContinuation) = AsyncStream<LiveEvent>.makeStream()
        self.events = events
        self.continuation = eventContinuation

        // Bounded, for the same reason the tap-to-pump hop is: `feed` yields
        // and returns without waiting for the analyzer, so an analyzer that has
        // stalled would otherwise grow this queue without limit - each entry
        // retaining an `AVAudioPCMBuffer`, at 230 MB an hour. Dropping the
        // oldest keeps the session responsive to what is being said now, which
        // is the only thing a live transcript can still be right about.
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.inputQueueDepth))
        self.inputContinuation = inputContinuation
        self.inputs = inputs
        self.kind = kind
    }

    private func start(context: AnalysisContext?) async throws {
        // Read before analyze, for the same reason the batch path does: the
        // results sequence has no history, and a short first utterance can be
        // over before a reader attached afterward sees anything.
        reader = Task { [weak self] in await self?.consume() }
        do {
            if let context { try await analyzer.setContext(context) }
            try await analyzer.start(inputSequence: inputs)
        } catch {
            // Tear the whole thing down, not just the reader. An abandoned
            // input stream leaves the analyzer waiting on audio that will never
            // arrive, and a live `AsyncStream` that is never finished is a
            // consumer parked forever.
            finishing = true
            finished = true
            reader?.cancel()
            reader = nil
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            continuation.finish()
            throw SpeechError.runtime(
                "\(kind.displayName) could not start live analysis: \(error.localizedDescription)")
        }
    }

    func feed(_ audio: CapturedAudio) async throws {
        guard !finishing else { return }
        if case .dropped = inputContinuation.yield(AnalyzerInput(buffer: audio.buffer)) {
            droppedInputs += 1
        }
    }

    func droppedInputCount() async -> Int { droppedInputs }

    func finish() async throws -> [Segment] {
        // On `finishing`, not `finished`: `finished` is only set after two long
        // awaits, so guarding on it would let a second call run the whole
        // teardown concurrently with the first.
        guard !finishing else { return finals }
        finishing = true
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            failure = failure ?? error.localizedDescription
        }
        await joinReader()
        finished = true
        continuation.finish()
        if let failure {
            // With the segments, not instead of them. See `LiveSessionFailure`.
            throw LiveSessionFailure(
                segments: finals,
                message: "\(kind.displayName) live session failed: \(failure)")
        }
        return finals
    }

    func cancel() async {
        guard !finished else { return }
        finishing = true
        finished = true
        inputContinuation.finish()
        reader?.cancel()
        reader = nil
        await analyzer.cancelAndFinishNow()
        continuation.finish()
    }

    /// Waits for the results reader, but not forever.
    ///
    /// `transcriber.results` is expected to end when the analyzer finishes, and
    /// normally does within milliseconds. It is not guaranteed to: a
    /// `finalizeAndFinishThroughEndOfInput()` that already threw can leave the
    /// sequence open, and an unbounded await there would hang the whole
    /// shutdown - `finish` never returns, the caller's event pump is never
    /// joined, and `done` is never emitted.
    ///
    /// Polled rather than raced in a task group, and that is the point: a task
    /// group waits for *every* child before it returns, so racing `reader.value`
    /// against a sleep still hangs if the reader ignores cancellation - which is
    /// exactly the failure being defended against. Watching a flag the reader
    /// sets on its way out is bounded whatever the reader does.
    private func joinReader() async {
        guard let reader else { return }
        self.reader = nil
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !readerFinished {
            // Cancellation first. Once this task is cancelled `Task.sleep`
            // throws instantly and `try?` swallows it, so without this the loop
            // stops sleeping and spins a core for the rest of the deadline.
            if Task.isCancelled {
                reader.cancel()
                return
            }
            if ContinuousClock().now >= deadline {
                reader.cancel()
                failure = failure ?? "the results stream did not end within 5 s"
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Results

    private func consume() async {
        defer { readerFinished = true }
        do {
            switch kind {
            case .transcriber:
                guard let transcriber = module as? SpeechTranscriber else { return }
                for try await result in transcriber.results {
                    handle(text: result.text, range: result.range, isFinal: result.isFinal)
                }
            case .dictation:
                guard let transcriber = module as? DictationTranscriber else { return }
                for try await result in transcriber.results {
                    handle(text: result.text, range: result.range, isFinal: result.isFinal)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            record(failure: error.localizedDescription)
        }
    }

    private func handle(text: AttributedString, range: CMTimeRange, isFinal: Bool) {
        let segment = AppleResults.segment(
            id: nextID, text: text, range: range, language: languageTag)
        guard !segment.text.isEmpty else { return }
        if isFinal {
            finals.append(segment)
            nextID += 1
            continuation.yield(.final(segment))
        } else {
            continuation.yield(.partial(segment))
        }
    }

    private func record(failure message: String) {
        guard self.failure == nil else { return }
        self.failure = message
    }
}

#endif
