// UnifiedStreamingBackend.swift - `fluid.parakeet-unified@stream-<ms>` behind
// the streaming-session protocol.
//
// The second row to reach `FluidStreamingSession`, and the shape is the same as
// the first: hand over audio, and the manager grows a transcript nobody ever
// revises. The differences from `NemotronStreamingBackend` are all in how the
// manager reports what it decoded, and each of them was read from the v0.15.6
// source rather than assumed from the sibling.
//
//   - `appendAudio(_:)` takes an `AVAudioPCMBuffer`, not `[Float]`, and runs it
//     through the library's own converter. Handing it the canonical 16 kHz mono
//     format takes that converter's pass-through path, which is why
//     `FluidStreamingSession` asks the pump for exactly that format.
//   - `processBufferedAudio()` decodes every window the buffered audio allows.
//     The first window opens once chunk+right samples exist and every chunk's
//     worth after that - so unlike the Nemotron row, the cadence is not one
//     fixed chunk size but a first step that waits for the look-ahead too.
//   - `getPartialTranscript()` returns the whole transcript, and it is CHEAPER
//     here: this manager appends each emission's text to a cache rather than
//     re-decoding the accumulated token ids, precisely because it is meant to
//     run for hours. Cheaper is not free - it still trims and copies the whole
//     string on every call - but it is a scan rather than a decode, and that is
//     what lets this backend poll on every buffer instead of gating on a chunk
//     watermark the way the Nemotron one has to.
//   - **`consumeTokenTimings()` is a DRAIN, not a read.** It returns what has
//     accumulated since the last call and clears it. That is the one real
//     difference and it costs this file two things: the timings have to be kept
//     here, because nobody else keeps them; and the library's own back-fill
//     stops at the drain boundary - see `StreamingTokenTimings`.
//   - `finish()` returns THE WHOLE TRANSCRIPT, like every other manager in this
//     library. The fourth one to do so and the third to be documented here,
//     after emitting one as a trailing segment cost `fluid.parakeet-v3` a WER
//     of 105%.
//
// One thing this backend deliberately does not do is gate its polls on a chunk
// watermark. The Nemotron backend has to, because a poll there re-decodes every
// token id in the session. Here a poll is a string the manager already built
// plus a regroup of the tokens, so the gate can be the honest one: did this
// call decode anything at all.

import AVFoundation
import FluidAudio
import Foundation
import SpeechCore

/// Token timings accumulated across drains, with the library's own back-fill
/// carried over the seams between them.
///
/// RNN-T tokens are emitted *at* an encoder frame and have no duration, so
/// `StreamingUnifiedAsrManager` gives each token an end of one frame and then
/// back-fills it to the next token's start when that arrives - "durations
/// reflect real gaps", in its own words. It can only do that while both tokens
/// are still in its pending buffer, and `consumeTokenTimings()` empties that
/// buffer on every poll. So without this type, the last token of every drained
/// batch would keep a provisional end the library would have corrected.
///
/// This applies the same rule at the seam, with the same two guards: only
/// shorten (`endTime > startTime` of the next token), and never move an end
/// before its own start. Batch needs none of it - it drains once, so every seam
/// is internal.
///
/// **How much it actually changes was measured rather than assumed, and it is
/// less than the mechanism suggests.** Eight minutes of speech at the 320 ms
/// tier - 1262 polls, 968 words - run through the real model both ways: with
/// this rule the live word timings match a whole-file drain exactly, in all
/// three fields. Without it, 14 of the 968 ends differ, and every one of the 14
/// differs in the last bits of a Double (132.32 against 132.32000000000002)
/// rather than by a frame. That is the arithmetic and not the audio: the guard
/// fires when a token's `start + 0.08` computes slightly above the next token's
/// `frameIndex * 0.08`, and the correction normalizes it.
///
/// The case worth 80 ms - two tokens emitted on one encoder frame with a drain
/// between them - did not occur once in those 1262 polls. It is a real decoder
/// behavior (`maxSymbolsPerFrame` is 10) and the library guards it, so the rule
/// stays; but nobody should describe it as recovering a word's duration. What
/// it buys, demonstrably, is that live and batch agree to the bit.
struct StreamingTokenTimings {
    /// Every token decoded so far, oldest first.
    private(set) var all: [TokenTiming] = []

    mutating func append(_ batch: [TokenTiming]) {
        if let next = batch.first, let last = all.indices.last, all[last].endTime > next.startTime {
            let previous = all[last]
            all[last] = TokenTiming(
                token: previous.token,
                tokenId: previous.tokenId,
                startTime: previous.startTime,
                endTime: max(previous.startTime, next.startTime),
                confidence: previous.confidence)
        }
        all.append(contentsOf: batch)
    }

    mutating func removeAll() {
        all.removeAll()
    }

    /// The words, through FluidAudio's own SentencePiece joiner - the same call
    /// the batch path makes, so a word means the same thing in both modes.
    ///
    /// Rebuilt from the whole list on every poll rather than extended
    /// incrementally, and that is a deliberate cost. A word can straddle a
    /// drain boundary, so an incremental builder would have to reimplement the
    /// joiner's boundary rule here and then keep it in step with theirs across
    /// pin bumps. The cost it buys off is quadratic in the session's length: at
    /// one poll per chunk, a thirty-minute dictation is a few thousand polls
    /// over a list that reaches a few thousand tokens, which is a small
    /// fraction of one core against an encoder that is running continuously.
    var words: [Word] {
        buildWordTimings(from: all).map {
            Word(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }
}

actor UnifiedStreamingBackend: FluidStreamingBackend {
    private let manager: StreamingUnifiedAsrManager
    private var timings = StreamingTokenTimings()

    static func make(
        manager: StreamingUnifiedAsrManager
    ) async throws -> UnifiedStreamingBackend {
        // A session starts from nothing. This manager is shared with the batch
        // path, and every piece of its state persists across calls by design -
        // including `finalFlushEmitted`, which after a batch transcription
        // would stop this session producing any window at all.
        try await manager.reset()
        return UnifiedStreamingBackend(manager: manager)
    }

    private init(manager: StreamingUnifiedAsrManager) {
        self.manager = manager
    }

    func feed(_ samples: [Float]) async throws -> FluidStreamingPoll? {
        try await manager.appendAudio(FluidBuffers.canonical(samples))
        try await manager.processBufferedAudio()
        let batch = await manager.consumeTokenTimings()
        // An empty batch is the whole "nothing was decoded" test, and it is
        // exact rather than approximate: the transcript cache grows only when an
        // emission is appended to it, so no emissions means no new text. That
        // equivalence holds because vocabulary boosting is off on this row - it
        // is the one path that rewrites the transcript without new emissions,
        // and the capability record says no to it.
        guard !batch.isEmpty else { return nil }
        timings.append(batch)
        return FluidStreamingPoll(
            transcript: await manager.getPartialTranscript(), words: timings.words)
    }

    func flush() async throws -> FluidStreamingPoll {
        // The final window is held back until the stream ends, because the
        // right context is re-encoded with more future audio on every step.
        // `finish()` is what releases it, and it returns the whole transcript
        // rather than the remainder.
        let transcript = try await manager.finish()
        timings.append(await manager.consumeTokenTimings())
        return FluidStreamingPoll(transcript: transcript, words: timings.words)
    }

    func reset() async {
        timings.removeAll()
        // The manager belongs to the engine and outlives this backend, so a
        // session that ended has to leave it clean for the next one. The throw
        // is the RNN-T decoder reallocating its state; there is nothing useful
        // to do with it here, and the next session's `make` resets again.
        try? await manager.reset()
    }
}
