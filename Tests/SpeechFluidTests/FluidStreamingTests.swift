// FluidStreamingTests.swift - the cache-aware streaming mapping and the
// session lifecycle around it, both without a model.
//
// The two rows this covers cannot be constructed in a test: between them they
// want seven compiled CoreML bundles and about a gigabyte of weights. That is
// the same wall the sliding-window row hit, and it is why the mapping is a
// plain struct and the session takes its manager behind a protocol - a fake
// backend is four lines, and the lifecycle is where the last two reviews found
// every defect worth finding.

import AVFoundation
import Foundation
import Testing

@testable import SpeechCore
@testable import SpeechFluid

@Suite("Fluid streaming segments")
struct FluidStreamingSegmentsTests {
    static func words(_ entries: [(String, Double, Double)]) -> [Word] {
        entries.map { Word(text: $0.0, start: $0.1, end: $0.2) }
    }

    static func segment(_ event: LiveEvent?) -> Segment? {
        switch event {
        case .final(let segment), .partial(let segment): return segment
        case nil: return nil
        }
    }

    static func finals(_ events: [LiveEvent]) -> [Segment] {
        events.compactMap { if case .final(let segment) = $0 { return segment } else { return nil } }
    }

    static func partials(_ events: [LiveEvent]) -> [Segment] {
        events.compactMap { if case .partial(let segment) = $0 { return segment } else { return nil } }
    }

    @Test("text with no sentence in it is a partial and nothing else")
    func partialUntilSentence() {
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "hello there",
            words: Self.words([("hello", 0.5, 1.0), ("there", 1.0, 1.5)]),
            receivedSeconds: 2.0,
            isFinal: false)

        #expect(Self.finals(events).isEmpty)
        let partial = Self.partials(events).first
        #expect(partial?.text == "hello there")
        // The start is the first word's, not the accumulator's zero: a partial
        // that claims to begin at the top of the session would make every
        // refinement slice start there too.
        #expect(partial?.start == 0.5)
        // The end is the audio position. The text is still growing, and the
        // honest answer for where it reaches is what has been heard.
        #expect(partial?.end == 2.0)
        // No words on a partial: its last one is the most likely to change.
        #expect(partial?.words == nil)
    }

    @Test("a closed segment takes its span from the words its text is made of")
    func spanFromWords() {
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "hello there. bye",
            words: Self.words([("hello", 0.5, 1.0), ("there.", 1.0, 1.5), ("bye", 2.0, 2.4)]),
            receivedSeconds: 2.6,
            isFinal: false)

        let final = Self.finals(events).first
        #expect(final?.text == "hello there.")
        // The accumulator cut this sentence at 1.8 s by interpolating the
        // character position into the time range. The words say 1.5, which is
        // when the speaker actually stopped saying it.
        #expect(final?.start == 0.5)
        #expect(final?.end == 1.5)
        #expect(final?.words?.map(\.text) == ["hello", "there."])

        // And the word that belongs to the next sentence stayed there.
        let partial = Self.partials(events).first
        #expect(partial?.text == "bye")
        #expect(partial?.start == 2.0)
    }

    // MARK: - Boundary cuts

    @Test("a boundary cuts the words spoken before it, not the text as it stands")
    func boundaryCutsOnTheWordClock() {
        var mapper = FluidStreamingSegments(
            language: "en-US", wantWords: true, segmentation: .vad)
        mapper.mark(SpeechBoundary(kind: .end, seconds: 2.0))
        // One poll carrying both sides of the pause, which is what a real one
        // does: the commit that takes the watermark past the boundary is the
        // one that decoded the next utterance's first words. Cutting "the text
        // as it stands" would put "next up" in the first segment.
        let events = mapper.absorb(
            transcript: "hello there. next up",
            words: Self.words([
                ("hello", 0.5, 1.0), ("there.", 1.0, 2.0),
                ("next", 3.0, 3.2), ("up", 3.2, 3.4),
            ]),
            receivedSeconds: 3.6,
            isFinal: false)

        let final = Self.finals(events).first
        #expect(final?.text == "hello there.")
        #expect(final?.start == 0.5)
        #expect(final?.end == 2.0, "the boundary, not the last word's end")
        #expect(Self.partials(events).first?.text == "next up")
    }

    @Test("the last word before a pause is counted by where it started")
    func lastWordIsCountedByItsStart() {
        // The trap this exists for, measured on a real recording: sentence-final
        // punctuation is decoded late - the decoder emits "." once it has
        // evidence the sentence ended, which is at or after the next
        // utterance's onset - and the word grouping glues it onto the word
        // before it. So "certainty." starts at 9.84 s and ends at 13.20 on a
        // pause that began around 10.2, while a word carrying no punctuation
        // ends 80 ms after its last piece was decoded. Selecting words whose end is before the
        // boundary therefore drops the last word of every sentence, and each
        // segment lands three seconds early with its own ending leading the
        // next one.
        var mapper = FluidStreamingSegments(
            language: "en-US", wantWords: true, segmentation: .vad)
        mapper.mark(SpeechBoundary(kind: .end, seconds: 10.5))
        let events = mapper.absorb(
            transcript: "with 100% certainty. 20th century research",
            words: Self.words([
                ("with", 8.0, 8.2), ("100%", 8.2, 9.8), ("certainty.", 9.8, 13.4),
                ("20th", 13.4, 13.6), ("century", 13.6, 14.0), ("research", 14.0, 14.4),
            ]),
            receivedSeconds: 14.6,
            isFinal: false)

        let final = Self.finals(events).first
        #expect(final?.text == "with 100% certainty.")
        // And the span stops at the pause rather than at the word's recorded
        // end, which is a time inside the silence.
        #expect(final?.end == 10.5)
        #expect(final?.words?.last?.end == 10.5, "no word may end after the segment holding it")
    }

    @Test("a boundary the words have not reached leaves the text alone")
    func boundaryWaitsForTheWords() {
        var mapper = FluidStreamingSegments(
            language: "en-US", wantWords: true, segmentation: .vad)
        mapper.mark(SpeechBoundary(kind: .end, seconds: 5.0))
        // Nothing decoded past the boundary yet, so nothing can be cut at it:
        // the words after it may still be coming.
        var events = mapper.absorb(
            transcript: "still going",
            words: Self.words([("still", 3.0, 3.4), ("going", 3.4, 4.0)]),
            receivedSeconds: 4.2,
            isFinal: false)
        #expect(Self.finals(events).isEmpty)

        events = mapper.absorb(
            transcript: "still going and then more",
            words: Self.words([
                ("still", 3.0, 3.4), ("going", 3.4, 4.0), ("and", 4.2, 4.6),
                ("then", 6.0, 6.4), ("more", 6.4, 6.8),
            ]),
            receivedSeconds: 7.0,
            isFinal: false)
        #expect(Self.finals(events).map(\.text) == ["still going and"])
        // The boundary is a ceiling, not a floor: the words stop at 4.6, and a
        // span running on to 5.0 would be claiming 0.4 s of silence that the
        // detector's own padding put there.
        #expect(Self.finals(events).first?.end == 4.6)
    }

    @Test("a cut lands between words in a script that writes no spaces")
    func boundaryCutsCJK() {
        // The rows that stream here list zh-CN and ja-JP, and their text has no
        // whitespace at all. A cut placed by counting words would have nothing
        // to count and would take the whole pending text - including the
        // utterance after the pause, whose word then starts after the segment
        // holding it ends.
        var mapper = FluidStreamingSegments(
            language: "zh-CN", wantWords: true, segmentation: .vad)
        mapper.mark(SpeechBoundary(kind: .end, seconds: 2.1))
        let first = "\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{5F88}\u{597D}"
        let second = "\u{660E}\u{5929}\u{4E5F}\u{4E0D}\u{9519}"
        let events = mapper.absorb(
            transcript: first + second,
            words: [
                Word(text: first, start: 0.5, end: 2.0),
                Word(text: second, start: 3.0, end: 4.0),
            ],
            receivedSeconds: 4.2,
            isFinal: false)

        let final = Self.finals(events).first
        #expect(final?.text == first)
        #expect(final?.end == 2.0)
        #expect(final?.words?.map(\.text) == [first])
        // And the second utterance is still pending rather than published
        // inside a segment that ended before it was spoken.
        #expect(Self.partials(events).first?.text == second)
    }

    @Test("a segment whose words did not match does not strand one behind it")
    func aFailedMatchResynchronizes() {
        // The two lists are built by different code paths, so they can
        // disagree - here the tokenizer's text ends a word with a comma where
        // the word list has a period. The match fails and the segment keeps the
        // accumulator's span, which is this file's documented fallback. What
        // must not happen is the word list staying behind the text for the rest
        // of the session: the word that straddles a boundary is exactly the one
        // the end-time loop cannot drop, so every later cut would land by the
        // no-clock rule and no later segment would carry words at all.
        var mapper = FluidStreamingSegments(
            language: "en-US", wantWords: true, segmentation: .vad)
        mapper.mark(SpeechBoundary(kind: .end, seconds: 3.0))
        var events = mapper.absorb(
            transcript: "alpha beta, gamma",
            words: Self.words([
                ("alpha", 0.5, 1.0), ("beta.", 1.0, 6.0), ("gamma", 5.6, 6.0),
            ]),
            receivedSeconds: 6.2,
            isFinal: false)
        #expect(Self.finals(events).map(\.text) == ["alpha"])

        mapper.mark(SpeechBoundary(kind: .end, seconds: 5.5))
        events = mapper.absorb(
            transcript: "alpha beta, gamma",
            words: Self.words([
                ("alpha", 0.5, 1.0), ("beta.", 1.0, 6.0), ("gamma", 5.6, 6.0),
            ]),
            receivedSeconds: 6.4,
            isFinal: false)
        // The cut still happens - "I cannot tell" falls back to the rule a row
        // with no word clock gets, rather than holding the utterance open - and
        // this segment carries no words, because the text won.
        #expect(Self.finals(events).map(\.text) == ["beta,"])
        #expect(Self.finals(events).first?.words == nil)

        // And the session recovers even when the fallback cut published words
        // from after the boundary - which is the normal shape, since the commit
        // that carries the watermark past a pause carries the next utterance's
        // opening. The cursor is re-anchored by matching text, not by dropping
        // words whose start looks early: a rule keyed on time recovers only
        // when exactly one post-boundary word was published, and chains the
        // error forward on every other commit.
        mapper.mark(SpeechBoundary(kind: .end, seconds: 7.0))
        events = mapper.absorb(
            transcript: "alpha beta, gamma delta epsilon zeta",
            words: Self.words([
                ("alpha", 0.5, 1.0), ("beta.", 1.0, 6.0), ("gamma", 5.6, 6.0),
                ("delta", 6.5, 6.9), ("epsilon", 7.5, 7.9), ("zeta", 8.2, 8.6),
            ]),
            receivedSeconds: 8.8,
            isFinal: false)
        #expect(Self.finals(events).map(\.text) == ["gamma delta"])
        #expect(Self.finals(events).first?.words?.map(\.text) == ["gamma", "delta"])
    }

    @Test("a mismatch does not chain forward when the fallback published a late word")
    func aMismatchDoesNotChainForward() {
        // The shape a time-keyed resynchronization cannot handle. The fallback
        // cut publishes everything but the last word, and on a real pause that
        // includes words spoken *after* the boundary - which a rule that drops
        // words by their start time will not drop, because their start is late.
        // The cursor then points at a word whose text has gone out, every later
        // anchored scan fails at position 0, and every later cut falls back
        // again: a chain of segments taking the next utterance's opening word
        // and carrying no payload at all.
        var mapper = FluidStreamingSegments(
            language: "en-US", wantWords: true, segmentation: .vad)
        let words = Self.words([
            ("alpha", 0.5, 1.0), ("beta.", 1.0, 6.0), ("gamma", 5.6, 6.0),
            ("delta", 6.0, 6.4), ("epsilon", 7.5, 7.9), ("zeta", 8.2, 8.6),
        ])

        mapper.mark(SpeechBoundary(kind: .end, seconds: 3.0))
        var events = mapper.absorb(
            transcript: "alpha beta, gamma",
            words: Array(words.prefix(3)), receivedSeconds: 6.2, isFinal: false)
        #expect(Self.finals(events).map(\.text) == ["alpha"])

        // The disagreement: the text says `beta,` where the word list says
        // `beta.`, so the scan cannot place this cut and the no-clock rule
        // takes everything but the last word - publishing `gamma`, which was
        // spoken at 5.6, after this boundary.
        mapper.mark(SpeechBoundary(kind: .end, seconds: 5.5))
        events = mapper.absorb(
            transcript: "alpha beta, gamma delta",
            words: Array(words.prefix(4)), receivedSeconds: 6.6, isFinal: false)
        #expect(Self.finals(events).map(\.text) == ["beta, gamma"])
        #expect(Self.finals(events).first?.words == nil)

        // And the next cut is anchored again, by finding where in the word list
        // this text begins rather than by guessing from the clock.
        // 8.5 rather than 9.0: a boundary is honored once the engine has
        // decoded past it, and the last word here ends at 8.6.
        mapper.mark(SpeechBoundary(kind: .end, seconds: 8.5))
        events = mapper.absorb(
            transcript: "alpha beta, gamma delta epsilon zeta",
            words: words, receivedSeconds: 9.2, isFinal: false)
        #expect(Self.finals(events).map(\.text) == ["delta epsilon zeta"])
        #expect(
            Self.finals(events).first?.words?.map(\.text) == ["delta", "epsilon", "zeta"],
            "the payload comes back too, which is what says the cursor recovered")

        // And the cursor moved past the word the re-anchor skipped as well as
        // the ones it matched: the next partial opens on the next word decoded,
        // not on one already published.
        events = mapper.absorb(
            transcript: "alpha beta, gamma delta epsilon zeta eta",
            words: words + Self.words([("eta", 9.5, 9.9)]),
            receivedSeconds: 10.0,
            isFinal: false)
        #expect(Self.partials(events).first?.start == 9.5)
    }

    @Test("a boundary before any word publishes nothing and still moves the clock")
    func aBoundaryBeforeTheFirstWord() {
        // The detector heard speech the engine transcribed nothing from - room
        // noise, or a word too quiet to decode. "No word started before this
        // boundary" is a definite answer and not a disagreement, so the text
        // stays whole for the next segment rather than being cut by the
        // fallback rule.
        var mapper = FluidStreamingSegments(
            language: "en-US", wantWords: true, segmentation: .vad)
        mapper.mark(SpeechBoundary(kind: .end, seconds: 1.0))
        var events = mapper.absorb(
            transcript: "spoken after the noise",
            words: Self.words([
                ("spoken", 2.0, 2.4), ("after", 2.4, 2.8), ("the", 2.8, 3.0),
                ("noise", 3.0, 3.4),
            ]),
            receivedSeconds: 3.6,
            isFinal: false)
        #expect(Self.finals(events).isEmpty)

        mapper.mark(SpeechBoundary(kind: .end, seconds: 4.0))
        events = mapper.absorb(
            transcript: "spoken after the noise and then more",
            words: Self.words([
                ("spoken", 2.0, 2.4), ("after", 2.4, 2.8), ("the", 2.8, 3.0),
                ("noise", 3.0, 3.4), ("and", 4.5, 4.7), ("then", 4.7, 5.0),
                ("more", 5.0, 5.4),
            ]),
            receivedSeconds: 5.6,
            isFinal: false)
        #expect(Self.finals(events).map(\.text) == ["spoken after the noise"])
    }

    @Test("under engine segmentation the word clock still owns the span")
    func engineModeKeepsItsSpans() {
        // The clamp above must not reach the default path: there the
        // accumulator's end is a character-fraction estimate and the words are
        // the better answer, which is the whole point of this file.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        mapper.mark(SpeechBoundary(kind: .end, seconds: 0.6))
        let events = mapper.absorb(
            transcript: "hello there. bye",
            words: Self.words([("hello", 0.5, 1.0), ("there.", 1.0, 1.5), ("bye", 2.0, 2.4)]),
            receivedSeconds: 2.6,
            isFinal: false)
        let final = Self.finals(events).first
        #expect(final?.text == "hello there.")
        #expect(final?.end == 1.5, "the words, not the boundary nobody asked to use")
    }

    @Test("the span survives wantWords being false")
    func spanIndependentOfWantWords() {
        // The regression this pins cost the sliding-window row every one of its
        // refinement slices: gating the timing computation on the payload flag
        // left every segment at 0..0. The payload is optional; the span is not.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: false)
        let events = mapper.absorb(
            transcript: "hello there.",
            words: Self.words([("hello", 0.5, 1.0), ("there.", 1.0, 1.5)]),
            receivedSeconds: 2.0,
            isFinal: true)

        let final = Self.finals(events).first
        #expect(final?.start == 0.5)
        #expect(final?.end == 1.5)
        #expect(final?.words == nil)
    }

    @Test("a growing word is corrected rather than published truncated")
    func frontierWordIsNotPublishedEarly() {
        // Why the word list arrives whole rather than as a delta. `hel` is a
        // real intermediate state - the tokenizer emits sub-word pieces - and a
        // delta would have published it as a finished word with an end time.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(
            transcript: "hel",
            words: Self.words([("hel", 0.5, 0.7)]),
            receivedSeconds: 0.8,
            isFinal: false)
        let events = mapper.absorb(
            transcript: "hello.",
            words: Self.words([("hello.", 0.5, 1.0)]),
            receivedSeconds: 1.2,
            isFinal: true)

        let final = Self.finals(events).first
        #expect(final?.text == "hello.")
        #expect(final?.words?.map(\.text) == ["hello."])
        #expect(final?.end == 1.0)
    }

    @Test("words that do not match the text are dropped, and the text is kept")
    func mismatchKeepsTheText() {
        // The failure worth having. A segment with no word timings is
        // incomplete; a segment whose word timings describe different text is
        // wrong, and nothing downstream can tell.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "hello there.",
            words: Self.words([("bonjour", 0.5, 1.0)]),
            receivedSeconds: 2.0,
            isFinal: true)

        let final = Self.finals(events).first
        #expect(final?.text == "hello there.")
        #expect(final?.words == nil)
        // The estimated span stands rather than being replaced by a word from
        // some other transcript.
        #expect(final?.end == 1.0)
    }

    @Test("consecutive segments do not share a word or overlap in time")
    func segmentsDoNotOverlap() {
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(
            transcript: "one. two. three.",
            words: Self.words([
                ("one.", 0.0, 1.0), ("two.", 1.2, 2.0), ("three.", 2.2, 3.0),
            ]),
            receivedSeconds: 3.2,
            isFinal: true)

        #expect(mapper.finals.map(\.text) == ["one.", "two.", "three."])
        #expect(mapper.finals.map(\.start) == [0.0, 1.2, 2.2])
        #expect(mapper.finals.map(\.end) == [1.0, 2.0, 3.0])
        for (earlier, later) in zip(mapper.finals, mapper.finals.dropFirst()) {
            #expect(later.start >= earlier.end)
        }
        // Each word landed in exactly one segment.
        let published = mapper.finals.flatMap { $0.words ?? [] }.map(\.text)
        #expect(published == ["one.", "two.", "three."])
    }

    @Test("the end of the stream closes text with no terminator")
    func flushClosesTheRemainder() {
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(
            transcript: "no full stop here",
            words: Self.words([("no", 0.0, 0.4), ("full", 0.4, 0.8),
                               ("stop", 0.8, 1.2), ("here", 1.2, 1.6)]),
            receivedSeconds: 1.8,
            isFinal: false)
        #expect(mapper.finals.isEmpty)

        let events = mapper.absorb(
            transcript: "no full stop here",
            words: Self.words([("no", 0.0, 0.4), ("full", 0.4, 0.8),
                               ("stop", 0.8, 1.2), ("here", 1.2, 1.6)]),
            receivedSeconds: 1.8,
            isFinal: true)
        #expect(Self.finals(events).map(\.text) == ["no full stop here"])
        #expect(Self.finals(events).first?.end == 1.6)
        // A flush publishes no partial - there is nothing left to revise.
        #expect(Self.partials(events).isEmpty)
    }

    @Test("a transcript with no timings still reaches the wire")
    func noTimingsAtAll() {
        // Should not happen: both managers record a timing for every token they
        // emit. If it ever does, losing the text would be far worse than losing
        // the span, and a span pinned at zero would leave every refinement
        // slice empty.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "text with no timings.",
            words: [],
            receivedSeconds: 4.0,
            isFinal: true)

        let final = Self.finals(events).first
        #expect(final?.text == "text with no timings.")
        #expect(final?.end == 4.0)
        #expect(final?.words == nil)
    }

    @Test("the language tag is stamped as a primary subtag")
    func languageTag() {
        var mapper = FluidStreamingSegments(language: "pl-PL", wantWords: true)
        let events = mapper.absorb(
            transcript: "dzien dobry.", words: Self.words([("dzien dobry.", 0, 1)]),
            receivedSeconds: 1, isFinal: true)
        #expect(Self.finals(events).first?.language == "pl")
    }

    @Test("matching takes the words this text is made of and leaves the rest")
    func matchTakesWhatTheTextCovers() {
        // Words past the end of the text are the next segment's, not a failure.
        let words = Self.words([("one", 0, 1), ("two", 1, 2), ("three", 2, 3)])
        let matched = FluidStreamingSegments.match(words[...], to: "one two")
        #expect(matched.map(\.text) == ["one", "two"])
    }

    @Test("a word list that covers only part of the text matches nothing")
    func partialCoverageIsNoMatch() {
        // All or nothing, and a review earned it. A prefix looks like a partial
        // success and is worse than a failure: the segment would be published
        // ending where the scan stopped - in the middle of itself - and the
        // refinement slice and the buffer's discard point would both be cut
        // short with nothing saying so. Here the tokenizer dropped `quick`.
        let words = Self.words([("The", 0, 0.4), ("brown", 0.8, 1.2), ("fox.", 1.2, 1.6)])
        #expect(FluidStreamingSegments.match(words[...], to: "The quick brown fox.").isEmpty)
    }

    @Test("a word is matched where it sits, not wherever it next appears")
    func matchIsAnchored() {
        // The unanchored version of this scan found a one-character word inside
        // the middle of the following sentence and handed that sentence the
        // span of a token from the previous one.
        let words = Self.words([("!", 0.96, 1.04), ("Wow!", 2.0, 2.4)])
        #expect(FluidStreamingSegments.match(words[...], to: "Wow!").isEmpty)
    }

    @Test("words sharing an encoder frame do not make segments overlap")
    func sharedFrameDoesNotOverlap() {
        // Token times are a frame index times 0.08 s and the decoder emits
        // several tokens on one frame, so a word boundary falling inside a
        // frame gives the next word a start before the previous word's end.
        // That is a real overlap in the audio and an impossible one on the
        // wire, so the span moves forward and the words keep their own times.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(
            transcript: "I saw a cat. A dog ran.",
            words: Self.words([
                ("I", 0.0, 0.24), ("saw", 0.24, 0.48), ("a", 0.48, 0.56), ("cat.", 0.56, 1.00),
                ("A", 0.96, 1.04), ("dog", 1.04, 1.40), ("ran.", 1.40, 1.80),
            ]),
            receivedSeconds: 2.0,
            isFinal: true)

        #expect(mapper.finals.map(\.text) == ["I saw a cat.", "A dog ran."])
        #expect(mapper.finals.map(\.start) == [0.0, 1.0])
        #expect(mapper.finals.map(\.end) == [1.0, 1.8])
        // The word keeps the time it was said at, which is before the segment
        // it belongs to is allowed to start.
        #expect(mapper.finals.last?.words?.first?.start == 0.96)
    }

    @Test("a partial cannot open before the last final closed either")
    func partialDoesNotReachBack() {
        // The straddling word is usually the one that opens the next partial,
        // so this is the commoner half of the same defect rather than the
        // rarer one.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "I saw a cat. A dog",
            words: Self.words([
                ("I", 0.0, 0.24), ("saw", 0.24, 0.48), ("a", 0.48, 0.56), ("cat.", 0.56, 1.00),
                ("A", 0.96, 1.04), ("dog", 1.04, 1.40),
            ]),
            receivedSeconds: 1.6,
            isFinal: false)

        #expect(Self.finals(events).map(\.end) == [1.0])
        let partial = Self.partials(events).first
        #expect(partial?.text == "A dog")
        #expect(partial?.start == 1.0)
    }

    @Test("a segment whose words do not match still cannot open behind the one before it")
    func unmatchedSegmentStaysMonotonic() {
        // The overlap does not come from the matched segments, it comes from
        // mixing the two clocks. A final that matched publishes an end taken
        // from the audio, which is later here than the character-fraction
        // estimate the accumulator cut on - so the next final, if its words do
        // not match and it keeps that estimate, opens 110 ms behind the final
        // before it.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "A very long first sentence indeed. Hi.",
            words: Self.words([
                ("A", 0.10, 0.20), ("very", 0.20, 0.60), ("long", 0.60, 0.90),
                ("first", 0.90, 1.20), ("sentence", 1.20, 1.60), ("indeed.", 1.60, 1.90),
                ("Bonjour", 1.95, 2.00),
            ]),
            receivedSeconds: 2.0,
            isFinal: true)

        let finals = Self.finals(events)
        #expect(finals.map(\.text) == ["A very long first sentence indeed.", "Hi."])
        #expect(finals.first?.end == 1.90)
        // Not the accumulator's estimate, which is behind that.
        #expect(finals.last?.start == 1.90)
        #expect(finals.last?.words == nil)
        for (earlier, later) in zip(finals, finals.dropFirst()) {
            #expect(later.start >= earlier.end)
        }
    }

    @Test("a partial with no word of its own still cannot open behind the last final")
    func partialWithNoFrontierWord() {
        // Reachable through the drop loop: it takes any word ending exactly
        // where the segment did, and two tokens landing on one encoder frame
        // produce exactly that. The partial is then left with no word to open
        // on, and without the clamp it falls back to an estimate that sits
        // behind the final just published.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "One. Two",
            words: Self.words([("One.", 0.0, 1.0), ("Two", 0.5, 1.0)]),
            receivedSeconds: 1.4,
            isFinal: false)

        #expect(Self.finals(events).map(\.end) == [1.0])
        let partial = Self.partials(events).first
        #expect(partial?.text == "Two")
        #expect(partial?.start == 1.0)
        #expect(partial?.end == 1.4)
    }

    @Test("words are consumed across polls, not rematched from the start")
    func consumedAcrossPolls() {
        // Nothing else drives `close` more than once, and the index that says
        // which words are already inside a segment only moves there.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let first = Self.words([("One.", 0.0, 0.8), ("Two", 1.0, 1.4)])
        _ = mapper.absorb(
            transcript: "One. Two", words: first, receivedSeconds: 1.5, isFinal: false)
        let second = first + Self.words([("more.", 1.4, 1.9), ("Three.", 2.1, 2.6)])
        _ = mapper.absorb(
            transcript: "One. Two more. Three.", words: second,
            receivedSeconds: 2.8, isFinal: true)

        #expect(mapper.finals.map(\.text) == ["One.", "Two more.", "Three."])
        #expect(mapper.finals.map(\.start) == [0.0, 1.0, 2.1])
        #expect(mapper.finals.map(\.end) == [0.8, 1.9, 2.6])
        #expect(mapper.finals.map { $0.words?.map(\.text) ?? [] }
            == [["One."], ["Two", "more."], ["Three."]])
    }

    @Test("a segment with no word boundary in it keeps its text and loses only its words")
    func scriptWithoutWordBoundaries() {
        // Reachable in the scripts that do not separate words. This model's
        // vocabulary marks a word start on 206 of its 6910 CJK pieces, so a
        // Japanese segment can easily contain none at all - and then the
        // joiner's one "word" spans the whole utterance and matches no single
        // sentence.
        //
        // What is asserted here is the safe degradation, not a claim about the
        // language: the text and the segmentation are right and the span falls
        // back to the accumulator's estimate. Where marked pieces DO occur the
        // words line up exactly as they do in English, because the detokenizer
        // renders each mark as a space - checked against the model's own
        // tokenizer.json, after the first version of this comment asserted the
        // opposite from reading the joiner alone.
        var mapper = FluidStreamingSegments(language: "ja-JP", wantWords: true)
        let events = mapper.absorb(
            transcript: "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{3002}\u{3055}\u{3088}\u{3046}\u{306A}\u{3089}\u{3002}",
            words: Self.words([("\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{3002}\u{3055}\u{3088}\u{3046}\u{306A}\u{3089}\u{3002}", 0.0, 2.0)]),
            receivedSeconds: 2.2,
            isFinal: true)

        #expect(Self.finals(events).map(\.text)
            == ["\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{3002}", "\u{3055}\u{3088}\u{3046}\u{306A}\u{3089}\u{3002}"])
        #expect(Self.finals(events).allSatisfy { $0.words == nil })
    }
}

/// A backend that hands over whatever the test scripted, so the session's
/// lifecycle can be driven without a model.
actor ScriptedStreamingBackend: FluidStreamingBackend {
    private var polls: [FluidStreamingPoll?]
    private let final: FluidStreamingPoll
    private let failOnFlush: Bool
    private(set) var resets = 0
    private(set) var feeds = 0

    init(polls: [FluidStreamingPoll?], final: FluidStreamingPoll, failOnFlush: Bool = false) {
        self.polls = polls
        self.final = final
        self.failOnFlush = failOnFlush
    }

    func feed(_ samples: [Float]) async throws -> FluidStreamingPoll? {
        feeds += 1
        guard !polls.isEmpty else { return nil }
        return polls.removeFirst()
    }

    func flush() async throws -> FluidStreamingPoll {
        if failOnFlush { throw SpeechError.runtime("the encoder gave up") }
        return final
    }

    func reset() async { resets += 1 }
}

/// A backend whose `feed` parks until the test lets it go, so `finish()` can be
/// made to land in the middle of a chunk decode.
actor GatedStreamingBackend: FluidStreamingBackend {
    private var release: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    private var feedArrived = false
    private let late: FluidStreamingPoll
    private let final: FluidStreamingPoll

    init(late: FluidStreamingPoll, final: FluidStreamingPoll) {
        self.late = late
        self.final = final
    }

    func feed(_ samples: [Float]) async throws -> FluidStreamingPoll? {
        feedArrived = true
        arrived?.resume()
        arrived = nil
        await withCheckedContinuation { release = $0 }
        return late
    }

    func flush() async throws -> FluidStreamingPoll { final }
    func reset() async {}

    /// Returns once `feed` has parked.
    func waitForFeed() async {
        if feedArrived { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func letFeedFinish() {
        release?.resume()
        release = nil
    }
}

@Suite("Fluid streaming session")
struct FluidStreamingSessionTests {
    static func poll(_ text: String, _ words: [(String, Double, Double)]) -> FluidStreamingPoll {
        FluidStreamingPoll(
            transcript: text,
            words: words.map { Word(text: $0.0, start: $0.1, end: $0.2) })
    }

    static func buffer(seconds: Double) -> CapturedAudio {
        let format = LiveAudioFormat.canonical
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: 0.01, count: Int(frames))
        return CapturedAudio(buffer)
    }

    static func collect(_ session: FluidStreamingSession) -> Task<[LiveEvent], Never> {
        let events = session.events
        return Task { var seen: [LiveEvent] = []; for await event in events { seen.append(event) }; return seen }
    }

    @Test("a session publishes partials, then a final, then closes its stream")
    func happyPath() async throws {
        let backend = ScriptedStreamingBackend(
            polls: [Self.poll("hello", [("hello", 0.0, 0.5)]), nil],
            final: Self.poll("hello there.", [("hello", 0.0, 0.5), ("there.", 0.5, 1.0)]))
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)

        try await session.feed(Self.buffer(seconds: 0.5))
        try await session.feed(Self.buffer(seconds: 0.5))
        let finals = try await session.finish()

        let events = await reader.value
        #expect(finals.map(\.text) == ["hello there."])
        #expect(finals.first?.end == 1.0)
        // Two feeds, one of which decoded nothing: the session must not have
        // published anything for the nil poll.
        #expect(events.count == 2)
        if case .partial(let partial) = events[0] {
            #expect(partial.text == "hello")
        } else {
            Issue.record("the first event was not a partial")
        }
        if case .final(let final) = events[1] {
            #expect(final.text == "hello there.")
        } else {
            Issue.record("the last event was not a final")
        }
        // The manager goes back to the engine clean, whichever way the session
        // ended.
        #expect(await backend.resets == 1)
    }

    @Test("a failed flush keeps the transcript and reports the failure every time")
    func flushFailureKeepsWork() async throws {
        let backend = ScriptedStreamingBackend(
            polls: [Self.poll("first sentence. second", [
                ("first", 0.0, 0.5), ("sentence.", 0.5, 1.0), ("second", 1.2, 1.6),
            ])],
            final: Self.poll("", []),
            failOnFlush: true)
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)
        try await session.feed(Self.buffer(seconds: 1.6))

        // The transcript travels with the error rather than being thrown away.
        await #expect(throws: LiveSessionFailure.self) { try await session.finish() }
        do {
            _ = try await session.finish()
            Issue.record("a repeated finish() reported a clean run")
        } catch let failure as LiveSessionFailure {
            #expect(failure.segments.map(\.text) == ["first sentence."])
        }
        _ = await reader.value
        #expect(await backend.resets == 1)
    }

    @Test("cancel closes the stream without flushing")
    func cancelDoesNotFlush() async throws {
        let backend = ScriptedStreamingBackend(
            polls: [Self.poll("half a sentence", [("half", 0.0, 0.5)])],
            final: Self.poll("should never be published.", []),
            failOnFlush: false)
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)

        try await session.feed(Self.buffer(seconds: 0.5))
        await session.cancel()

        let events = await reader.value
        #expect(events.count == 1)
        for event in events {
            if case .final(let segment) = event {
                Issue.record("cancel published a final: \(segment.text)")
            }
        }
        #expect(await backend.resets == 1)
    }

    @Test("a decode that lands after finish does not add a segment nobody saw")
    func feedResumingAfterFinish() async throws {
        // `feed` suspends for the length of a chunk decode, and a `finish()`
        // arriving in that gap publishes the final and closes the event stream.
        // Yielding into a closed continuation is a silent no-op, so without the
        // second check the resumed feed would append a segment to `finals` that
        // no reader ever saw - and the transcript returned by a repeated
        // `finish()` would disagree with the events the session published.
        // The late transcript has to CLOSE a sentence, not merely carry text.
        // The first version of this test ended it in a bare terminator, which
        // mid-stream is not a sentence at all - so the resumed feed emitted a
        // partial, nothing was appended to `finals`, and the test passed with
        // the guard deleted. It is append-only relative to what the flush
        // already published, the way these managers really behave.
        let backend = GatedStreamingBackend(
            late: Self.poll(
                "in time. far too late. and more",
                [("in", 0.0, 0.4), ("time.", 0.4, 0.8),
                 ("far", 2.0, 2.2), ("too", 2.2, 2.4), ("late.", 2.4, 2.8),
                 ("and", 3.0, 3.2), ("more", 3.2, 3.4)]),
            final: Self.poll("in time.", [("in", 0.0, 0.4), ("time.", 0.4, 0.8)]))
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)

        let feeding = Task { try await session.feed(Self.buffer(seconds: 0.5)) }
        await backend.waitForFeed()
        let finals = try await session.finish()
        await backend.letFeedFinish()
        try await feeding.value

        let events = await reader.value
        #expect(finals.map(\.text) == ["in time."])
        #expect(events.count == 1)
        // The transcript a second caller sees is the one that went out.
        let again = try await session.finish()
        #expect(again.map(\.text) == ["in time."])
    }

    @Test("feeding after finish is ignored rather than decoded")
    func feedAfterFinish() async throws {
        let backend = ScriptedStreamingBackend(
            polls: [Self.poll("one.", [("one.", 0.0, 0.5)])],
            final: Self.poll("one.", [("one.", 0.0, 0.5)]))
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)

        try await session.feed(Self.buffer(seconds: 0.5))
        _ = try await session.finish()
        try await session.feed(Self.buffer(seconds: 0.5))

        _ = await reader.value
        // One feed reached the backend. The second arrived after the stream was
        // closed, and yielding into a finished continuation is a silent no-op -
        // so the audio has to stop at the session rather than at the stream.
        #expect(await backend.feeds == 1)
    }
}
