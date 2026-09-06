// UnifiedStreamingBackendTests.swift - the one rule this backend owns that the
// library does not: what happens to a token timing at a drain boundary.
//
// `StreamingUnifiedAsrManager.consumeTokenTimings()` empties its pending buffer
// on every call, and the back-fill that gives each token a real duration - end
// moved to the next token's start - can only run while both tokens are in that
// buffer. So a session that drains every chunk gets a different answer from a
// batch transcription that drains once at the end, and the difference is one
// short-ended token per poll.
//
// The property pinned here is that there is no difference: draining in any
// number of batches produces exactly what draining once would have. That is
// stronger than testing the back-fill directly, and it fails if the back-fill
// is dropped, applied in the wrong direction, or applied when it should not be.

import FluidAudio
import Foundation
import Testing
@testable import SpeechFluid
@testable import SpeechCore

@Suite("Parakeet Unified streaming token timings")
struct UnifiedStreamingBackendTests {
    /// 80 ms, the encoder frame these timings are quantized to.
    private static let frame = 0.08

    /// One batch as `StreamingUnifiedAsrManager` would hand it over.
    ///
    /// Transcribed from its emission loop rather than invented: within a batch
    /// each token's end is back-filled to the next token's start, and only when
    /// that would shorten it; the batch's last token keeps a provisional
    /// one-frame end because the next emission has not arrived yet.
    private func batch(_ pieces: [(text: String, frame: Int)]) -> [TokenTiming] {
        var timings: [TokenTiming] = []
        for piece in pieces {
            let start = Double(piece.frame) * Self.frame
            if let last = timings.indices.last, timings[last].endTime > start {
                let previous = timings[last]
                timings[last] = TokenTiming(
                    token: previous.token, tokenId: previous.tokenId,
                    startTime: previous.startTime, endTime: max(previous.startTime, start),
                    confidence: previous.confidence)
            }
            timings.append(
                TokenTiming(
                    token: piece.text, tokenId: piece.frame, startTime: start,
                    endTime: start + Self.frame, confidence: 1))
        }
        return timings
    }

    /// A sentence with tokens at one, two and three frame intervals, and two
    /// pairs sharing a frame.
    ///
    /// The shared frames are the point, and the first version of this fixture
    /// did not have them - which made the seam test below pass with the
    /// back-fill deleted. An RNN-T decoder emits up to `maxSymbolsPerFrame`
    /// tokens at one frame index, so a two-token word decoded in one frame is
    /// the ordinary case rather than an edge, and it is the case where the
    /// back-fill moves an end by a whole frame.
    ///
    /// Tokens one frame apart are a weaker case rather than no case, and the
    /// distinction is worth stating because a review caught the loose version
    /// of it here. The rule fires when the next token starts before the
    /// previous one's provisional end, and `n * 0.08 + 0.08` is *sometimes*
    /// fractionally above `(n + 1) * 0.08` - for 193 of the first 2000 frame
    /// indices, where the correction is one bit of a Double rather than 80 ms.
    /// The old fixture's one-frame gaps (0 to 1, 8 to 9, 13 to 14) all fall in
    /// the other 90%, so nothing in it fired at all.
    private let pieces: [(text: String, frame: Int)] = [
        (" the", 0), (" quick", 1), (" brown", 3), (" f", 4), ("ox", 4), (" jump", 8),
        ("s", 8), (" over", 9), (" the", 13), (" lazy", 14), (" dog", 17),
    ]

    private func accumulated(splittingAfter counts: [Int]) -> StreamingTokenTimings {
        var timings = StreamingTokenTimings()
        var index = 0
        for count in counts {
            timings.append(batch(Array(pieces[index..<(index + count)])))
            index += count
        }
        if index < pieces.count {
            timings.append(batch(Array(pieces[index...])))
        }
        return timings
    }

    // MARK: - Seams

    @Test("draining in batches gives what draining once would have")
    func seamsAreInvisible() {
        let whole = batch(pieces)
        // Every single split point, then a few multi-way splits. A session
        // drains once per decoded chunk, so a real one is the multi-way case.
        var splits: [[Int]] = (1..<pieces.count).map { [$0] }
        splits.append([1, 1, 1, 1, 1, 1, 1, 1, 1, 1])
        splits.append([2, 3, 1, 4])
        splits.append([5, 5])

        for split in splits {
            let got = accumulated(splittingAfter: split).all
            #expect(got.count == whole.count, "split \(split)")
            for (a, b) in zip(got, whole) {
                #expect(a.token == b.token, "split \(split)")
                #expect(a.startTime == b.startTime, "split \(split)")
                #expect(
                    a.endTime == b.endTime,
                    "split \(split): '\(a.token)' ends at \(a.endTime), want \(b.endTime)")
            }
        }
    }

    @Test("a seam only ever shortens an end, and never past its own start")
    func backfillOnlyShortens() {
        // A gap wider than a frame: the previous token's provisional end is
        // already earlier than the next token's start, so nothing moves. If the
        // rule were "always assign", this token would grow from 80 ms to 240 ms
        // and claim silence it was not spoken in.
        var gapped = StreamingTokenTimings()
        gapped.append(batch([(" one", 0)]))
        gapped.append(batch([(" two", 3)]))
        #expect(gapped.all[0].endTime == Self.frame)

        // A next token that starts before the previous one did. Nothing in the
        // decoder should produce this, and the library still guards it, so the
        // end clamps to the start rather than inverting the span.
        var inverted = StreamingTokenTimings()
        inverted.append(batch([(" one", 5)]))
        inverted.append(batch([(" two", 2)]))
        #expect(inverted.all[0].endTime == inverted.all[0].startTime)
        #expect(inverted.all[0].endTime >= inverted.all[0].startTime)
    }

    @Test("the frontier token keeps its provisional end")
    func frontierIsProvisional() throws {
        // Nothing has arrived after it, so there is nothing to back-fill from.
        // The alternative - holding the last token back until the next poll -
        // would delay every word by a chunk.
        //
        // `try #require` in a throwing test, not `try? #require`: the optional
        // form swallows the requirement's failure, so on an empty list this
        // read `nil == nil` and passed. Checked rather than assumed - a probe
        // with an empty array and the old shape passed.
        let timings = accumulated(splittingAfter: [4, 3])
        #expect(timings.all.count == pieces.count)
        let last = try #require(timings.all.last)
        #expect(last.endTime == last.startTime + Self.frame)
    }

    // MARK: - Words

    @Test("a word split across a drain is one word, not two")
    func wordsSurviveASeam() {
        // "fox" is two tokens and "jumps" is two more; the split lands inside
        // each. This is why the tokens are accumulated rather than the words:
        // grouping per batch would publish "f" and "ox" as separate words with
        // separate spans.
        var timings = StreamingTokenTimings()
        timings.append(batch(Array(pieces[0..<4])))
        timings.append(batch(Array(pieces[4..<7])))
        timings.append(batch(Array(pieces[7...])))

        #expect(timings.words.map(\.text) == [
            "the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog",
        ])
    }

    @Test("a word's span runs from its first token to its last")
    func wordSpansCoverTheirTokens() {
        let timings = accumulated(splittingAfter: [4, 3])
        let words = timings.words
        // "fox" is two tokens decoded at the same frame, so its span is one
        // frame wide: the first token's end was back-filled onto its own start
        // and the second keeps its provisional frame. It does not stretch to
        // frame 8 where "jump" starts, because the back-fill only ever
        // *shortens* an end - a token followed by a real gap is not stretched
        // across silence it was not spoken in. That is the library's rule and
        // this pins it, because the obvious reading of "back-fill to the next
        // token's start" is the other one.
        let fox = words.first { $0.text == "fox" }
        #expect(fox?.start == 4 * Self.frame)
        // Written as the sum the code computes rather than as `5 * frame`.
        // Here the two are equal to the bit, so this is a habit rather than a
        // necessity - but one frame later they are not (`5 * 0.08 + 0.08` is
        // 0.48000000000000004 against `6 * 0.08`'s 0.48), and matching how the
        // value was built is what keeps `==` usable at all.
        #expect(fox?.end == 4 * Self.frame + Self.frame)
        // Monotonic and non-overlapping, which is what the segment mapping
        // downstream assumes when it takes a span from matched words.
        for (a, b) in zip(words, words.dropFirst()) {
            #expect(a.end <= b.start, "'\(a.text)' ends after '\(b.text)' starts")
        }
    }

    @Test("clearing leaves nothing behind for the next session")
    func removeAllClears() {
        var timings = accumulated(splittingAfter: [4])
        timings.removeAll()
        #expect(timings.all.isEmpty)
        #expect(timings.words.isEmpty)
        // And the next batch must not be back-filled against a token from the
        // session that just ended.
        timings.append(batch([(" hello", 0)]))
        #expect(timings.all.count == 1)
        #expect(timings.all[0].startTime == 0)
    }

    // MARK: - Rows

    @Test("every streaming tier now reports live")
    func rowsAreLive() throws {
        for variant in UnifiedStreamTier.variants {
            let capabilities = try #require(
                FluidEngineFactory.capabilities(for: "parakeet-unified", variant: variant))
            #expect(capabilities.live == true)
            #expect(capabilities.batch == true)
        }
        // The offline rows are not live and cannot become live: their encoder
        // has no chunked-attention export.
        for variant in ["int8", "fp16"] {
            #expect(
                FluidEngineFactory.capabilities(for: "parakeet-unified", variant: variant)?.live
                    == false)
        }
    }
}
