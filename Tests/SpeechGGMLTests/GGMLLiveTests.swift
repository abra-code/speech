// GGMLLiveTests.swift - the part of ggml live mode that can be tested without
// a microphone or a two-gigabyte download.
//
// The streaming decoder itself is not testable here: it needs weights, real
// audio and about ten seconds per case, and what it produces is transcribe.cpp's
// business. What *is* ours, and what these tests cover, is the mapping from a
// growing committed string to segments - and that mapping is where the first
// version was wrong, so it is worth pinning precisely.

import Foundation
import Testing

@testable import SpeechCore
@testable import SpeechGGML

@Suite("ggml live segmentation")
struct GGMLLiveSegmentationTests {
    /// The text up to and including the first complete sentence, or nil.
    ///
    /// `atEnd: true` is the end-of-stream flush. Mid-stream, "the terminator is
    /// at the end of what has been committed" means nothing - see
    /// `decimalSplitAcrossCommits`.
    static func firstSentence(_ text: String, atEnd: Bool = true) -> String? {
        StreamSegmentAccumulator.endOfFirstSentence(in: text, atEnd: atEnd)
            .map { String(text[..<$0]) }
    }

    @Test("a sentence is found where it ends, not only at the end of the text")
    func splitsMidText() {
        // This is the whole reason the rule is a scan rather than a test on the
        // tail. Commits arrive in 8 to 20 character increments about once a
        // second, so a full stop is almost always in the middle of what just
        // arrived. The first version asked "does the pending text end in a
        // period", which never fired once: a ten-second, two-sentence dictation
        // came back as one segment closed only by the end of the stream.
        #expect(Self.firstSentence("The quick brown fox jumps over the lazy dog. Pack my box")
            == "The quick brown fox jumps over the lazy dog.")
        #expect(Self.firstSentence("Stop! Now go") == "Stop!")
        #expect(Self.firstSentence("Really? I think so") == "Really?")
    }

    @Test("an incomplete sentence is left pending")
    func noSplitWithoutTerminator() {
        #expect(Self.firstSentence("The quick brown fox") == nil)
        #expect(Self.firstSentence("") == nil)
        #expect(Self.firstSentence("   ") == nil)
    }

    @Test("a terminator at the very end still closes the sentence")
    func splitsAtEnd() {
        #expect(Self.firstSentence("All done.") == "All done.")
        #expect(Self.firstSentence("All done") == nil)
    }

    @Test("a decimal point is not a sentence")
    func decimalsSurvive() {
        // The narrowing rule: a terminator counts only when whitespace or the
        // end of the text follows it. Without this, "transcribe.cpp v0.2.3"
        // becomes four segments.
        #expect(Self.firstSentence("It runs at 3.5 times real time") == nil)
        #expect(Self.firstSentence("Version v0.2.3 shipped") == nil)
        #expect(Self.firstSentence("It runs at 3.5 times real time. Next")
            == "It runs at 3.5 times real time.")
    }

    @Test("closing quotes and brackets belong to the sentence they end")
    func absorbsClosers() {
        #expect(Self.firstSentence("He said \"stop.\" Then he left")
            == "He said \"stop.\"")
        #expect(Self.firstSentence("(See the note.) And then")
            == "(See the note.)")
    }

    @Test("the ideographic full stop closes a sentence too")
    func ideographicStop() {
        // U+3002, which these models emit for Chinese and Japanese instead of
        // ".". Without it a Chinese dictation would never split.
        let text = "\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{5F88}\u{597D}\u{3002}\u{660E}\u{5929}"
        #expect(Self.firstSentence(text) == "\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{5F88}\u{597D}\u{3002}")
    }

    @Test("fullwidth CJK terminators close a sentence")
    func fullwidthTerminators() {
        // U+FF01 and U+FF1F. Without them a Japanese question runs into the
        // next sentence until the 15-second backstop, because CJK text does not
        // use the ASCII forms and puts no space after them either.
        let question = "\u{3053}\u{308C}\u{306F}\u{4F55}\u{FF1F}\u{6B21}"
        #expect(Self.firstSentence(question) == "\u{3053}\u{308C}\u{306F}\u{4F55}\u{FF1F}")
        let shout = "\u{3059}\u{3054}\u{3044}\u{FF01}\u{6B21}"
        #expect(Self.firstSentence(shout) == "\u{3059}\u{3054}\u{3044}\u{FF01}")
    }

    @Test("mid-stream, a terminator at the end of the committed text is not a sentence")
    func terminatorAtEndOfCommittedText() {
        // The rule that makes "All done." close is only correct at end of
        // stream. Mid-stream the end of the text is an arbitrary position -
        // wherever the decoder happened to stop committing.
        #expect(Self.firstSentence("It runs at 3.", atEnd: false) == nil)
        #expect(Self.firstSentence("It runs at 3.", atEnd: true) == "It runs at 3.")
    }
}

@Suite("ggml live segment accumulator")
struct StreamSegmentAccumulatorTests {
    /// Feeds one committed snapshot and returns the events it produced.
    static func step(
        _ accumulator: inout StreamSegmentAccumulator,
        _ committed: String, at seconds: Double, isFinal: Bool = false
    ) -> [LiveEvent] {
        accumulator.absorb(
            committed: committed, tentative: "",
            committedMs: Int64(seconds * 1000), receivedMs: Int64(seconds * 1000),
            isFinal: isFinal)
    }

    static func finals(_ events: [LiveEvent]) -> [Segment] {
        events.compactMap { if case .final(let s) = $0 { return s } else { return nil } }
    }

    static func partials(_ events: [LiveEvent]) -> [Segment] {
        events.compactMap { if case .partial(let s) = $0 { return s } else { return nil } }
    }

    @Test("a commit that completes a grapheme cluster is not lost")
    func graphemeClusterCommit() {
        // The defect this pins, and it is silent: `cafe` then `cafe` plus a
        // combining acute is the SAME number of Characters, so a Character
        // watermark sees nothing new and drops the accent. The rows that stream
        // here list ko-KR, hi-IN, vi-VN and fr-FR, which is exactly where a
        // byte-level tokenizer commits a prefix ending mid-cluster.
        var accumulator = StreamSegmentAccumulator()
        _ = Self.step(&accumulator, "Le caf\u{65}", at: 1)
        let events = Self.step(&accumulator, "Le caf\u{65}\u{301}. Puis", at: 2)
        #expect(Self.finals(events).map(\.text) == ["Le caf\u{65}\u{301}."])

        // Hangul jamo composing into a syllable: same trap, same fix.
        var hangul = StreamSegmentAccumulator()
        _ = Self.step(&hangul, "\u{1100}", at: 1)
        let composed = Self.step(&hangul, "\u{1100}\u{1161}. \u{B2E4}", at: 2)
        #expect(Self.finals(composed).map(\.text) == ["\u{1100}\u{1161}."])
    }

    @Test("a run of terminators does not produce punctuation-only segments")
    func noPunctuationOnlySegments() {
        // `Really?!` used to emit `Really?` and then a segment containing only
        // `!` - a real event on the wire, which `--refine` would then spend a
        // whole model inference re-transcribing.
        var accumulator = StreamSegmentAccumulator()
        let events = Self.step(&accumulator, "Really?! That is amazing. Next", at: 4)
        #expect(Self.finals(events).map(\.text) == ["Really?!", "That is amazing."])

        var shouty = StreamSegmentAccumulator()
        let bangs = Self.step(&shouty, "Wow!!! Look at that. Next", at: 4)
        #expect(Self.finals(bangs).map(\.text) == ["Wow!!!", "Look at that."])

        var leading = StreamSegmentAccumulator()
        let dot = Self.step(&leading, " . Hello world. Next", at: 4)
        #expect(Self.finals(dot).map(\.text) == ["Hello world."])
    }

    @Test("a decimal split across two commits is not cut in half")
    func decimalSplitAcrossCommits() {
        // The case the old `decimalsSurvive` test could not reach: it fed whole
        // strings, and the production path never sees one. Here the first
        // commit ends at the decimal point, which is where the end-of-text rule
        // used to fire.
        var accumulator = StreamSegmentAccumulator()
        let first = Self.step(&accumulator, "It runs at 3.", at: 2)
        #expect(Self.finals(first).isEmpty, "nothing may close on a bare decimal point")
        let second = Self.step(&accumulator, "It runs at 3.5 times real time. Next", at: 4)
        #expect(Self.finals(second).map(\.text) == ["It runs at 3.5 times real time."])
    }

    @Test("two sentences in one commit get their own interpolated spans")
    func twoSentencesInOneCommit() {
        var accumulator = StreamSegmentAccumulator()
        let events = Self.step(&accumulator, "Hello there. How are you? Next", at: 10)
        let finals = Self.finals(events)
        #expect(finals.map(\.text) == ["Hello there.", "How are you?"])
        // Contiguous, ordered, inside the committed span, and the second does
        // not inherit the first's start.
        #expect(finals[0].start == 0)
        #expect(finals[0].end == finals[1].start)
        #expect(finals[1].end <= 10)
        #expect(finals[0].end > 0)
    }

    @Test("ids advance only on finals, and a partial carries the next one")
    func idSequencing() {
        var accumulator = StreamSegmentAccumulator()
        let opening = Self.step(&accumulator, "Hello there", at: 2)
        #expect(Self.partials(opening).map(\.id) == [0])
        let closing = Self.step(&accumulator, "Hello there. How", at: 4)
        #expect(Self.finals(closing).map(\.id) == [0])
        // The partial that follows the final carries the id the *next* final
        // will have, which is the contract `segment.refined` relies on.
        #expect(Self.partials(closing).map(\.id) == [1])
    }

    @Test("the backstop closes a segment nobody punctuated")
    func backstop() {
        var accumulator = StreamSegmentAccumulator(maxUtteranceSeconds: 5)
        let early = Self.step(&accumulator, "one two three", at: 3)
        #expect(Self.finals(early).isEmpty)
        let late = Self.step(&accumulator, "one two three four five", at: 6)
        #expect(Self.finals(late).map(\.text) == ["one two three four five"])
    }

    @Test("the end of the stream closes whatever is pending")
    func flushAtEnd() {
        var accumulator = StreamSegmentAccumulator()
        _ = Self.step(&accumulator, "no punctuation here", at: 3)
        let events = Self.step(&accumulator, "no punctuation here at all", at: 4, isFinal: true)
        #expect(Self.finals(events).map(\.text) == ["no punctuation here at all"])
        // And no partial after the flush.
        #expect(Self.partials(events).isEmpty)
    }

    @Test("no segment ever ends before it starts")
    func spansAreOrdered() {
        var accumulator = StreamSegmentAccumulator()
        // A commit reported at an earlier time than the previous one, which is
        // out of contract but must not produce nonsense on the wire.
        var events = Self.step(&accumulator, "First one. ", at: 10)
        events += Self.step(&accumulator, "First one. Second one. ", at: 4)
        events += Self.step(&accumulator, "First one. Second one. Third.", at: 12, isFinal: true)
        for segment in Self.finals(events) + Self.partials(events) {
            #expect(segment.end >= segment.start, "\(segment.id): \(segment.start)..\(segment.end)")
            #expect(segment.start.isFinite && segment.end.isFinite)
        }
    }
}

@Suite("ggml streaming rows")
struct GGMLStreamingRowTests {
    /// Measured 2026-09-05 by loading every installed GGUF and reading
    /// `Model.capabilities.supportsStreaming`. Pinned as a set rather than
    /// spot-checked so that adding a row forces a decision about it.
    static let streamingModels: Set<String> = [
        "parakeet-unified-en-0.6b",
        "nemotron-3.5-asr-streaming-0.6b",
    ]

    @Test("exactly the measured rows claim a streaming decoder")
    func streamingSet() {
        let claimed = Set(GGMLCatalog.rows.filter(\.streaming).map(\.model))
        #expect(claimed == Self.streamingModels)
    }

    @Test("the fast multilingual row is not one of them")
    func parakeetV3IsNotLive() throws {
        // Worth its own assertion because it is the row a reader would assume
        // streams: it is the fast one, it is multilingual, and its CoreML twin
        // has a sliding-window live mode. On this engine it does not stream, so
        // ggml live mode means either an English-only model or the row that
        // lost to Apple in all three languages in spike 2.
        let row = try #require(GGMLCatalog.row(model: "parakeet-tdt-0.6b-v3"))
        #expect(row.streaming == false)
    }

    /// Narrow on purpose: this checks the wiring, not the truth. Whether the
    /// row's flag matches the weights can only be settled by loading them, and
    /// `makeLiveSession` is where that check lives. What this catches is the
    /// flag being hardcoded again, which is what it replaced.
    @Test("the capability record carries the row's answer")
    func capabilitiesFollowTheRow() {
        for (model, variant) in GGMLEngineFactory.catalogRows {
            guard let row = GGMLCatalog.row(model: model),
                  let capabilities = GGMLEngineFactory.capabilities(for: model, variant: variant)
            else {
                Issue.record("no capabilities for \(model)")
                continue
            }
            #expect(
                capabilities.live == row.streaming,
                "\(model)@\(variant ?? "-") reports live=\(capabilities.live)")
        }
    }
}
