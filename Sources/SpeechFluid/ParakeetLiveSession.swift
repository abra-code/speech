// ParakeetLiveSession.swift - live mode for `fluid.parakeet-v3`.
//
// This is the row live mode needed. The two Apple modules stream, and so do two
// `ggml` families, but between them they cover English plus one row that lost
// to Apple in every language spike 2 measured. Parakeet v3 streams 25 languages
// including Polish, which is the claim the whole product rests on.
//
// FluidAudio's `SlidingWindowAsrManager` is a third streaming shape, and the
// first version of this file mapped it wrongly in three separate ways because
// the mapping was inferred from short test utterances. What it actually does,
// read out of the library rather than guessed at:
//
//   1. A window is assembled and decoded once `chunk + right` seconds of audio
//      have arrived - 13 s with the config here - and once every `chunk`
//      seconds (11 s) after that. Nothing is emitted before the first one.
//   2. Each window's tokens are deduplicated against everything decoded so far,
//      and the update carries the text of ONLY the new tokens. Updates are
//      therefore non-overlapping, append-only pieces of one transcript, and no
//      piece is ever revised.
//   3. `isConfirmed` on an update is not about that update. It says the
//      PREVIOUS piece has been promoted out of the manager's volatile slot. A
//      piece marked unconfirmed is not provisional text - it is the same
//      never-revised piece, arriving before the manager is willing to settle
//      its predecessor.
//
// So every update becomes a `segment.final`, and this row emits no partials at
// all. That is a real and uncomfortable property worth stating plainly rather
// than dressing up: on this row, live means a block of text roughly every 11
// seconds, with nothing for the first 13. Apple's rows and the ggml rows both
// give word-by-word feedback; this one gives languages instead.
//
// The three corrections the first version needed, each of which was a defect:
//
// `finish()` returns the WHOLE transcript, not a remainder - it rebuilds text
// from every accumulated token. Emitting its return value as a trailing segment
// duplicated the entire session's text on any run past 13 seconds. It is called
// for its flush and its return value is deliberately discarded.
//
// Unconfirmed updates carry text, and `volatileTranscript` is assigned that
// same string. Polling the property could therefore never learn anything the
// update stream had not already delivered, and it published the previous
// segment's text under the next segment's id. The poll is gone, along with the
// per-buffer actor round trip that was blamed for starving the feed.
//
// `finish()` does not close the update stream; only `cancel()` does. Without a
// `cancel()` after it, the reader parks forever and the join below burns its
// whole deadline on every single run.
//
// One thing the first version got right, and it is still the sharpest edge in
// the file: `transcriptionUpdates` is a computed property that builds a fresh
// `AsyncStream` and overwrites the manager's continuation every time it is
// read. Reading it twice silently orphans the first stream - the reader is
// still there, awaiting a continuation nothing will ever yield to again. It is
// read exactly once, in `start`, and before `startStreaming`, so there is no
// interval in which a window could be decoded with nowhere to put it.

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
    private let continuation: AsyncStream<LiveEvent>.Continuation

    private var reader: Task<Void, Never>?
    private var readerFinished = false
    /// The mapping, in a plain struct so it can be tested without four
    /// compiled CoreML models. See `SlidingWindowSegments`.
    private var segments: SlidingWindowSegments
    private var finishing = false
    private var finished = false
    /// Kept so a second `finish()` rethrows rather than reporting a clean run.
    private var failure: String?

    static func make(
        models: AsrModels,
        catalogID: String,
        language: String?,
        wantWords: Bool
    ) async throws -> ParakeetLiveSession {
        // `.streaming` rather than `.default`, and the difference is one knob:
        // a confirmation threshold of 0.80 against 0.85. (`.streaming` also
        // sets `hypothesisChunkSeconds` to 1.0, but nothing in the manager
        // reads it - it is exposed as `hypothesisChunkSamples` and used
        // nowhere.) Since every update becomes a final here, the threshold
        // changes only when the manager promotes its own volatile slot, which
        // this session does not read. The lower value is kept because it is
        // what the library calls the streaming configuration, not because it
        // has been measured to matter.
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
        self.segments = SlidingWindowSegments(language: language, wantWords: wantWords)
        let (events, continuation) = AsyncStream<LiveEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    private func start() async throws {
        // Read the update stream first, and exactly once. Until this property
        // is read the manager's continuation is nil and a yielded update goes
        // nowhere, so doing it after `startStreaming` would leave a window -
        // small, but real - in which a decoded chunk is silently discarded.
        let updates = await manager.transcriptionUpdates
        reader = Task { [weak self] in await self?.consume(updates) }
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
    }

    func feed(_ audio: CapturedAudio) async throws {
        guard !finishing else { return }
        await manager.streamAudio(audio.buffer)
    }

    func finish() async throws -> [Segment] {
        // `finishing`, not `finished`: the flush below is the longest await in
        // the file - it decodes the last window - and a second `finish()`
        // arriving inside it would run the whole teardown concurrently with the
        // first, flushing twice.
        guard !finishing else {
            if let failure {
                throw LiveSessionFailure(
                    segments: segments.finals,
                    message: "'\(catalogID)' could not finish the live stream: \(failure)")
            }
            return segments.finals
        }
        finishing = true

        do {
            // Called for its side effect and NOT for its return value, which is
            // the whole transcript rather than a remainder. What matters here
            // is that it ends the input stream, which makes the recognizer task
            // flush the audio left over below one window's worth - and that
            // flush is yielded as an ordinary update, so it reaches the wire
            // through the same path every other window does.
            _ = try await manager.finish()
        } catch {
            failure = error.localizedDescription
        }
        // The library closes the update stream only in `cancel()`, never in
        // `finish()`. Without this the reader is parked on a continuation that
        // will never yield again and the join below waits out its full
        // deadline on every run. Buffered updates survive it: an `AsyncStream`
        // iterator drains what is already in the buffer before it ends.
        await manager.cancel()
        await joinReader()

        finished = true
        continuation.finish()
        if let failure {
            throw LiveSessionFailure(
                segments: segments.finals,
                message: "'\(catalogID)' could not finish the live stream: \(failure)")
        }
        return segments.finals
    }

    func cancel() async {
        // Both flags. `finish()` sets `finishing` and then suspends for the
        // length of a window decode; a `cancel()` landing in that gap would
        // close the event stream underneath it, so the flush window would reach
        // the returned array and never reach the wire. `GGMLLiveSession` guards
        // the same way for the same reason.
        guard !finished, !finishing else { return }
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
            absorb(update)
        }
    }

    /// One update, one event on the wire.
    ///
    /// Which event it is belongs to `SlidingWindowSegments` rather than to this
    /// line, and deliberately: it is the whole mapping, it was wrong once, and
    /// a decision made here is a decision no test can reach.
    private func absorb(_ update: SlidingWindowTranscriptionUpdate) {
        guard let event = segments.absorb(update) else { return }
        continuation.yield(event)
    }

    /// Waits for the update reader, but not forever.
    ///
    /// Polled rather than raced in a task group, for the reason the Apple
    /// session records: a task group waits for every child before returning, so
    /// racing the reader against a sleep still hangs if the reader ignores
    /// cancellation - which is the failure being defended against.
    ///
    /// A timeout here is recorded as a failure rather than swallowed. It means
    /// the last window or two never reached the transcript, and a silent
    /// version of this would look exactly like a slow shutdown.
    private func joinReader() async {
        guard let reader else { return }
        self.reader = nil
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !readerFinished {
            // Cancellation first. Once this task is canceled `Task.sleep`
            // throws instantly and `try?` swallows it, so without this the loop
            // stops sleeping and spins a core for the rest of the deadline.
            if Task.isCancelled {
                reader.cancel()
                return
            }
            if ContinuousClock().now >= deadline {
                reader.cancel()
                failure = failure ?? "the transcription updates did not end within 5 s"
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
