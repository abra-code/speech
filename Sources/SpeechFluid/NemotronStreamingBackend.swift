// NemotronStreamingBackend.swift - `fluid.nemotron-multilingual` behind the
// streaming-session protocol.
//
// This row's manager is the one this engine already loads for batch work, so
// live mode here really is the wiring job the capability record promised: no
// second download, no second set of weights, no second ANE compile. The batch
// path calls `process(samples:)` with a whole file and then
// `finishWithTokenTimings()`; live calls the same two, in the same order, with
// the file arriving 64 milliseconds at a time.
//
// What the manager does with that audio, read from the v0.15.6 source rather
// than inferred:
//
//   - `process(samples:)` appends to an internal buffer and decodes every whole
//     `chunkSamples` chunk it can. The chunk is the row's variant: 2240 ms,
//     1120 ms or 560 ms, and it is the entire latency story for this row.
//   - `getPartialTranscript()` decodes every accumulated token id into text.
//     Not a delta - the whole transcript, every time - which is why this file
//     only calls it when a chunk was actually consumed.
//   - `getTokenTimings()` returns per-token absolute seconds, lang-tag tokens
//     excluded and the SentencePiece boundary marker preserved, which is
//     exactly what `buildWordTimings` groups on.
//   - `finish()` returns THE WHOLE TRANSCRIPT and clears the accumulators. The
//     third manager in this library to do that and the second to be documented
//     here, after emitting one as a trailing segment cost `fluid.parakeet-v3` a
//     WER of 105%.
//
// An actor rather than a struct for one reason: the chunk watermark. Polling on
// every 64 ms buffer would re-decode every token in the session fifteen times a
// second, which on a ten-minute dictation is a real fraction of a core spent
// rebuilding a string that had not changed.

import FluidAudio
import Foundation
import SpeechCore

actor NemotronStreamingBackend: FluidStreamingBackend {
    private let manager: StreamingNemotronMultilingualAsrManager
    /// Read off the loaded model's own metadata rather than derived from the
    /// catalog id: `metadata.json` carries `chunk_ms`, and a download whose
    /// chunk size disagrees with the id would otherwise set the poll cadence
    /// wrong in whichever direction nobody would notice.
    private let chunkSamples: Int
    /// Samples handed over that the manager has not turned into a chunk yet.
    private var buffered = 0

    static func make(
        manager: StreamingNemotronMultilingualAsrManager
    ) async -> NemotronStreamingBackend {
        let chunkSamples = await manager.config.chunkSamples
        // A session starts from nothing. The engine shares this manager with
        // the batch path, and `transcribe` resets before it decodes, so a live
        // session that did not would inherit whatever the last one left.
        await manager.reset()
        return NemotronStreamingBackend(manager: manager, chunkSamples: max(1, chunkSamples))
    }

    private init(manager: StreamingNemotronMultilingualAsrManager, chunkSamples: Int) {
        self.manager = manager
        self.chunkSamples = chunkSamples
    }

    func feed(_ samples: [Float]) async throws -> FluidStreamingPoll? {
        // Counted after the call, not before. `process` can throw before it has
        // appended anything - `notInitialized`, if the engine unloaded - and a
        // watermark incremented on a decode that did not happen stays wrong for
        // the rest of the session, putting every later poll one buffer early.
        _ = try await manager.process(samples: samples)
        buffered += samples.count
        // `process` drains every whole chunk it can, so what is left over is
        // the remainder - which is also the arithmetic that says whether
        // anything was decoded at all.
        guard buffered >= chunkSamples else { return nil }
        buffered %= chunkSamples
        return await poll()
    }

    func flush() async throws -> FluidStreamingPoll {
        buffered = 0
        // Called for the transcript it returns, which is the whole thing. The
        // timings come back from the same call because `finish()` clears the
        // accumulator it would otherwise have to be read from afterwards.
        let (text, timings) = try await manager.finishWithTokenTimings()
        return FluidStreamingPoll(transcript: text, words: Self.words(from: timings))
    }

    func reset() async {
        buffered = 0
        await manager.reset()
    }

    /// The residual cost, stated because the chunk gate above only bounds it
    /// rather than removing it: each poll decodes every token id accumulated so
    /// far and regroups every word, so a session's total polling work grows
    /// with the square of its length. At the tiers that exist - one poll every
    /// 0.56 s at worst - a thirty-minute dictation is about 3200 polls over a
    /// list that reaches a few thousand words, which is nothing next to the
    /// encoder. A tier finer than 560 ms would want a real delta instead.
    private func poll() async -> FluidStreamingPoll {
        FluidStreamingPoll(
            transcript: await manager.getPartialTranscript(),
            words: Self.words(from: await manager.getTokenTimings()))
    }

    /// Through FluidAudio's own SentencePiece joiner, which is what the batch
    /// path for this row uses too - so a word means the same thing in both
    /// modes.
    static func words(from timings: [TokenTiming]) -> [Word] {
        buildWordTimings(from: timings).map {
            Word(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }
}
