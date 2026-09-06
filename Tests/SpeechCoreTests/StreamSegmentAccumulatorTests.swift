// StreamSegmentAccumulatorTests.swift - the rule that turns a growing
// hypothesis into segments, tested without any engine at all.
//
// The two families that need this rule cannot be constructed in a test: one
// wants a 750 MB GGUF and a Metal device, the other four compiled CoreML
// models. That is why the rule is a plain struct in SpeechCore, and it is why
// these tests are the only place its behavior is pinned. The cases below are
// the ones that were once wrong: text lost at a grapheme boundary, a segment
// holding nothing but punctuation, and a decimal cut in half at a commit.

import Foundation
import Testing

@testable import SpeechCore

@Suite("live segmentation")
struct LiveSegmentationTests {
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

@Suite("live segment accumulator")
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

    @Test("the backstop closes a segment nobody punctuated, without breaking a word")
    func backstop() {
        var accumulator = StreamSegmentAccumulator(maxUtteranceSeconds: 5)
        let early = Self.step(&accumulator, "one two three", at: 3)
        #expect(Self.finals(early).isEmpty)
        // The last word is held back: mid-stream, "five" may be the whole word
        // or the front of "fivefold", and nothing here can tell the difference.
        // It leads the next segment instead of being cut in half.
        let late = Self.step(&accumulator, "one two three four five", at: 6)
        #expect(Self.finals(late).map(\.text) == ["one two three four"])
        let end = Self.step(&accumulator, "one two three four five", at: 7, isFinal: true)
        #expect(Self.finals(end).map(\.text) == ["five"])
    }

    @Test("a word is never cut in half, and text with no word boundary says so")
    func splitAtLastWord() throws {
        // The head keeps everything up to the last word boundary; the tail is
        // the word that may still be growing.
        var split = try #require(StreamSegmentAccumulator.splitAtLastWord("one two three"))
        #expect(split.head == "one two")
        #expect(split.tail == "three")
        // Trailing whitespace means the last word is finished.
        split = try #require(StreamSegmentAccumulator.splitAtLastWord("one two "))
        #expect(split.head == "one two")
        #expect(split.tail == "")
        // One word, and one word behind a space: nothing can be held back that
        // would leave anything to publish, so there is no cut to make here.
        #expect(StreamSegmentAccumulator.splitAtLastWord("one") == nil)
        #expect(StreamSegmentAccumulator.splitAtLastWord(" one") == nil)
        // No whitespace anywhere is also the CJK case: the rows that stream
        // Chinese and Japanese emit no spaces at all, so there is no boundary
        // in the text to find. The caller is what stops that becoming a stall.
        let chinese = "\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{5F88}\u{597D}"
        #expect(StreamSegmentAccumulator.splitAtLastWord(chinese) == nil)
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

@Suite("boundary-cut segmentation")
struct BoundarySegmentationTests {
    private func accumulator() -> StreamSegmentAccumulator {
        StreamSegmentAccumulator(language: "en", segmentation: .vad)
    }

    private func step(
        _ accumulator: inout StreamSegmentAccumulator,
        _ committed: String, at seconds: Double, isFinal: Bool = false
    ) -> [LiveEvent] {
        StreamSegmentAccumulatorTests.step(&accumulator, committed, at: seconds, isFinal: isFinal)
    }

    private func finals(_ events: [LiveEvent]) -> [Segment] {
        StreamSegmentAccumulatorTests.finals(events)
    }

    private func end(_ seconds: Double) -> SpeechBoundary {
        SpeechBoundary(kind: .end, seconds: seconds)
    }

    private func start(_ seconds: Double) -> SpeechBoundary {
        SpeechBoundary(kind: .start, seconds: seconds)
    }

    @Test("the cut is where the audio said, not where the text looks finished")
    func cutsAtTheBoundary() {
        var accumulator = self.accumulator()
        // Two sentences' worth of text and a boundary that agrees with neither
        // of the full stops: under this rule the sentence is not the unit, the
        // pause is.
        var events = step(&accumulator, "one. two. three", at: 3)
        #expect(finals(events).isEmpty, "no boundary has been reached yet")

        accumulator.mark(end(2.5))
        events = step(&accumulator, "one. two. three and more", at: 4)
        let cut = finals(events)
        // Everything but the last word, which is held back because nothing here
        // can tell a finished word from one the decoder is still extending -
        // see `splitAtLastWord`.
        #expect(cut.map(\.text) == ["one. two. three and"])
        #expect(cut.first?.end == 2.5)
    }

    @Test("a boundary the engine has not decoded past waits for it")
    func boundariesWaitForTheCommit() {
        var accumulator = self.accumulator()
        accumulator.mark(end(9))
        // The detector is ahead of the decoder, which is the normal case: an
        // ending is reported after 0.75 s of silence, and an engine can easily
        // be further behind than that.
        var events = step(&accumulator, "still going", at: 5)
        #expect(finals(events).isEmpty)
        events = step(&accumulator, "still going and now past it", at: 9.5)
        #expect(finals(events).map(\.text) == ["still going and now past"])
        #expect(finals(events).first?.end == 9)
        // And the word held back leads the next segment rather than vanishing.
        accumulator.mark(end(12))
        events = step(&accumulator, "still going and now past it plus more words", at: 13)
        #expect(finals(events).map(\.text) == ["it plus more"])
    }

    @Test("the sentence rule is off, and the backstop is not")
    func sentencesDoNotCut() {
        var accumulator = StreamSegmentAccumulator(
            maxUtteranceSeconds: 10, language: "en", segmentation: .vad)
        // Four sentences, no boundary: under `.engine` this is four segments.
        var events = step(&accumulator, "One. Two. Three. Four. ", at: 4)
        #expect(finals(events).isEmpty)
        // The backstop still fires, because a speaker who never pauses would
        // otherwise produce one segment covering the whole session. It holds
        // the last word back for the same reason a boundary cut does.
        events = step(&accumulator, "One. Two. Three. Four. Five.", at: 11)
        #expect(finals(events).map(\.text) == ["One. Two. Three. Four."])
    }

    @Test("a burst covering several boundaries stays in one piece, cut at the last")
    func burstsCollapseToTheLastBoundary() {
        var accumulator = self.accumulator()
        // The case that decides the rule: an engine that has been silent for
        // twenty seconds hands over everything at once. The text cannot be
        // split - there is no word clock here - so cutting at the first
        // boundary would stamp three utterances with the first one's end time.
        for boundary in [end(5), start(7), end(12), start(14), end(19)] {
            accumulator.mark(boundary)
        }
        let events = step(&accumulator, "all three utterances in one commit", at: 20)
        let cut = finals(events)
        #expect(cut.map(\.text) == ["all three utterances in one"])
        #expect(cut.first?.start == 0)
        #expect(cut.first?.end == 19, "the last boundary the commit reached, not the first")
    }

    @Test("speech the engine transcribed nothing from moves the clock, not the transcript")
    func emptySpansAdvanceTheClock() {
        var accumulator = self.accumulator()
        // A cough, or a word too quiet to decode: the detector heard something
        // and the engine produced no text for it. The ending is the only thing
        // that moves here - no start follows it - so this is what pins the
        // clock advancing on an empty span rather than on the next start.
        accumulator.mark(end(2))
        var events = step(&accumulator, "", at: 3)
        #expect(events.isEmpty, "nothing to publish, and no empty segment on the wire")

        accumulator.mark(end(5))
        events = step(&accumulator, "the first real words", at: 6)
        var cut = finals(events)
        #expect(cut.map(\.text) == ["the first real"])
        #expect(cut.first?.start == 2, "the silence that produced no text is not in this segment")
        #expect(cut.first?.end == 5)

        // And a start honored while nothing is pending - the engine has
        // committed everything it had - begins the next segment where speech
        // did rather than in the pause before it.
        accumulator.mark(start(8))
        events = step(&accumulator, "the first real words", at: 9)
        // The held-back word is still pending, so it is published as a partial
        // rather than being honored as a start.
        #expect(finals(events).isEmpty)
        accumulator.mark(end(11))
        events = step(&accumulator, "the first real words and the second lot", at: 12)
        cut = finals(events)
        #expect(cut.map(\.text) == ["words and the second"])
        // Not 8: this segment already held "words" when the start arrived, so
        // its beginning stays where the previous cut left it.
        #expect(cut.first?.start == 5)
    }

    @Test("a start cannot move a segment that already has text")
    func startsDoNotStealDecodedText() {
        var accumulator = self.accumulator()
        accumulator.mark(end(4))
        var cut = finals(step(&accumulator, "alpha beta", at: 5))
        #expect(cut.map(\.text) == ["alpha"], "the first utterance closes at its boundary")

        // Now the case the guard exists for. The engine is running behind, so
        // it commits text for audio *before* the next start - and that text
        // belongs to the segment that was open when it arrived. A start honored
        // on its own, with text already pending, must not move that segment's
        // beginning past its own words.
        _ = step(&accumulator, "alpha beta gamma", at: 5.5)
        accumulator.mark(start(6))
        _ = step(&accumulator, "alpha beta gamma", at: 7)
        accumulator.mark(end(9))
        cut = finals(step(&accumulator, "alpha beta gamma delta", at: 10))
        #expect(cut.map(\.text) == ["beta gamma"])
        #expect(cut.first?.start == 4, "not 6: the segment already held words decoded before it")
        #expect(cut.first?.end == 9)
    }

    @Test("the flush honors a boundary before closing the rest")
    func flushUsesTheLastBoundary() {
        var accumulator = self.accumulator()
        accumulator.mark(end(4))
        let events = step(&accumulator, "everything that was said", at: 6, isFinal: true)
        let cut = finals(events)
        // Cut at the boundary rather than at the end of the audio - the
        // trailing two seconds were silence - and then the flush takes the word
        // the cut held back, because there is no next commit to finish it in.
        #expect(cut.map(\.text) == ["everything that was", "said"])
        #expect(cut.first?.end == 4)
    }

    @Test("a cut with nothing to cut waits for the next commit, at its own time")
    func aCutWithNoWordBoundaryIsCarried() {
        var accumulator = self.accumulator()
        accumulator.mark(end(3))
        // One unfinished word and no word clock: cutting here would either
        // publish half a word or drop the boundary. It is carried instead.
        var events = step(&accumulator, "Twent", at: 4)
        #expect(finals(events).isEmpty)

        events = step(&accumulator, "Twentieth century research", at: 5)
        let cut = finals(events)
        #expect(cut.map(\.text) == ["Twentieth century"])
        #expect(cut.first?.end == 3, "the boundary the audio reported, not the commit that made it usable")
    }

    @Test("a carried cut waits one commit and no longer")
    func aCarriedCutIsNotHeldForever() {
        var accumulator = self.accumulator()
        accumulator.mark(end(3))
        // Text with no word boundary in it at all, which is what Chinese and
        // Japanese look like here: the rows that stream them emit no spaces.
        let chinese = "\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{5F88}\u{597D}"
        var events = step(&accumulator, chinese, at: 4)
        #expect(finals(events).isEmpty, "one commit of grace")

        events = step(&accumulator, chinese, at: 5)
        let cut = finals(events)
        #expect(cut.map(\.text) == [chinese], "and then it is cut rather than held to the backstop")
        #expect(cut.first?.end == 3)
    }

    @Test("a cut carried past a backstop does not fire on the next commit's text")
    func aCarriedCutDiesWithTheTextItDescribed() {
        var accumulator = StreamSegmentAccumulator(
            maxUtteranceSeconds: 15, language: "en", segmentation: .vad)
        accumulator.mark(end(3))
        // The boundary is carried because one unfinished word cannot be cut.
        // Then the backstop fires in the same commit and publishes that word.
        let events = step(&accumulator, "Twent", at: 16)
        #expect(finals(events).map(\.text) == ["Twent"])

        // The carried cut described text that has now gone out. Inheriting it
        // would cut the next commit's unrelated text at a time the clock has
        // already passed, which reaches the wire as a segment of zero length
        // stamped before the audio it came from.
        let next = finals(step(&accumulator, "Twentieth century research", at: 17))
        #expect(next.isEmpty)
    }

    @Test("a start carried with a cut still opens the segment it belongs to")
    func aCarriedCutKeepsItsStart() {
        var accumulator = self.accumulator()
        accumulator.mark(end(3))
        accumulator.mark(start(5))
        // Both are drained together and neither can be acted on: there is no
        // word boundary in this text to cut at. The start has to travel with
        // the cut, or the segment it eventually opens begins in the silence.
        let chinese = "\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{5F88}\u{597D}"
        var events = step(&accumulator, chinese, at: 6)
        #expect(finals(events).isEmpty)

        events = step(&accumulator, chinese, at: 7)
        #expect(finals(events).map(\.text) == [chinese])
        // Nothing is pending now, so the carried start is what the next segment
        // opens at - 5, where speech resumed, not 3 where the last one closed.
        events = step(&accumulator, chinese + "\u{660E}\u{5929}", at: 8)
        #expect(StreamSegmentAccumulatorTests.partials(events).first?.start == 5)
    }

    @Test("a newer boundary replaces a carried one rather than inheriting its grace")
    func aNewerBoundaryIsAFirstAttempt() {
        var accumulator = self.accumulator()
        accumulator.mark(end(3))
        _ = step(&accumulator, "Twent", at: 4)
        // The word still has not finished, but this is a different boundary, so
        // it gets its own commit of grace rather than cutting immediately.
        accumulator.mark(end(6))
        let events = step(&accumulator, "Twent", at: 7)
        #expect(finals(events).isEmpty)
        // And when it does cut, it cuts at the newer boundary.
        let cut = finals(step(&accumulator, "Twentieth century", at: 8))
        #expect(cut.map(\.text) == ["Twentieth"])
        #expect(cut.first?.end == 6)
    }

    /// Drives `absorb` with a word clock, the way the two `fluid` streaming
    /// families do. `clock` answers how many Characters of the pending text
    /// were spoken before a given time.
    private func step(
        _ accumulator: inout StreamSegmentAccumulator,
        _ committed: String, at seconds: Double,
        clock: @escaping (Double, String) -> Int
    ) -> [LiveEvent] {
        accumulator.absorb(
            committed: committed, tentative: "",
            committedMs: Int64(seconds * 1000), receivedMs: Int64(seconds * 1000),
            isFinal: false, settledText: clock)
    }

    @Test("a word clock cuts where it says, not at the last whitespace")
    func theWordClockOwnsTheCut() {
        var accumulator = self.accumulator()
        accumulator.mark(end(2))
        // Three words pending and the clock says two of them were spoken before
        // the boundary. Without it the cut would keep two and hold one back,
        // which is the same answer for the wrong reason - so the fixture says
        // one, which nothing else here would produce.
        let events = step(&accumulator, "one two three", at: 3, clock: { _, _ in 3 })
        let cut = finals(events)
        #expect(cut.map(\.text) == ["one"])
        #expect(cut.first?.end == 2)
    }

    @Test("a word clock that names nothing moves the clock and publishes nothing")
    func theWordClockCanSayNone() {
        var accumulator = self.accumulator()
        accumulator.mark(end(2))
        // Everything pending was spoken after the boundary: the commit that
        // carried the watermark past it is the one that decoded the next
        // utterance. There is nothing to publish, and the next segment must not
        // then claim the silence that went before it.
        var events = step(&accumulator, "next utterance", at: 3, clock: { _, _ in 0 })
        #expect(events.compactMap { if case .final = $0 { return true } else { return nil } }.isEmpty)

        accumulator.mark(end(5))
        events = step(&accumulator, "next utterance here", at: 6, clock: { _, text in text.count })
        let cut = finals(events)
        #expect(cut.map(\.text) == ["next utterance here"])
        #expect(cut.first?.start == 2, "the boundary that published nothing still moved the clock")
        #expect(cut.first?.end == 5)
    }

    @Test("a cut keeps the space the next word will arrive without")
    func aCutKeepsItsTrailingSpace() {
        // A commit is a growing string and the piece appended next carries a
        // leading space only if the tokenizer put one there. Trimming it away
        // at a cut glues two words into one - `two` and `three` becoming
        // `twothree` - in the middle of a transcript, with nothing to say it
        // happened.
        var accumulator = self.accumulator()
        accumulator.mark(end(2.5))
        var events = step(&accumulator, "one two ", at: 3)
        #expect(finals(events).map(\.text) == ["one"])
        events = step(&accumulator, "one two three", at: 4, isFinal: true)
        #expect(finals(events).map(\.text) == ["two three"])
    }

    @Test("a cut placed by the word clock keeps it as well")
    func aWordClockCutKeepsItsTrailingSpace() {
        var accumulator = self.accumulator()
        accumulator.mark(end(2.5))
        var events = step(&accumulator, "one two ", at: 3, clock: { _, _ in 3 })
        #expect(finals(events).map(\.text) == ["one"])
        events = step(&accumulator, "one two three", at: 4, clock: { _, _ in 0 })
        #expect(StreamSegmentAccumulatorTests.partials(events).map(\.text) == ["two three"])
    }

    @Test("a cut that takes everything leaves nothing pending, not a space")
    func aWholeCutLeavesNothingPending() {
        // The difference is visible one boundary later: a pending buffer
        // holding only whitespace is not empty, so the start that follows would
        // be ignored and the next segment would open at the cut instead of
        // where speech resumed.
        var accumulator = self.accumulator()
        accumulator.mark(end(2))
        var events = step(&accumulator, "one two ", at: 3, clock: { _, text in text.count })
        #expect(finals(events).map(\.text) == ["one two"])

        // The start is honored on the next poll, which decoded nothing new -
        // and only if the buffer it finds is genuinely empty.
        accumulator.mark(start(5))
        events = step(&accumulator, "one two ", at: 6, clock: { _, _ in 0 })
        #expect(events.isEmpty)
        events = step(&accumulator, "one two three", at: 7, clock: { _, _ in 0 })
        #expect(StreamSegmentAccumulatorTests.partials(events).first?.start == 5)
    }

    @Test("the backstop keeps it too")
    func theBackstopKeepsItsTrailingSpace() {
        var accumulator = StreamSegmentAccumulator(maxUtteranceSeconds: 5, language: "en")
        _ = step(&accumulator, "one two ", at: 3)
        var events = step(&accumulator, "one two ", at: 6)
        #expect(finals(events).map(\.text) == ["one"])
        events = step(&accumulator, "one two three", at: 7, isFinal: true)
        #expect(finals(events).map(\.text) == ["two three"])
    }

    @Test("boundaries do not reach a sentence-cutting accumulator")
    func markIsInertUnderEngineSegmentation() {
        var accumulator = StreamSegmentAccumulator(language: "en")
        accumulator.mark(end(1))
        accumulator.mark(end(2))
        // Cut by the sentence rule, at its own estimated time, exactly as it
        // would be with no boundary in sight.
        let cut = finals(step(&accumulator, "One. Two", at: 4))
        #expect(cut.map(\.text) == ["One."])
        #expect(cut.first?.end != 1)
        // What this does NOT check: that `mark` also drops the boundary rather
        // than queueing one nothing will ever read. That is a memory property
        // of a private field, invisible from out here, and it is guarded in the
        // source rather than pinned here - see `mark`.
    }

    @Test("segments never overlap, even on a boundary that goes backwards")
    func spansStayOrdered() {
        var accumulator = self.accumulator()
        // A boundary older than the previous cut, which this detector does not
        // produce and the wire must survive anyway. Both cases are here: one
        // that closes text, and one that lands on an empty pending buffer,
        // because those take different paths through the clock.
        accumulator.mark(end(8))
        var events = step(&accumulator, "first", at: 9)
        accumulator.mark(end(2))
        events += step(&accumulator, "first", at: 10)
        accumulator.mark(end(3))
        events += step(&accumulator, "first second", at: 11)
        // And a start that goes backwards, honored on an empty buffer, which is
        // the other way a segment could be given a beginning inside the one
        // before it.
        accumulator.mark(start(3))
        events += step(&accumulator, "first second", at: 11.5)
        events += step(&accumulator, "first second third", at: 12, isFinal: true)

        var previousEnd = 0.0
        for segment in finals(events) {
            #expect(segment.end >= segment.start, "\(segment.id): \(segment.start)..\(segment.end)")
            #expect(
                segment.start >= previousEnd,
                "\(segment.id) starts at \(segment.start), inside a segment ending at \(previousEnd)")
            previousEnd = segment.end
        }
        for segment in StreamSegmentAccumulatorTests.partials(events) {
            #expect(segment.end >= segment.start)
        }
    }
}
