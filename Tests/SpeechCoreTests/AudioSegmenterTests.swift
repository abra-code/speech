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

    @Test("sample ranges convert to seconds at the decoder's rate")
    func rangeSeconds() {
        let range = SampleRange(start: 16000, end: 48000)
        #expect(range.count == 32000)
        #expect(range.startSeconds == 1.0)
        #expect(range.endSeconds == 3.0)
    }
}
