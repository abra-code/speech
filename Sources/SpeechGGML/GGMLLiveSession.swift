// GGMLLiveSession.swift - live mode for the `ggml` rows that can stream.
//
// transcribe.cpp's streaming shape is different from Apple's and from
// FluidAudio's, and the difference is the whole design of this file. There is
// no result callback and no utterance boundary. There is one growing hypothesis
// split into two parts: `committed`, which is append-only and will not change,
// and `tentative`, the volatile suffix that will. Every `feed` returns the
// current split plus how much audio has been committed so far.
//
// That maps cleanly onto `segment.partial` - the tentative text is exactly what
// a partial is - and not at all onto `segment.final`, because the library never
// says "that was an utterance". Commits arrive in whatever chunks the decoder's
// stable-prefix logic produces, which is a few words at a time. Emitting one
// final per commit would produce dozens of two-word segments a minute, each of
// which `--refine` would then hand to a large model with no context to work
// from, which is the opposite of what refinement is for.
//
// So commits accumulate and a segment closes on sentence-ending punctuation, or
// at a duration cap, or at the end of the stream. Both streaming rows here emit
// punctuation, so in practice the punctuation rule is what fires. **Stage 4.3
// replaces this with voice activity detection**, which is the real answer:
// utterance boundaries belong to the audio, not to the text.

import AVFoundation
import Foundation
import SpeechCore
import TranscribeCpp

actor GGMLLiveSession: LiveSession {
    nonisolated let events: AsyncStream<LiveEvent>
    /// ggml wants the project's canonical format and nothing else, which is
    /// also what every batch measurement was taken on.
    nonisolated var preferredFormat: AVAudioFormat? { LiveAudioFormat.canonical }

    private let session: GGMLSession
    private let catalogID: String
    private let language: String?
    private let continuation: AsyncStream<LiveEvent>.Continuation

    /// The segment state machine. Extracted so it can be tested without a
    /// 750 MB GGUF and a Metal device; see `StreamSegmentAccumulator`.
    private var accumulator: StreamSegmentAccumulator
    private var finals: [SpeechCore.Segment] { accumulator.finals }
    private var finishing = false
    private var finished = false
    /// Kept so a repeated `finish()` reports the same failure.
    private var failure: LiveSessionFailure?

    static func make(
        session: GGMLSession,
        catalogID: String,
        language: String?,
        runOptions: RunOptions,
        streamExtension: StreamExtension?,
        segmentation: LiveSegmentation = .engine
    ) async throws -> GGMLLiveSession {
        let live = GGMLLiveSession(
            session: session, catalogID: catalogID, language: language,
            segmentation: segmentation)
        // `.auto` lets the family pick its own commit policy. Overriding it
        // here would mean this file claiming to know better than the decoder
        // about when a prefix is stable, which it does not.
        try await session.beginStream(
            run: runOptions,
            options: StreamOptions(commitPolicy: .auto, family: streamExtension))
        return live
    }

    private init(
        session: GGMLSession,
        catalogID: String,
        language: String?,
        segmentation: LiveSegmentation
    ) {
        self.session = session
        self.catalogID = catalogID
        self.language = language
        self.accumulator = StreamSegmentAccumulator(
            language: language, segmentation: segmentation)
        let (events, continuation) = AsyncStream<LiveEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func feed(_ audio: CapturedAudio) async throws {
        guard !finishing else { return }
        let samples = LiveAudioFormat.samples(audio.buffer)
        guard !samples.isEmpty else { return }
        let step: GGMLSession.StreamStep
        do {
            step = try await session.feedStream(samples)
        } catch let error as TranscribeError {
            // Through the engine's describer: `TranscribeError` interpolates as
            // "The operation couldn't be completed. (error 0.)", which tells
            // nobody anything.
            throw SpeechError.runtime(
                "'\(catalogID)' live feed failed: \(GGMLEngine.describe(error))")
        }
        absorb(step, isFinal: false)
    }

    /// This engine never says where an utterance ended - there is one growing
    /// hypothesis and nothing else - so its cuts are invented from the text.
    /// A measured boundary is exactly what that rule was standing in for.
    func mark(_ boundary: SpeechBoundary) async {
        guard !finishing else { return }
        accumulator.mark(boundary)
    }

    nonisolated var honorsSpeechBoundaries: Bool { true }

    func finish() async throws -> [SpeechCore.Segment] {
        if finished {
            // Report the failure every time rather than once. A caller that
            // retries after a `LiveSessionFailure` would otherwise get a clean
            // return and conclude the transcript was complete.
            if let failure { throw failure }
            return finals
        }
        finishing = true
        defer {
            finished = true
            continuation.finish()
        }
        let step: GGMLSession.StreamStep
        do {
            step = try await session.finalizeStream()
        } catch {
            // The stream is over either way; what was already committed is a
            // real transcript and must not be thrown away with the error.
            await session.resetStream()
            let message = (error as? SpeechError)?.message ?? "\(error)"
            let recorded = LiveSessionFailure(
                segments: finals,
                message: "'\(catalogID)' could not finalize the live stream: \(message)")
            failure = recorded
            throw recorded
        }
        absorb(step, isFinal: true)
        return finals
    }

    func cancel() async {
        // `finishing` too, not only `finished`: `finish` sets `finishing` and
        // then suspends on `finalizeStream`, and a `cancel` landing in that
        // window used to finish the event continuation underneath it - so the
        // last segment reached the returned array but never reached the wire,
        // and the two disagreed.
        guard !finished, !finishing else { return }
        finishing = true
        finished = true
        await session.resetStream()
        continuation.finish()
    }

    // MARK: - Mapping

    private func absorb(_ step: GGMLSession.StreamStep, isFinal: Bool) {
        let events = accumulator.absorb(
            committed: step.text.committed,
            tentative: step.text.tentative,
            committedMs: step.update.audioCommittedMs,
            receivedMs: step.update.inputReceivedMs,
            isFinal: isFinal)
        for event in events { continuation.yield(event) }
    }
}
