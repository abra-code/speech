// FluidStreamingSession.swift - live mode for the `fluid` rows whose managers
// are cache-aware streaming ones.
//
// Two row families land here: `fluid.nemotron-multilingual` and the four
// `fluid.parakeet-unified@stream-<ms>` tiers, whose streaming encoder is a
// separate download from the offline row's. The shape is the last of the four
// this program has to speak: hand over audio, and the manager grows a
// transcript. There is no result callback worth using (the library's
// partial callback delivers the same whole transcript a poll returns), no
// utterance boundary, and no revision - the encoder carries its own cache
// forward, so a token, once decoded, is settled.
//
// That makes the mapping a two-part job, and each part lives where it can be
// tested: `FluidStreamingSegments` decides where one segment ends, and the
// backends below say what the manager has decoded. This file is the lifecycle
// and nothing else, which is the shape `GGMLLiveSession` settled on.
//
// **`finish()` returns the whole transcript on both of these managers, not a
// remainder.** That is the defect that cost `fluid.parakeet-v3` a WER of 105%
// on its first commit, and the third manager in a row to work this way: it is
// a property of the library, not an accident of one class. Its return value is
// therefore the authoritative last poll rather than a segment to append, which
// is exactly how a poll is treated on every other call.
//
// The audio is decoded inside `feed`, deliberately. The alternative - yielding
// into a stream the manager reads on its own task - is what
// `ParakeetLiveSession` has to do, and it makes the session's bounded queue
// structurally unable to drop: `droppedInputCount` there is always zero, so an
// encoder that fell behind would grow memory instead of dropping and warning.
// Decoding in `feed` puts the backpressure back where the pump can see it.

import AVFoundation
import FluidAudio
import Foundation
import SpeechCore

/// What one poll of a streaming manager reported.
struct FluidStreamingPoll: Sendable {
    /// Everything decoded so far, by the library's own tokenizer. Never a
    /// delta, and never re-joined from `words` - see the header of
    /// `FluidStreamingSegments` for why the text has to come from here.
    let transcript: String
    /// The same tokens grouped into words, on the audio's clock. Cumulative,
    /// because the last word is still growing and a delta would publish it
    /// truncated.
    let words: [Word]
}

/// One streaming manager, behind the two calls a session makes of it.
protocol FluidStreamingBackend: Sendable {
    /// Hand over 16 kHz mono samples and decode whatever chunks they complete.
    ///
    /// Returns nil when nothing was decoded, which is what stops the session
    /// publishing a partial identical to the last one. How much that saves
    /// differs by backend and neither is free: the Nemotron manager re-decodes
    /// every accumulated token id on each poll, so its backend gates on a chunk
    /// watermark as well; the Unified one appends to a transcript cache, so its
    /// backend can ask the honest question - did this call decode anything -
    /// and pay only a scan.
    func feed(_ samples: [Float]) async throws -> FluidStreamingPoll?
    /// Flush the remainder and report the transcript one last time.
    func flush() async throws -> FluidStreamingPoll
    /// Drop decoding state, keeping the models loaded for the next session.
    func reset() async
}

actor FluidStreamingSession: LiveSession {
    nonisolated let events: AsyncStream<LiveEvent>
    /// Canonical, unlike the sliding-window row's nil. These backends are fed
    /// `[Float]` directly, so the samples have to be at 16 kHz mono by the time
    /// they arrive; asking the pump for that costs one conversion, which is the
    /// same one the manager's own resampler would do a moment later.
    nonisolated var preferredFormat: AVAudioFormat? { LiveAudioFormat.canonical }

    private let backend: any FluidStreamingBackend
    private let catalogID: String
    private let continuation: AsyncStream<LiveEvent>.Continuation

    private var segments: FluidStreamingSegments
    /// Audio handed over, in seconds. What a partial claims to end at.
    private var fedSeconds: Double = 0
    private var finishing = false
    private var finished = false
    /// Kept so a second `finish()` rethrows rather than reporting a clean run.
    private var failure: String?

    init(
        backend: any FluidStreamingBackend,
        catalogID: String,
        language: String?,
        wantWords: Bool
    ) {
        self.backend = backend
        self.catalogID = catalogID
        self.segments = FluidStreamingSegments(language: language, wantWords: wantWords)
        let (events, continuation) = AsyncStream<LiveEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func feed(_ audio: CapturedAudio) async throws {
        guard !finishing else { return }
        let samples = LiveAudioFormat.samples(audio.buffer)
        guard !samples.isEmpty else { return }
        fedSeconds += Double(samples.count) / AudioDecoder.sampleRate

        let poll: FluidStreamingPoll?
        do {
            poll = try await backend.feed(samples)
        } catch {
            throw SpeechError.runtime(
                "'\(catalogID)' live feed failed: \(error.localizedDescription)")
        }
        // Checked again on the far side of the await. `feed` suspends for the
        // length of a chunk decode, and a `finish()` landing in that gap
        // publishes the final and closes the continuation - so publishing here
        // would append a segment to `finals` that no reader ever saw, and a
        // second `finish()` would return a transcript disagreeing with the
        // events. Nothing is lost by dropping the poll: these managers return
        // the whole transcript from `finish()`, so the flush already carries
        // whatever this decode produced.
        guard let poll, !finishing else { return }
        publish(poll, isFinal: false)
    }

    func finish() async throws -> [Segment] {
        // `finishing` rather than `finished`, because the flush below decodes
        // the last chunk and a second call arriving inside it would flush
        // twice. The same guard the two sibling sessions use.
        guard !finishing else {
            if let failure { throw failed(failure) }
            return segments.finals
        }
        finishing = true

        do {
            publish(try await backend.flush(), isFinal: true)
        } catch {
            failure = error.localizedDescription
        }
        // Whether or not the flush worked. The engine keeps these managers
        // across sessions, and one left holding a dead session's decoder state
        // would carry it into the next transcript.
        await backend.reset()

        finished = true
        continuation.finish()
        if let failure { throw failed(failure) }
        return segments.finals
    }

    func cancel() async {
        // Both flags: `finish()` sets `finishing` and then suspends for the
        // length of a chunk decode, and a `cancel()` landing in that gap would
        // close the event stream underneath it - so the flush would reach the
        // returned array and never reach the wire.
        guard !finished, !finishing else { return }
        finishing = true
        finished = true
        await backend.reset()
        continuation.finish()
    }

    // MARK: - Mapping

    private func publish(_ poll: FluidStreamingPoll, isFinal: Bool) {
        let events = segments.absorb(
            transcript: poll.transcript,
            words: poll.words,
            receivedSeconds: fedSeconds,
            isFinal: isFinal)
        for event in events { continuation.yield(event) }
    }

    /// The transcript travels with the failure. A session that produced forty
    /// segments and then stumbled on its last flush has forty segments.
    private func failed(_ message: String) -> LiveSessionFailure {
        LiveSessionFailure(
            segments: segments.finals,
            message: "'\(catalogID)' could not finish the live stream: \(message)")
    }
}
