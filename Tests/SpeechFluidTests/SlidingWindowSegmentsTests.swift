// SlidingWindowSegmentsTests.swift - the sliding-window mapping, without a
// model.
//
// These exist because the first version of this mapping shipped with three
// defects and none of them was reachable by any test: the logic lived inside an
// actor that cannot be constructed without four compiled CoreML models, so the
// only thing anyone could exercise was a live microphone and a person reading
// the output. `SlidingWindowTranscriptionUpdate` and `TokenTiming` are both
// publicly constructible, so the whole mapping can be driven from a literal.
//
// What is pinned here is the mapping's contract with the library, which was
// read out of FluidAudio v0.15.6 rather than inferred from short utterances:
// each update carries only the new, deduplicated tokens, so it is a finished
// piece of transcript that will never be revised, and `isConfirmed` is a
// statement about the piece before it.

import FluidAudio
import Foundation
import Testing

@testable import SpeechCore
@testable import SpeechFluid

@Suite("Sliding window segments")
struct SlidingWindowSegmentsTests {
    static func timings(
        _ words: [(String, Double, Double)]
    ) -> [TokenTiming] {
        words.enumerated().map { index, entry in
            // A leading U+2581 is SentencePiece's word-boundary marker, which
            // is what `buildWordTimings` groups on. Without it every token
            // joins the previous word and a two-word update comes back as one.
            TokenTiming(
                token: "\u{2581}" + entry.0, tokenId: index,
                startTime: entry.1, endTime: entry.2, confidence: 0.9)
        }
    }

    static func update(
        _ text: String,
        confirmed: Bool = true,
        confidence: Float = 0.9,
        timings: [TokenTiming] = []
    ) -> SlidingWindowTranscriptionUpdate {
        SlidingWindowTranscriptionUpdate(
            text: text, isConfirmed: confirmed, confidence: confidence,
            timestamp: Date(), tokenIds: [], tokenTimings: timings)
    }

    @Test("an unconfirmed update is a final, not a partial")
    func unconfirmedIsStillFinal() {
        // The defect this pins cost the last utterance of every short session.
        // `isConfirmed` false does not mean "this text may change" - the
        // library never re-sends a window - it means the manager has not yet
        // promoted the PREVIOUS window out of its volatile slot. Waiting for a
        // confirmation that is never sent loses the text outright.
        var mapper = SlidingWindowSegments(language: "en-US", wantWords: true)
        let segment = mapper.absorb(Self.update("the last thing I said", confirmed: false))
        #expect(segment != nil)
        #expect(mapper.finals.count == 1)
        #expect(mapper.finals.first?.text == "the last thing I said")
    }

    @Test("updates are appended in order with sequential ids")
    func idsAndOrder() {
        var mapper = SlidingWindowSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(Self.update("first window"))
        _ = mapper.absorb(Self.update("second window", confirmed: false))
        _ = mapper.absorb(Self.update("third window"))

        #expect(mapper.finals.map(\.id) == [0, 1, 2])
        #expect(mapper.finals.map(\.text) == ["first window", "second window", "third window"])
    }

    @Test("an empty update is dropped rather than published")
    func emptyUpdate() {
        var mapper = SlidingWindowSegments()
        #expect(mapper.absorb(Self.update("")) == nil)
        #expect(mapper.absorb(Self.update("   \n ")) == nil)
        #expect(mapper.finals.isEmpty)
        // And it does not consume an id, so the segment that follows is still 0.
        let segment = mapper.absorb(Self.update("real text"))
        #expect(segment?.id == 0)
    }

    @Test("the span comes from the token timings")
    func spanFromTimings() {
        var mapper = SlidingWindowSegments(language: "en-US", wantWords: true)
        let segment = mapper.absorb(Self.update(
            "hello there",
            timings: Self.timings([("hello", 13.5, 14.0), ("there", 14.0, 14.6)])))

        #expect(segment?.start == 13.5)
        #expect(segment?.end == 14.6)
        #expect(segment?.words?.count == 2)
        #expect(segment?.words?.first?.text.contains("hello") == true)
    }

    @Test("the span survives wantWords being false")
    func spanIndependentOfWantWords() {
        // The regression: gating the timing computation on `wantWords` left
        // every segment at 0..0, which never advances the session clock and
        // makes every refinement slice empty. The payload is optional; the
        // span is not.
        var mapper = SlidingWindowSegments(language: "en-US", wantWords: false)
        let segment = mapper.absorb(Self.update(
            "hello there",
            timings: Self.timings([("hello", 13.5, 14.0), ("there", 14.0, 14.6)])))

        #expect(segment?.start == 13.5)
        #expect(segment?.end == 14.6)
        #expect(segment?.words == nil)
    }

    @Test("a window with no timings borrows the previous segment's end")
    func noTimings() {
        var mapper = SlidingWindowSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(Self.update(
            "first", timings: Self.timings([("first", 0, 11.2)])))
        let second = mapper.absorb(Self.update("second"))

        // Not zero, and not a fabricated range: an empty span at the end of
        // what is known beats a span that claims audio it cannot describe.
        #expect(second?.start == 11.2)
        #expect(second?.end == 11.2)
        #expect(second?.words == nil)
    }

    @Test("spans do not run backwards across a burst of updates")
    func monotonicSpans() {
        var mapper = SlidingWindowSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(Self.update("one", timings: Self.timings([("one", 0.5, 11.0)])))
        _ = mapper.absorb(Self.update("two", timings: Self.timings([("two", 11.0, 22.0)])))
        _ = mapper.absorb(Self.update("three", timings: Self.timings([("three", 22.0, 30.0)])))

        for segment in mapper.finals {
            #expect(segment.end >= segment.start)
        }
        for (earlier, later) in zip(mapper.finals, mapper.finals.dropFirst()) {
            #expect(later.start >= earlier.start)
        }
    }

    @Test("the language tag is stamped as a primary subtag")
    func languageTag() {
        var mapper = SlidingWindowSegments(language: "pl-PL", wantWords: true)
        #expect(mapper.absorb(Self.update("dzien dobry"))?.language == "pl")
        var none = SlidingWindowSegments(language: nil, wantWords: true)
        #expect(none.absorb(Self.update("hello"))?.language == nil)
    }

    @Test("the update's confidence reaches the segment")
    func confidence() {
        var mapper = SlidingWindowSegments()
        let segment = mapper.absorb(Self.update("text", confidence: 0.42))
        #expect(segment?.confidence == 0.42)
    }
}
