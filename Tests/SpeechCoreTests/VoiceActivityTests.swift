// VoiceActivityTests.swift - the one piece of arithmetic between a microphone
// and a voice activity model.
//
// A detector's timestamps are only as good as its clock, and its clock is the
// count of samples it has been handed. FluidAudio's model takes a 4096-sample
// window, accepts a shorter one by padding it with a repeat of the last sample,
// and then advances its clock by the length it was handed rather than by the
// window it processed - so a ragged feed silently produces boundaries for a
// stream nobody played. `SampleChunker` is the guard, and the property worth
// testing is not "it splits an array" but "nothing is lost, nothing is
// reordered, and nothing partial ever leaves it".
//
// The buffer sizes below are the awkward ones on purpose: 1365 is what a
// 4096-frame tap at 48 kHz becomes after conversion to 16 kHz, 1024 is a 64 ms
// buffer, and 4095/4097 straddle the window by one sample in each direction.

import Foundation
import Testing
@testable import SpeechCore

@Suite("Sample chunking for voice activity")
struct VoiceActivityTests {
    /// FluidAudio's window, and the only size this program feeds one.
    private let window = 4096

    /// A ramp, so a misplaced sample is visible rather than merely a count.
    private func ramp(from start: Int, count: Int) -> [Float] {
        (0..<count).map { Float(start + $0) }
    }

    @Test("every chunk is whole, in order, and nothing is dropped")
    func chunksAreWholeAndOrdered() {
        var chunker = SampleChunker(size: window)
        var fed: [Float] = []
        var emitted: [Float] = []

        // Starting with a whole window on an empty chunker is deliberate: it is
        // the case where the residual is empty and the drain has to take the
        // buffer directly. Without it the "fill the residual first" branch
        // handles every chunk and the boundary in the second loop goes untested.
        for count in [4096, 1365, 1024, 4096, 3, 4095, 4097, 1, 8192, 0, 2731] {
            let buffer = ramp(from: fed.count, count: count)
            fed += buffer
            for chunk in chunker.take(buffer) {
                #expect(chunk.count == window, "a short chunk escaped")
                emitted += chunk
            }
            // The invariant that makes the clock trustworthy: what has left the
            // chunker plus what it is still holding is exactly what went in.
            #expect(emitted.count + chunker.pendingSamples == fed.count)
            #expect(chunker.pendingSamples < window)
        }

        // Order and identity, not just totals. A chunker that emitted the right
        // number of samples in the wrong order would pass every count above.
        #expect(emitted == Array(fed.prefix(emitted.count)))
        #expect(emitted.count == (fed.count / window) * window)
    }

    @Test("a buffer shorter than a chunk yields nothing and is kept")
    func shortBuffersAreHeld() {
        var chunker = SampleChunker(size: window)
        #expect(chunker.take(ramp(from: 0, count: 1024)).isEmpty)
        #expect(chunker.take(ramp(from: 1024, count: 1024)).isEmpty)
        #expect(chunker.pendingSamples == 2048)
    }

    @Test("the held-back audio leads the chunk it completes")
    func residualLeadsTheNextChunk() {
        var chunker = SampleChunker(size: window)
        #expect(chunker.take(ramp(from: 0, count: window - 1)).isEmpty)

        // One sample completes the window, and the residual has to come first:
        // a chunker that appended it would hand the model a chunk starting at
        // sample 4095 and still report the same counts.
        let chunks = chunker.take(ramp(from: window - 1, count: 1))
        #expect(chunks.count == 1)
        #expect(chunks.first == ramp(from: 0, count: window))
        #expect(chunker.pendingSamples == 0)
    }

    @Test("one buffer can complete a held chunk and several of its own")
    func oneBufferCanCarryMany() {
        var chunker = SampleChunker(size: window)
        _ = chunker.take(ramp(from: 0, count: 100))
        let chunks = chunker.take(ramp(from: 100, count: 3 * window))
        #expect(chunks.count == 3)
        #expect(chunks[0] == ramp(from: 0, count: window))
        #expect(chunks[1] == ramp(from: window, count: window))
        #expect(chunks[2] == ramp(from: 2 * window, count: window))
        #expect(chunker.pendingSamples == 100)
    }

    @Test("an empty buffer changes nothing")
    func emptyBuffersAreInert() {
        var chunker = SampleChunker(size: window)
        _ = chunker.take(ramp(from: 0, count: 10))
        #expect(chunker.take([]).isEmpty)
        #expect(chunker.pendingSamples == 10)
    }

    @Test("reset drops the held audio and nothing else")
    func resetDropsTheResidual() {
        var chunker = SampleChunker(size: window)
        _ = chunker.take(ramp(from: 0, count: window + 7))
        #expect(chunker.pendingSamples == 7)
        chunker.reset()
        #expect(chunker.pendingSamples == 0)
        // Still usable, and starting from empty rather than from seven samples
        // of the previous session's audio.
        let chunks = chunker.take(ramp(from: 0, count: window))
        #expect(chunks.count == 1)
        #expect(chunks.first == ramp(from: 0, count: window))
    }

    @Test("a size of zero is refused rather than looping forever")
    func sizeIsAtLeastOne() {
        var chunker = SampleChunker(size: 0)
        #expect(chunker.size == 1)
        #expect(chunker.take([1, 2, 3]).count == 3)
    }
}
