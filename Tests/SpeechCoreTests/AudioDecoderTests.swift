// AudioDecoderTests.swift - the decoder is the other half of the measuring
// instrument. If it resampled wrong, every WER number in the product would be
// measured on audio no engine actually received, and nothing downstream could
// detect it.

import AVFoundation
import Foundation
import Testing
@testable import SpeechCore

@Suite("Audio decoding")
struct AudioDecoderTests {
    @Test("a wav decodes to exactly the expected sample count")
    func wavRoundTrip() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }

        let url = try Fixtures.makeWAV(in: directory, seconds: 3)
        let samples = try await AudioDecoder.decode(url: url)
        // A wav is not resampled, so this is exact rather than within a
        // tolerance: 3 seconds at 16 kHz.
        #expect(samples.count == 48000)

        let duration = try await AudioDecoder.duration(url: url)
        #expect(abs(duration - 3.0) < 0.01)
    }

    @Test("a 44.1 kHz stereo m4a is resampled and downmixed to within one percent")
    func compressedAudio() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }

        let url = try Fixtures.makeM4A(in: directory, seconds: 3)
        let samples = try await AudioDecoder.decode(url: url)
        let expected = 3.0 * AudioDecoder.sampleRate
        // AAC pads with encoder priming, so this is a tolerance rather than an
        // equality. One percent is far tighter than any resampling mistake.
        #expect(abs(Double(samples.count) - expected) / expected < 0.01)
    }

    @Test("a movie with a video track decodes its audio")
    func movieWithVideo() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }

        let url = try await Fixtures.makeMovie(in: directory, seconds: 2)
        let samples = try await AudioDecoder.decode(url: url)
        let expected = 2.0 * AudioDecoder.sampleRate
        #expect(abs(Double(samples.count) - expected) / expected < 0.02)
    }

    @Test("windowed decoding yields the same audio as one-shot decoding")
    func windowing() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }

        let url = try Fixtures.makeWAV(in: directory, seconds: 5)
        let whole = try await AudioDecoder.decode(url: url)

        var windowed: [Float] = []
        var windowCount = 0
        try await AudioDecoder.forEachWindow(url: url, seconds: 1) { window in
            windowCount += 1
            // Every window but the last is exactly the requested size; that is
            // what keeps a long file's memory flat.
            if windowed.count + window.count < whole.count {
                #expect(window.count == 16000)
            }
            windowed.append(contentsOf: window)
        }
        #expect(windowCount == 5)
        #expect(windowed == whole)
    }

    @Test("a slow consumer paces the decoder instead of being buffered ahead of")
    func windowBackPressure() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }

        let url = try Fixtures.makeWAV(in: directory, seconds: 20)

        // The bug this pins: an AsyncStream-based version yields without ever
        // suspending, so the producer runs to EOF while the consumer sleeps and
        // the whole file ends up queued in the continuation's unbounded buffer.
        // With an awaited closure the producer cannot get ahead at all, so by
        // the time the second window is delivered the first is the only one
        // that has been read past.
        var delivered = 0
        var maxOutstanding = 0
        try await AudioDecoder.forEachWindow(url: url, seconds: 1) { window in
            delivered += 1
            maxOutstanding = max(maxOutstanding, window.count)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(delivered == 20)
        // One window's worth of samples is the most that is ever live.
        #expect(maxOutstanding == 16000)
    }

    @Test("writeWAV round-trips the samples it was given")
    func writeRoundTrip() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }

        let original = Fixtures.sineSamples(seconds: 0.5)
        let url = directory.appendingPathComponent("written.wav")
        try AudioDecoder.writeWAV(samples: original, to: url)
        let decoded = try await AudioDecoder.decode(url: url)
        #expect(decoded.count == original.count)
        // Float32 in, Float32 out: the samples must survive exactly, or the
        // Apple engine is being fed something the other engines are not.
        for (a, b) in zip(original, decoded) {
            #expect(abs(a - b) < 1e-6)
        }
    }

    @Test("a missing file and an unsupported container both report why")
    func errors() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }

        await #expect(throws: SpeechError.self) {
            _ = try await AudioDecoder.decode(
                url: directory.appendingPathComponent("absent.wav"))
        }

        // A container AVFoundation will not open. The error must name the
        // extension and say what to do, not just fail.
        let webm = directory.appendingPathComponent("clip.webm")
        try Data("not really a webm".utf8).write(to: webm)
        do {
            _ = try await AudioDecoder.decode(url: webm)
            Issue.record("expected an unsupported-format error")
        } catch let error as SpeechError {
            #expect(error.code == "unsupported_format")
            #expect(error.message.contains("webm"))
        }
    }
}
