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
// `EnergySegmenter`, which needs no weights: it makes each piece as long as the
// cap allows and cuts it at the latest real pause it can find, falling back to
// shorter pauses and then to the quietest moment.
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

/// Makes each piece as long as the cap allows and cuts it at a real pause. No
/// model, no download.
///
/// The cap is the longest piece the engine transcribes without losing accuracy,
/// so a piece should come as close to it as a good cut allows - and a good cut
/// is a pause, because a cut inside a word or a sentence costs words on both
/// sides of it. Every 20 ms frame is scored by mean square amplitude, and a
/// frame is quiet when it is 35 dB below the loud speech around it, the
/// 95th-percentile frame of the `contextSeconds` before it or after it,
/// whichever is quieter (or, where the floor sits above that, within 3 dB of
/// the floor). Then, looking back from the cap over the last `searchSeconds`:
///
///  1. the latest run of quiet frames at least `sentencePauseSeconds` long;
///  2. else the latest one at least `phrasePauseSeconds` long;
///  3. else the longest quiet run there is;
///  4. else the quietest single frame, which in continuous sound degrades to a
///     cut near the window's start.
///
/// A cut lands in the middle of its pause. Until 2026-10-22 this took the
/// quietest single frame in the last 3 s, so a 20 ms dip between syllables
/// beat a half-second pause 3.5 s back, and a recording just over a multiple of
/// the cap ended in a piece of a second or less - which a text decoder answers
/// with words nobody said ("Okay."). The last piece is now never shorter than
/// `minimumTailSeconds`.
///
/// The speech a pause is measured against is local because levels are not
/// constant: a quiet participant can be 40 dB under a loud one. Measured
/// against the whole recording, 4 x 5 minutes of FLEURS English sentences
/// (speech levels from -63 to -14 dB) had its quieter half counted as 86-96%
/// pause, and at a 20 s cap 57 of 68 cuts landed inside a sentence. Against the
/// quieter side, quiet speakers read 11-14% pause, like loud ones, and 48 of 72
/// cuts land between sentences; one-speaker LibriSpeech passages cut the same.
///
/// It deliberately does not try to *detect speech* - it never drops a region
/// for being quiet. Trimming silence is a different job with a different
/// failure mode (a soft speaker transcribed as an empty file), and this type
/// exists only to choose where to cut.
public struct EnergySegmenter: AudioSegmenter {
    /// How far back from the cap a cut may land; nil, the default, is half the
    /// cap, so no piece but the last is shorter than half of it.
    public var searchSeconds: Double?
    /// Width of one scored frame.
    public var frameSeconds: Double
    /// Quiet this long is a pause between sentences, the preferred cut.
    public var sentencePauseSeconds: Double
    /// Quiet this long is a pause between phrases, the next best.
    public var phrasePauseSeconds: Double
    /// The shortest last piece; never more than half the cap.
    public var minimumTailSeconds: Double
    /// How much speech on each side of a frame decides whether it is quiet;
    /// from half a second to a minute.
    public var contextSeconds: Double

    /// The context is measured in blocks of this, not frame by frame.
    static let blockSeconds = 0.5

    public init(
        searchSeconds: Double? = nil, frameSeconds: Double = 0.02,
        sentencePauseSeconds: Double = 0.5, phrasePauseSeconds: Double = 0.2,
        minimumTailSeconds: Double = 3, contextSeconds: Double = 5
    ) {
        self.searchSeconds = searchSeconds
        self.frameSeconds = frameSeconds
        self.sentencePauseSeconds = sentencePauseSeconds
        self.phrasePauseSeconds = phrasePauseSeconds
        self.minimumTailSeconds = minimumTailSeconds
        self.contextSeconds = contextSeconds
    }

    /// A run of quiet frames, `start..<end` in frame indices.
    struct QuietRun: Equatable {
        var start: Int
        var end: Int
        var length: Int { end - start }
    }

    /// Mean square amplitude of each frame; the last one may be partial.
    static func frameEnergies(_ samples: [Float], frame: Int) -> [Double] {
        var energies: [Double] = []
        energies.reserveCapacity(samples.count / frame + 1)
        var frameStart = 0
        while frameStart < samples.count {
            let frameEnd = min(samples.count, frameStart + frame)
            var sum = 0.0
            for index in frameStart..<frameEnd {
                let value = Double(samples[index])
                sum += value * value
            }
            energies.append(sum / Double(frameEnd - frameStart))
            frameStart = frameEnd
        }
        return energies
    }

    /// Loud speech and the floor of some frames: their 95th and 5th
    /// percentiles. Loud speech is the reference, not the median frame: in real
    /// speech the median is a quiet consonant or a gap, about 40 dB under loud
    /// speech (30 FLEURS English clips joined: 5th percentile -85.7 dB, median
    /// -58.9, 95th -18.3).
    static func levels(_ energies: ArraySlice<Double>) -> (speech: Double, floor: Double) {
        let sorted = energies.sorted()
        return (sorted[min(sorted.count - 1, sorted.count * 19 / 20)], sorted[sorted.count / 20])
    }

    /// The energy at or below which a frame counts as a pause, given the
    /// speech and floor it is judged against.
    static func pauseLine(speech: Double, floor: Double) -> Double {
        // 25 dB under the median put the line at -83 dB and found 3 of the 29
        // pauses between those clips; 35 dB under the 95th percentile finds 28.
        let belowSpeech = speech * 0.000_316
        // A noisy recording's pauses sit at its floor, which can be above that.
        // Trusted only when the floor is at least 10 dB under speech: in a
        // stretch with almost no pauses the 5th percentile is quiet speech,
        // and 3 dB above it would mark syllables as pauses.
        if floor < speech * 0.1, floor * 2 > belowSpeech { return floor * 2 }
        return belowSpeech
    }

    /// The whole recording's pause line, or nil when it has no quiet to speak
    /// of (all of it silent). Pauses are judged locally (`quietThresholds`);
    /// this only tells a stretch with no speech in it from a quiet speaker.
    static func quietThreshold(_ energies: [Double]) -> Double? {
        guard let loudest = energies.max(), loudest > 0 else { return nil }
        let (speech, floor) = levels(energies[...])
        // A recording that is mostly digital silence still has speech at its
        // 95th percentile, so its zeros are pauses.
        guard speech > 0 else { return 0 }
        return pauseLine(speech: speech, floor: floor)
    }

    /// The pause line of every frame, judged against the speech on each side
    /// of it - `sideBlocks` blocks of `blockFrames` frames, plus the frame's
    /// own block - and set by the quieter side. Empty when the recording has
    /// no pause line at all.
    static func quietThresholds(_ energies: [Double], blockFrames: Int, sideBlocks: Int) -> [Double] {
        guard let line = quietThreshold(energies) else { return [] }
        let blocks = (energies.count + blockFrames - 1) / blockFrames
        // A side longer than the recording is clipped to it anyway; unclipped,
        // a huge context sorts the whole recording once per block it reaches.
        let sideBlocks = min(sideBlocks, blocks)
        // The speech in blocks first...first + sideBlocks, or nil when there is
        // none: 35 dB under the recording's line (70 dB under its loud speech;
        // FLEURS speakers span 49 dB), which also covers all silent, or so flat
        // (under 10 dB from floor to speech) and quiet (under the recording's
        // line) that it is one long pause: room noise, never speech, whose
        // syllables and word gaps move it more than that. A side without
        // speech cannot set the line; with neither side, all is pause.
        func side(_ first: Int) -> (speech: Double, floor: Double)? {
            let from = max(0, first) * blockFrames
            let to = min(energies.count, (first + sideBlocks + 1) * blockFrames)
            guard from < to else { return nil }
            let (speech, floor) = levels(energies[from..<to])
            if speech <= line * 0.000_316 || (speech < floor * 10 && speech <= line) { return nil }
            return (speech, floor)
        }
        // Index i holds the window starting at block i - sideBlocks: block b's
        // before side is at b, its after side at b + sideBlocks.
        let sides = (-sideBlocks..<blocks).map(side)
        var thresholds = [Double](repeating: 0, count: energies.count)
        for block in 0..<blocks {
            let present = [sides[block], sides[block + sideBlocks]].compactMap { $0 }
            let threshold = present.min { $0.speech < $1.speech }
                .map { pauseLine(speech: $0.speech, floor: $0.floor) } ?? .infinity
            for index in (block * blockFrames)..<min(energies.count, (block + 1) * blockFrames) {
                thresholds[index] = threshold
            }
        }
        return thresholds
    }

    /// Every run of quiet frames in the recording, in order: each frame
    /// against its own threshold, none when there are no thresholds.
    static func quietRuns(_ energies: [Double], thresholds: [Double]) -> [QuietRun] {
        guard thresholds.count == energies.count else { return [] }
        var runs: [QuietRun] = []
        var runStart: Int?
        for (index, energy) in energies.enumerated() {
            if energy <= thresholds[index] {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append(QuietRun(start: start, end: index))
                runStart = nil
            }
        }
        if let start = runStart { runs.append(QuietRun(start: start, end: energies.count)) }
        return runs
    }

    /// The cut for one piece, in samples, inside `window`.
    static func cut(
        in window: Range<Int>, frame: Int, energies: [Double], runs: [QuietRun],
        sentenceFrames: Int, phraseFrames: Int
    ) -> Int {
        func clamped(_ sample: Int) -> Int { min(max(sample, window.lowerBound), window.upperBound - 1) }
        // A run counts by its whole length, even where it reaches past the
        // window: a two-second pause is a sentence break wherever it is cut.
        // Runs are in order and disjoint, so the first one ending past the
        // window's start is found by bisection: a scan from the top for every
        // piece is quadratic in a multi-hour recording.
        var low = 0
        var high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if runs[mid].end * frame > window.lowerBound { high = mid } else { low = mid + 1 }
        }
        let candidates = runs[low...].prefix { $0.start * frame < window.upperBound }
        func middle(_ run: QuietRun) -> Int {
            // Of the part inside the window, so the cut never leaves it.
            let from = max(run.start * frame, window.lowerBound)
            let to = min(run.end * frame, window.upperBound)
            return clamped((from + to) / 2)
        }
        if let run = candidates.last(where: { $0.length >= sentenceFrames }) { return middle(run) }
        if let run = candidates.last(where: { $0.length >= phraseFrames }) { return middle(run) }
        // On a tie the later run: the longer piece.
        if let run = candidates.max(by: { $0.length < $1.length || ($0.length == $1.length && $0.start < $1.start) }) {
            return middle(run)
        }
        // No quiet frame at all. Strictly less keeps the earliest of equally
        // quiet frames.
        var best = window.upperBound - 1
        var bestEnergy = Double.infinity
        var index = (window.lowerBound + frame - 1) / frame
        while (index + 1) * frame <= window.upperBound, index < energies.count {
            if energies[index] < bestEnergy {
                bestEnergy = energies[index]
                best = index * frame + frame / 2
            }
            index += 1
        }
        return clamped(best)
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

        // A frame no wider than half a piece, so a window always holds one.
        let frame = max(1, min(Self.samples(frameSeconds, rate: rate), maxSamples / 2))
        // The search region can never eat the whole piece: a cut at or before
        // `start` would make no progress and loop.
        let searchSamples = min(
            max(frame, searchSeconds.map { Self.samples($0, rate: rate) } ?? maxSamples / 2),
            maxSamples / 2)
        // Never longer than the window either, or the tail rule would shrink
        // the window to nothing and force the cut wherever it ends.
        let tailSamples = min(Self.samples(minimumTailSeconds, rate: rate), maxSamples / 2, searchSamples)
        let sentenceFrames = max(1, Self.samples(sentencePauseSeconds, rate: rate) / frame)
        let phraseFrames = max(1, Self.samples(phrasePauseSeconds, rate: rate) / frame)

        let blockFrames = max(1, Self.samples(Self.blockSeconds, rate: rate) / frame)
        // Clamped before the conversion, which traps on NaN or a huge value.
        // A minute is the most context that means anything for a pause, and
        // sorting each block's window costs its length; infinity is the most.
        let contextBlocks = contextSeconds.isNaN ? 10 : contextSeconds / Self.blockSeconds
        let sideBlocks = Int(min(max(contextBlocks, 1), 120).rounded())

        let energies = Self.frameEnergies(samples, frame: frame)
        let runs = Self.quietRuns(
            energies,
            thresholds: Self.quietThresholds(energies, blockFrames: blockFrames, sideBlocks: sideBlocks))

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
            // Ends early enough that what follows is at least the minimum tail.
            // More than a cap's worth remains here, and the tail is at most
            // half a cap, so the window never closes.
            let windowEnd = min(hardEnd, samples.count - tailSamples)
            let windowStart = max(start + 1, min(hardEnd - searchSamples, windowEnd - 1))
            let chosen = Self.cut(
                in: windowStart..<windowEnd, frame: frame, energies: energies, runs: runs,
                sentenceFrames: sentenceFrames, phraseFrames: phraseFrames)
            let cut = max(start + 1, min(chosen, samples.count))
            ranges.append(SampleRange(start: start, end: cut))
            start = cut
        }
        return ranges
    }
}
