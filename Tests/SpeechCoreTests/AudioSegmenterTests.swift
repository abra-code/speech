import Foundation
import Testing

@testable import SpeechCore

@Suite("Audio segmentation")
struct AudioSegmenterTests {
    /// Silence with speech-shaped noise everywhere except a gap at `quietAt`.
    static func audio(seconds: Double, quietAt: [Double] = [], gap: Double = 0.4) -> [Float] {
        let rate = AudioDecoder.sampleRate
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        var generator = SystemRandomNumberGenerator()
        for index in samples.indices {
            samples[index] = Float.random(in: -0.5...0.5, using: &generator)
        }
        for center in quietAt {
            let from = max(0, Int((center - gap / 2) * rate))
            let to = min(samples.count, Int((center + gap / 2) * rate))
            for index in from..<to { samples[index] = 0 }
        }
        return samples
    }

    /// The contract the rest of the program relies on: ordered, non-overlapping,
    /// and covering every sample. A segmenter that drops audio drops words, and
    /// nothing downstream would notice.
    static func check(_ ranges: [SampleRange], cover count: Int, cap: Double) {
        #expect(ranges.first?.start == 0)
        #expect(ranges.last?.end == count)
        // Emptiness is checked over every range, not over `zip`'s pairs: zipping
        // with `dropFirst()` never visits the last range, and the whole loop is
        // vacuous when there is only one - which is the case in most of these
        // tests, so the assertion was passing without ever running.
        for range in ranges {
            #expect(range.count > 0, "no empty range")
        }
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            #expect(a.end == b.start, "ranges must be contiguous")
        }
        if cap.isFinite {
            let maxSamples = Int(cap * AudioDecoder.sampleRate)
            for range in ranges {
                #expect(range.count <= maxSamples, "range longer than the cap")
            }
        }
    }

    @Test("audio under the cap comes back as one range")
    func shortAudioIsOneRange() async throws {
        let samples = Self.audio(seconds: 5)
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 30)
        #expect(ranges.count == 1)
        Self.check(ranges, cover: samples.count, cap: 30)
    }

    @Test("a long file is cut into pieces that cover all of it")
    func longAudioIsCovered() async throws {
        let samples = Self.audio(seconds: 65)
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        #expect(ranges.count >= 4)
        Self.check(ranges, cover: samples.count, cap: 20)
    }

    @Test("the cut lands in the quiet gap, not at the ceiling")
    func cutsAtSilence() async throws {
        // A gap at 18 s, a 20 s cap, and a 3 s search window: the quiet moment
        // is inside the window, so the cut should find it rather than falling
        // through to 20 s.
        let samples = Self.audio(seconds: 40, quietAt: [18.0])
        let ranges = try await EnergySegmenter(searchSeconds: 3).split(
            samples: samples, maxSeconds: 20)
        let firstCut = try #require(ranges.first).endSeconds
        #expect(abs(firstCut - 18.0) < 0.25, "cut at \(firstCut)s, expected about 18s")
        Self.check(ranges, cover: samples.count, cap: 20)
    }

    @Test("continuous sound still terminates, cutting at the ceiling")
    func noSilenceStillTerminates() async throws {
        let samples = Self.audio(seconds: 50)
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 10)
        Self.check(ranges, cover: samples.count, cap: 10)
    }

    /// `maxAudioMs == 0` is how the library says "no practical limit", and it
    /// reaches the segmenter as a non-positive cap. Looping forever on it would
    /// hang every unbounded model in the catalog.
    @Test("a zero or infinite cap means one range, not an infinite loop")
    func unboundedCap() async throws {
        let samples = Self.audio(seconds: 12)
        for cap in [0.0, -1.0, Double.infinity] {
            let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: cap)
            #expect(ranges.count == 1)
            #expect(ranges.first?.end == samples.count)
        }
    }

    @Test("empty audio produces no ranges")
    func emptyAudio() async throws {
        let ranges = try await EnergySegmenter().split(samples: [], maxSeconds: 10)
        #expect(ranges.isEmpty)
    }

    /// A cap short enough that the search window would otherwise swallow the
    /// whole piece. Without the clamp on `searchSamples` the chosen cut can
    /// land at or before the start of the range and the loop never advances.
    @Test("a cap smaller than the search window still makes progress")
    func tinyCap() async throws {
        let samples = Self.audio(seconds: 20)
        let ranges = try await EnergySegmenter(searchSeconds: 30).split(
            samples: samples, maxSeconds: 1)
        Self.check(ranges, cover: samples.count, cap: 1)
    }

    /// `maxAudioMs` is an Int64 straight out of GGUF metadata. A model using
    /// Int64.max as its "no limit" sentinel makes `maxSeconds * rate` about
    /// 1.5e20, and `Int(_:)` traps rather than saturating - a crash in
    /// `speech transcribe` on a file it could have transcribed.
    @Test("an absurd cap saturates instead of trapping")
    func absurdCapDoesNotTrap() async throws {
        let samples = Self.audio(seconds: 3)
        let cap = Double(Int64.max) / 1000
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: cap)
        #expect(ranges.count == 1)
        #expect(ranges.first?.end == samples.count)

        // The public knobs are the caller's to set, so they get the same
        // treatment as the model-supplied one.
        let wild = try await EnergySegmenter(searchSeconds: 1e300, frameSeconds: 1e300)
            .split(samples: Self.audio(seconds: 20), maxSeconds: 5)
        Self.check(wild, cover: Int(20 * AudioDecoder.sampleRate), cap: 5)
    }

    /// Noise everywhere except the given gaps, each (center, length) in seconds.
    static func audio(seconds: Double, gaps: [(center: Double, length: Double)]) -> [Float] {
        var samples = audio(seconds: seconds)
        let rate = AudioDecoder.sampleRate
        for gap in gaps {
            let from = max(0, Int((gap.center - gap.length / 2) * rate))
            let to = min(samples.count, Int((gap.center + gap.length / 2) * rate))
            for index in from..<to { samples[index] = 0 }
        }
        return samples
    }

    @Test("a sentence pause wins over a quieter dip nearer the cap")
    func sentencePauseBeatsADip() async throws {
        // The old cutter looked at the last 3 s only and took the quietest
        // 20 ms there: the dip at 19.5 s, mid-word, over the pause at 12 s.
        let samples = Self.audio(seconds: 40, gaps: [(12, 0.6), (19.5, 0.03)])
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        let firstCut = try #require(ranges.first).endSeconds
        #expect(abs(firstCut - 12) < 0.1, "cut at \(firstCut)s, expected the pause at 12s")
        Self.check(ranges, cover: samples.count, cap: 20)
    }

    @Test("of two sentence pauses, the later one: the longest piece")
    func laterSentencePause() async throws {
        let samples = Self.audio(seconds: 40, gaps: [(11, 0.7), (17, 0.6)])
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        let firstCut = try #require(ranges.first).endSeconds
        #expect(abs(firstCut - 17) < 0.1, "cut at \(firstCut)s, expected 17s")
    }

    @Test("a sentence pause wins over a later phrase pause")
    func sentenceBeforePhrase() async throws {
        let samples = Self.audio(seconds: 40, gaps: [(13, 0.6), (18, 0.25)])
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        let firstCut = try #require(ranges.first).endSeconds
        #expect(abs(firstCut - 13) < 0.1, "cut at \(firstCut)s, expected 13s")
    }

    @Test("with no pause long enough, the longest quiet run")
    func longestShortRun() async throws {
        let samples = Self.audio(seconds: 40, gaps: [(14, 0.15), (18, 0.06)])
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        let firstCut = try #require(ranges.first).endSeconds
        #expect(abs(firstCut - 14) < 0.1, "cut at \(firstCut)s, expected 14s")
    }

    @Test("no cut nearer the start than half the cap")
    func pauseTooEarlyIsIgnored() async throws {
        // A pause at 6 s is outside the default window (10 to 20 s), so the
        // cut is somewhere later rather than a 6 s piece.
        let samples = Self.audio(seconds: 40, gaps: [(6, 1.0)])
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        let firstCut = try #require(ranges.first).endSeconds
        #expect(firstCut >= 10, "cut at \(firstCut)s")
        Self.check(ranges, cover: samples.count, cap: 20)
    }

    @Test("the last piece is never a second long")
    func noTinyTail() async throws {
        // 21 s at a 20 s cap, with a pause at 19.5 s: cutting there leaves
        // 1.5 s, the shape that came back as "Okay." The pause at 15 s leaves
        // 6 s.
        let samples = Self.audio(seconds: 21, gaps: [(15, 0.6), (19.5, 0.6)])
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        #expect(ranges.count == 2)
        let last = try #require(ranges.last)
        #expect(last.endSeconds - last.startSeconds >= 3, "a last piece of \(last.endSeconds - last.startSeconds)s")
        #expect(abs(last.startSeconds - 15) < 0.1)
        Self.check(ranges, cover: samples.count, cap: 20)
    }

    @Test("a noisy recording's pauses are found at its floor")
    func noisyFloor() async throws {
        // Speech at 0.5 and pauses at 0.05 amplitude: the floor is 20 dB down,
        // short of the 25 dB rule, so the floor rule has to find them.
        var samples = Self.audio(seconds: 40)
        let rate = AudioDecoder.sampleRate
        var generator = SystemRandomNumberGenerator()
        for center in stride(from: 3.0, to: 40.0, by: 3.0) {
            let from = Int((center - 0.35) * rate)
            let to = Int((center + 0.35) * rate)
            for index in from..<to { samples[index] = Float.random(in: -0.05...0.05, using: &generator) }
        }
        let energies = EnergySegmenter.frameEnergies(samples, frame: 320)
        let thresholds = EnergySegmenter.quietThresholds(energies, blockFrames: 25, sideBlocks: 10)
        #expect(EnergySegmenter.quietRuns(energies, thresholds: thresholds).count >= 10)
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        let firstCut = try #require(ranges.first).endSeconds
        #expect(abs(firstCut - 18) < 0.1, "cut at \(firstCut)s, expected the pause at 18s")
    }

    @Test("all silence has no threshold and still cuts")
    func silentRecording() async throws {
        let samples = [Float](repeating: 0, count: Int(50 * AudioDecoder.sampleRate))
        #expect(EnergySegmenter.quietThreshold(EnergySegmenter.frameEnergies(samples, frame: 320)) == nil)
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        Self.check(ranges, cover: samples.count, cap: 20)
    }

    @Test("a recording that is mostly digital silence cuts at the latest silence")
    func mostlyDigitalSilence() async throws {
        // 3.5 s bursts every 8 s, digital zero between: the median frame is 0.
        // Without a threshold the cut fell to the first zero frame in the
        // window, 11.5 s, instead of the silence that reaches the cap.
        let rate = AudioDecoder.sampleRate
        var samples = [Float](repeating: 0, count: Int(60 * rate))
        let noise = Self.audio(seconds: 3.5)
        for burst in stride(from: 0.0, to: 60.0, by: 8.0) {
            let from = Int(burst * rate)
            for (offset, value) in noise.enumerated() where from + offset < samples.count {
                samples[from + offset] = value
            }
        }
        // The zeros are quiet against the speech at the 95th percentile.
        let threshold = try #require(EnergySegmenter.quietThreshold(EnergySegmenter.frameEnergies(samples, frame: 320)))
        #expect(threshold > 0)
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 20)
        let firstCut = try #require(ranges.first).endSeconds
        // The silence from 19.5 s runs past the cap; the cut is in its
        // in-window part.
        #expect(firstCut > 19.5 && firstCut < 20, "cut at \(firstCut)s")
        Self.check(ranges, cover: samples.count, cap: 20)
    }

    /// Noise at `amplitude` from `from` to `to` seconds, overwriting.
    static func speak(_ samples: inout [Float], from: Double, to: Double, amplitude: Float) {
        let rate = AudioDecoder.sampleRate
        var generator = SystemRandomNumberGenerator()
        for index in Int(from * rate)..<min(samples.count, Int(to * rate)) {
            samples[index] = Float.random(in: -amplitude...amplitude, using: &generator)
        }
    }

    /// Syllables at `amplitude` from `from` to `to` seconds: 0.25 s of sound,
    /// then 0.08 s 20 dB down, as speech moves. Steady sound this quiet would
    /// read as one long pause, which is what a quiet steady noise is.
    static func syllables(_ samples: inout [Float], from: Double, to: Double, amplitude: Float) {
        var start = from
        while start < to {
            speak(&samples, from: start, to: min(to, start + 0.25), amplitude: amplitude)
            speak(&samples, from: min(to, start + 0.25), to: min(to, start + 0.33), amplitude: amplitude / 10)
            start += 0.33
        }
    }

    @Test("a quiet speaker after a loud one is speech, not pause")
    func quietSpeaker() async throws {
        // Loud to 12 s, a pause, then a speaker 60 dB down with one pause of
        // their own at 20 s, then loud again from 30 s. Against the whole
        // recording the quiet speaker is all pause, and the cut went to the
        // middle of their speech; against the speech around it, only the real
        // pauses are long enough to cut at.
        var samples = [Float](repeating: 0, count: Int(50 * AudioDecoder.sampleRate))
        Self.syllables(&samples, from: 0, to: 12, amplitude: 0.5)
        Self.syllables(&samples, from: 12.6, to: 20, amplitude: 0.0005)
        Self.syllables(&samples, from: 20.6, to: 29.4, amplitude: 0.0005)
        Self.syllables(&samples, from: 30, to: 50, amplitude: 0.5)
        let energies = EnergySegmenter.frameEnergies(samples, frame: 320)
        let runs = EnergySegmenter.quietRuns(
            energies, thresholds: EnergySegmenter.quietThresholds(energies, blockFrames: 25, sideBlocks: 10))
        // Phrase-length runs (0.2 s and up) are the three real pauses only.
        let middles = runs.filter { $0.length >= 10 }.map { Double($0.start + $0.end) * 0.01 }
        let pauses = [12.3, 20.3, 29.7]
        #expect(middles.count == pauses.count, "pauses at \(middles)")
        for (middle, pause) in zip(middles, pauses) {
            #expect(abs(middle - pause) < 0.1, "pause at \(middle)s, expected \(pause)s")
        }
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 25)
        let firstCut = try #require(ranges.first).endSeconds
        #expect(firstCut > 20 && firstCut < 20.6, "cut at \(firstCut)s, expected the pause at 20s")
        Self.check(ranges, cover: samples.count, cap: 25)
    }

    @Test("a long silence is pause all through")
    func longSilence() async throws {
        // Ten seconds of silence leave no speech on either side of its middle;
        // it is still a pause, not a stretch with nothing to compare.
        var samples = [Float](repeating: 0, count: Int(40 * AudioDecoder.sampleRate))
        Self.speak(&samples, from: 0, to: 10, amplitude: 0.5)
        Self.speak(&samples, from: 25, to: 40, amplitude: 0.5)
        Self.speak(&samples, from: 15, to: 17, amplitude: 0.000_000_1)
        let energies = EnergySegmenter.frameEnergies(samples, frame: 320)
        let thresholds = EnergySegmenter.quietThresholds(energies, blockFrames: 25, sideBlocks: 10)
        let runs = EnergySegmenter.quietRuns(energies, thresholds: thresholds)
        #expect(runs.contains { $0.start <= 500 + 5 && $0.end >= 1250 - 5 }, "\(runs)")
        let ranges = try await EnergySegmenter().split(samples: samples, maxSeconds: 30)
        let firstCut = try #require(ranges.first).endSeconds
        #expect(firstCut > 15 && firstCut < 25, "cut at \(firstCut)s")
    }

    @Test("an unusable context still cuts")
    func wildContext() async throws {
        let samples = Self.audio(seconds: 40, gaps: [(15, 0.6)])
        for context in [0, -1, .nan, .infinity, 1e300] as [Double] {
            let ranges = try await EnergySegmenter(contextSeconds: context).split(samples: samples, maxSeconds: 20)
            Self.check(ranges, cover: samples.count, cap: 20)
        }
    }

    @Test("sample ranges convert to seconds at the decoder's rate")
    func rangeSeconds() {
        let range = SampleRange(start: 16000, end: 48000)
        #expect(range.count == 32000)
        #expect(range.startSeconds == 1.0)
        #expect(range.endSeconds == 3.0)
    }
}
