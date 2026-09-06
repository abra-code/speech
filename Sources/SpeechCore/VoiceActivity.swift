// VoiceActivity.swift - where speech starts and stops, according to the audio.
//
// Every live row in this program already decides where one utterance ends, and
// not one of them decides it from the audio. Apple's analyzer finalizes on its
// own schedule; `SlidingWindowAsrManager` finalizes when a window closes, which
// is every eleven seconds whatever the speaker is doing; and the two cache-aware
// managers plus the `ggml` rows hand over a transcript that only grows, so
// `StreamSegmentAccumulator` cuts it at what looks like the end of a sentence
// and estimates the time by interpolating a character position into a span.
//
// So the same recording produces different boundaries on every row, the times
// on those boundaries are estimates, and `--refine` re-transcribes a span the
// model chose rather than one the audio did. Measured on one 53.7-second
// utterance, that costs seven seconds: a missed sentence boundary holds finished
// text until the 15-second backstop fires.
//
// A voice activity detector answers the question directly, and it is the only
// component here that can, because it is the only one that looks at the audio
// without trying to read it. This file is the seam: the shape of an answer, the
// shape of something that produces answers, and the one piece of arithmetic
// that has to be right for the answers to mean anything - the clock.
//
// Nothing here detects anything. The implementation is `SileroVad` in
// SpeechFluid, because the model is FluidAudio's; the protocol lives in
// SpeechCore because the live path that consumes boundaries does.

import Foundation

/// One thing the audio said about itself.
///
/// The time is seconds since the stream began, on the same clock a live
/// session's segments are stamped with - so a boundary can be compared against
/// how much audio an engine has committed. Both clocks start when capture does,
/// and keeping them in step is the detector's obligation, not the caller's:
/// see `SampleChunker` for the one place it can go wrong.
public struct SpeechBoundary: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case start
        case end
    }

    public var kind: Kind
    public var seconds: Double

    public init(kind: Kind, seconds: Double) {
        self.kind = kind
        self.seconds = seconds
    }
}

/// Something that watches canonical audio and reports where speech begins and
/// ends.
///
/// Deliberately an observer and nothing more. It is never on the path the audio
/// takes to an engine, so a detector that is wrong, slow or missing changes
/// where a transcript is cut and can never change what the transcript says.
/// That is worth stating as a rule rather than as an accident of the current
/// wiring, because the alternative - gating the engine's audio on the detector -
/// is the obvious next idea and it would put every word at the mercy of a
/// second model.
public protocol VoiceActivityDetector: Sendable {
    /// Hand over the next samples, canonical 16 kHz mono, in capture order.
    ///
    /// Returns the boundaries these samples completed, which is usually none:
    /// a detector reports an ending only once enough silence has followed it to
    /// be sure, so the answer arrives later than the time it carries.
    func detect(_ samples: [Float]) async throws -> [SpeechBoundary]

    /// Forget the stream - the clock, the model's state and any audio held back
    /// for the next chunk. Keeps the weights loaded for the next session.
    func reset() async
}

/// An engine row that detects speech rather than transcribing it.
///
/// A refinement of `TranscriptionEngine` instead of a type of its own, because
/// the row is downloaded, measured, listed and deleted exactly like a model -
/// it has a catalog id, a directory in the store and a completeness check - and
/// only its output is different. `speech models` therefore needs no case for it,
/// and the one caller that wants boundaries asks the engine it already built
/// whether it can produce them.
public protocol VoiceActivityEngine: TranscriptionEngine {
    /// Load the weights and open a detector over them.
    ///
    /// Throws `.modelMissing` when the row is not installed, the same as
    /// `prepare` does on a transcriber, so an uninstalled detector costs a
    /// download instruction rather than a failure inside the first buffer.
    func makeDetector(progress: @escaping LoadProgressHandler) async throws
        -> any VoiceActivityDetector
}

public enum VoiceActivity {
    /// The row a caller that wants boundaries asks the registry for.
    ///
    /// One row rather than a choice: the model is 1.1 MB and language
    /// independent, so a second one would be a decision with nothing on either
    /// side of it. It sits here rather than in the CLI for the same reason the
    /// catalog does - the id is a fact about this build, not about one verb -
    /// and the lookup still goes through the registry, so a build without the
    /// `fluid` engines reports it as unavailable rather than crashing.
    public static let defaultRow = "fluid.silero-vad"
}

/// Cuts a stream of arbitrary buffers into fixed-size chunks, keeping what is
/// left over for the next call.
///
/// It exists because a voice activity model takes one fixed window and nothing
/// else, while a microphone delivers whatever the hardware chose - 4096 frames
/// at 48 kHz is 1365 canonical samples, which divides into no chunk size at all.
/// The library this program uses does accept a short chunk, and that is the
/// trap: it pads the audio to the window with a repeat of the last sample and
/// then advances its clock by the length it was *handed*, so feeding ragged
/// buffers silently mixes real audio with padding and reports timestamps for a
/// stream that was never played. Feeding only whole chunks is what makes the
/// detector's clock the same clock as the session's.
///
/// The cost of that rule is one chunk of latency at the end of a stream: the
/// tail that never filled a window is dropped rather than padded. Nothing is
/// lost by it, because the end of a stream closes every open segment anyway.
public struct SampleChunker {
    /// Samples in a whole chunk. Always positive.
    public let size: Int

    /// Audio that arrived but has not filled a chunk. Strictly shorter than
    /// `size`, which is the invariant the drain below maintains.
    private var residual: [Float] = []

    /// - Parameter size: clamped to at least one. A zero here would be a
    ///   divide-by-nothing loop rather than a diagnosable error, and this is a
    ///   value type with no other way to report one.
    public init(size: Int) {
        self.size = max(1, size)
    }

    /// Samples held back, waiting for the rest of their chunk.
    public var pendingSamples: Int { residual.count }

    /// Fold `samples` in and return every whole chunk they completed.
    ///
    /// Written to be linear in the input rather than obvious: the residual is
    /// filled and emptied at most once per call, and the rest of the buffer is
    /// sliced in place. The version that appended everything to one array and
    /// then took chunks off its front with `removeFirst` was quadratic in the
    /// buffer length, which is exactly the defect the batch path of the
    /// streaming rows shipped with.
    public mutating func take(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        var chunks: [[Float]] = []
        var offset = 0

        if !residual.isEmpty {
            let needed = size - residual.count
            guard samples.count >= needed else {
                residual.append(contentsOf: samples)
                return []
            }
            residual.append(contentsOf: samples[..<needed])
            chunks.append(residual)
            residual.removeAll(keepingCapacity: true)
            offset = needed
        }

        while samples.count - offset >= size {
            chunks.append(Array(samples[offset..<(offset + size)]))
            offset += size
        }
        if offset < samples.count {
            residual.append(contentsOf: samples[offset...])
        }
        return chunks
    }

    /// Drop the held-back audio. The clock belongs to whoever counts chunks, so
    /// this resets nothing else.
    public mutating func reset() {
        residual.removeAll(keepingCapacity: true)
    }
}
