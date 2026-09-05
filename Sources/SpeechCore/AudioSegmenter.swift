// AudioSegmenter.swift - how a long file is cut up for an engine that cannot
// swallow it whole.
//
// Several ggml families declare a hard ceiling on one run's audio
// (`capabilities.maxAudioMs`): Qwen3-ASR, Canary, Cohere, Voxtral, Granite.
// Past it the library throws `inputTooLong` rather than degrading, so an hour
// of audio needs to arrive as pieces and the transcripts stitched back with
// their timestamps offset.
//
// The seam is a protocol because the good answer and the available answer are
// different things. The good answer is a voice-activity model that cuts only in
// real silence; stage 4 needs one anyway for live mode, and when it exists it
// conforms to this protocol and gets injected. The available answer today is
// `EnergySegmenter`, which needs no weights: it looks for the quietest moment
// inside a window near the cap and cuts there.
//
// The plan assumed stage 1 had left a Silero VAD behind to borrow. It had not -
// FluidAudio's `VadManager` exists but nothing in this program has ever loaded
// it, and doing so is a CoreML download and a catalog row of its own. Making a
// `ggml` row depend on a `fluid` model download to transcribe a long file is a
// worse trade than cutting at a local energy minimum, so that is deferred to
// the stage that needs the model for its own sake.

import Foundation

/// A half-open range of sample indices, `start..<end`.
public struct SampleRange: Sendable, Equatable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var count: Int { max(0, end - start) }

    /// Seconds from the start of the media, at the decoder's rate.
    public var startSeconds: Double { Double(start) / AudioDecoder.sampleRate }
    public var endSeconds: Double { Double(end) / AudioDecoder.sampleRate }
}

/// Splits decoded audio into pieces an engine can accept one at a time.
public protocol AudioSegmenter: Sendable {
    /// Ranges covering all of `samples`, none longer than `maxSeconds`.
    ///
    /// Contract: the ranges are in order, non-overlapping, and together cover
    /// every sample - a segmenter that drops audio drops words, and nothing
    /// downstream would ever notice. Audio already under the cap comes back as
    /// a single range.
    func split(samples: [Float], maxSeconds: Double) async throws -> [SampleRange]
}

/// Cuts at the quietest point near the ceiling. No model, no download.
///
/// For each piece it walks back from the cap over the last `searchSeconds` of
/// the allowed span, scores every short frame by mean square amplitude, and
/// cuts at the lowest-scoring one. In speech that lands in a pause between
/// words almost every time; in continuous sound it degrades to a cut at the
/// cap, which is what a naive splitter would have done anyway.
///
/// It deliberately does not try to *detect speech* - it never drops a region
/// for being quiet. Trimming silence is a different job with a different
/// failure mode (a soft speaker transcribed as an empty file), and this type
/// exists only to choose where to cut.
public struct EnergySegmenter: AudioSegmenter {
    /// How far back from the cap to look for a quiet moment.
    public var searchSeconds: Double
    /// Width of one scored frame.
    public var frameSeconds: Double

    public init(searchSeconds: Double = 3.0, frameSeconds: Double = 0.02) {
        self.searchSeconds = searchSeconds
        self.frameSeconds = frameSeconds
    }

    /// Seconds to a sample count, saturating instead of trapping.
    ///
    /// `Int(_:)` on a `Double` traps when the value does not fit, and every
    /// operand here is either a public `var` on this type or a number read out
    /// of a model file, so none of them is this code's to trust.
    static func samples(_ seconds: Double, rate: Double) -> Int {
        let product = seconds * rate
        guard product.isFinite, product > 0 else { return 0 }
        return Int(min(product, Double(Int.max / 2)))
    }

    public func split(samples: [Float], maxSeconds: Double) async throws -> [SampleRange] {
        let rate = AudioDecoder.sampleRate
        guard !samples.isEmpty else { return [] }
        // A non-positive or unusable cap means "no limit"; returning one range
        // is right and is also what stops a zero cap from looping forever.
        guard maxSeconds > 0, maxSeconds.isFinite else {
            return [SampleRange(start: 0, end: samples.count)]
        }
        // Clamped before the conversion, not after. `maxAudioMs` is an Int64
        // read straight out of GGUF metadata, and a model that used Int64.max
        // as its "no limit" sentinel - a perfectly plausible alternative to the
        // 0 this code documents - makes `maxSeconds * rate` about 1.5e20, which
        // `Int(_:)` does not saturate but traps on. That is a crash in
        // `speech transcribe` on a file it could have transcribed.
        let maxSamples = max(1, Self.samples(maxSeconds, rate: rate))
        if samples.count <= maxSamples {
            return [SampleRange(start: 0, end: samples.count)]
        }

        let frame = max(1, Self.samples(frameSeconds, rate: rate))
        // The search region can never eat the whole piece: a cut at or before
        // `start` would make no progress and loop.
        let searchSamples = min(max(frame, Self.samples(searchSeconds, rate: rate)), maxSamples / 2)

        var ranges: [SampleRange] = []
        var start = 0
        while start < samples.count {
            // Cheap, and the only suspension point on a path that can scan a
            // multi-hour file's worth of search windows before the first range
            // is ever handed to an engine.
            try Task.checkCancellation()
            let hardEnd = start + maxSamples
            if hardEnd >= samples.count {
                ranges.append(SampleRange(start: start, end: samples.count))
                break
            }
            let searchStart = hardEnd - searchSamples
            var bestCut = hardEnd
            var bestEnergy = Double.infinity
            var frameStart = searchStart
            while frameStart + frame <= hardEnd {
                var sum = 0.0
                for index in frameStart..<(frameStart + frame) {
                    let value = Double(samples[index])
                    sum += value * value
                }
                let energy = sum / Double(frame)
                // Strictly less: on a run of equally quiet frames this keeps the
                // earliest, which biases the cut toward the start of a pause
                // rather than the moment speech resumes.
                if energy < bestEnergy {
                    bestEnergy = energy
                    // Cut in the middle of the quiet frame, not at its edge.
                    bestCut = frameStart + frame / 2
                }
                frameStart += frame
            }
            let cut = max(start + 1, min(bestCut, samples.count))
            ranges.append(SampleRange(start: start, end: cut))
            start = cut
        }
        return ranges
    }
}
