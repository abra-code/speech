// FluidStreamingSegments.swift - the mapping from a cache-aware streaming
// manager's growing transcript to segments on the wire.
//
// This is the fourth streaming shape in the program and the second one to
// arrive from FluidAudio. `SlidingWindowAsrManager` hands over windows, one
// finished piece of text at a time; the two managers here hand over a
// transcript that only ever grows, plus per-token timings on the same absolute
// clock. Neither says where one utterance ended, so this file has to decide -
// and the rule it uses is the shared one, `StreamSegmentAccumulator`, which the
// ggml rows already drive for exactly the same reason.
//
// What the timings add on top of that rule is worth two things the ggml rows
// cannot have:
//
//   1. A segment's span comes from the tokens its text is made of, rather than
//      from interpolating a character position into a time range. The
//      accumulator still decides *where* to cut; the clock says *when* the cut
//      happened.
//   2. Word timestamps, which these rows' batch paths already produce, so live
//      and batch describe a transcript the same way.
//
// The text itself is always the manager's own decode, never a re-join of the
// word list. That is deliberate, and it is why the words are matched against
// the text rather than substituted for it: `speech eval --live` scores a row
// against that same row's batch WER, and a transcript assembled here by a
// different route would put a spacing artifact of ours into the comparison.
// Where the two disagree the text wins, and the segment carries no words and
// keeps the accumulator's estimated span.
//
// That is reachable in the scripts that do not separate words. The word-
// boundary marker is much rarer in those vocabularies - of this model's 13087
// pieces, 206 CJK carry it against 6704 that do not - so a `zh` or `ja` segment
// can easily contain no marked piece at all, and then its one "word" is the
// whole run and matches no single sentence. It is worth being precise about
// what does NOT go wrong there, because the first version of this comment
// claimed it did: the marker still becomes a space in the decoded text, so
// where marked pieces do occur the words line up with the text exactly as they
// do in English, and the spans are as exact. What degrades is the granularity,
// not the correctness.
//
// The word list arrives whole rather than as a delta, and that is the one
// non-obvious thing in this file. Words are grouped from tokens by a
// left-to-right scan, so every word but the last is settled; the last one is
// still growing, and a delta would publish `hel` as a finished word the moment
// the next chunk was about to make it `hello`. Taking the list whole means the
// frontier word is simply replaced on the next poll.

import Foundation
import SpeechCore

struct FluidStreamingSegments {
    /// Word payloads are gated on this. Spans are not, and that distinction is
    /// the defect the sliding-window mapping shipped with: gating the timing
    /// computation left every segment at `start == end == 0` for any caller
    /// that did not ask for words, so the session clock never advanced and
    /// every `--refine` slice came back empty.
    var wantWords: Bool

    private let segmentation: LiveSegmentation
    private var accumulator: StreamSegmentAccumulator
    /// Every word decoded so far, replaced on each poll.
    private var words: [Word] = []
    /// How many of them are already inside a closed segment.
    private var consumed = 0

    init(
        language: String?,
        wantWords: Bool,
        maxUtteranceSeconds: Double = 15,
        segmentation: LiveSegmentation = .engine
    ) {
        self.wantWords = wantWords
        self.segmentation = segmentation
        self.accumulator = StreamSegmentAccumulator(
            maxUtteranceSeconds: maxUtteranceSeconds, language: language,
            segmentation: segmentation)
    }

    /// Where the audio said speech started or stopped. Straight through to the
    /// accumulator, which owns every cut; nothing in this file has an opinion
    /// about boundaries, only about the span and the words a cut piece gets.
    mutating func mark(_ boundary: SpeechBoundary) {
        accumulator.mark(boundary)
    }

    /// The segments that went out, carrying the spans this file corrected.
    ///
    /// Not `accumulator.finals`, and the difference is the whole reason this
    /// property exists: the accumulator's copy holds the estimated span it cut
    /// on, so returning that from `finish()` would hand the caller a transcript
    /// disagreeing with the events the same session published.
    private(set) var finals: [Segment] = []

    /// Fold one poll of the manager in, and say what to emit.
    ///
    /// - Parameters:
    ///   - transcript: everything decoded so far. Append-only: these managers
    ///     accumulate decoded tokens and never revise one.
    ///   - words: those same tokens grouped into words, on the audio's own
    ///     clock, oldest first - the whole list, not what is new since the last
    ///     call.
    ///   - receivedSeconds: audio handed to the manager so far. It is what a
    ///     partial claims to end at, which is the honest answer for text that
    ///     is still growing.
    ///   - isFinal: the flush at end of stream.
    mutating func absorb(
        transcript: String,
        words: [Word],
        receivedSeconds: Double,
        isFinal: Bool
    ) -> [LiveEvent] {
        // Defensive, and cheap: a shrinking list would index off the end of the
        // world below. The contract is append-only.
        self.words = words
        consumed = min(consumed, words.count)

        // Where the transcript reaches on the audio clock. The last word's end
        // rather than the audio position, because those are different facts:
        // audio has been fed that the manager has not decoded into anything
        // yet, and claiming a segment covers it would put silence in a span.
        //
        // With no timings at all it degrades to the audio position, which is
        // what the ggml rows have always used. That case should not arise -
        // both managers record a timing for every token they emit - but the
        // alternative reading of "no words" is that every segment sits at zero,
        // which would leave `--refine` slicing nothing at all.
        let committed = words.last?.end ?? receivedSeconds
        // Copies rather than captures of `self`: the parameter is optional,
        // which makes the closure escaping, and an escaping closure cannot
        // capture a mutating `self` at all. Both copies are cheap - an array
        // reference and an Int - and nothing mutates them while it runs.
        let clock = words
        let published = consumed
        let events = accumulator.absorb(
            committed: transcript,
            tentative: "",
            committedMs: Int64((committed * 1000).rounded()),
            receivedMs: Int64((max(committed, receivedSeconds) * 1000).rounded()),
            isFinal: isFinal,
            // What the ggml rows cannot answer and these rows can: how much of
            // the pending text was spoken before a boundary. Without it a cut
            // takes the text as it stands, and on a real pause that is one
            // decode step too much - the commit that carries the watermark past
            // the boundary is the one carrying the next utterance's first
            // words. `consumed` is where the pending text begins in this list,
            // so the scan runs over exactly the words the accumulator holds.
            //
            // **Selected on `start`, not on `end`, and that is not a detail.**
            // Sentence-final punctuation is decoded late: the RNN-T decoder
            // emits `.` once it has evidence the sentence ended, which is at or
            // after the next utterance's onset, and `buildWordTimings` glues a
            // piece carrying no word-boundary marker onto the word before it.
            // So `certainty.` starts at 9.84 s and ends at 13.20 on a pause
            // that began around 10.2. Selecting on `end <= boundary` therefore
            // drops the last word of every sentence, and measured on one
            // recording it cut each segment three seconds early with the
            // sentence's own ending leading the next one. Where a word starts
            // is what says which side of a pause it was spoken on.
            //
            // The answer is in Characters rather than words because the scan
            // is what locates it: matching the word texts against the pending
            // text works in a script that separates words and in one that does
            // not, while a count of words in Chinese would be a count of
            // whitespace runs, of which there are none.
            settledText: { boundary, pending in
                let settled = clock[published...].prefix { $0.start < boundary }
                guard !settled.isEmpty else { return 0 }
                let located = Self.locate(settled, in: pending)
                // Nothing matched from any starting point, with words that
                // should have been there: the two lists disagree about the
                // text itself. Say "I cannot tell" rather than "none of it",
                // which would hold this utterance open until the backstop and
                // every one after it; the accumulator then cuts the way a row
                // with no word clock does.
                guard located.scan.matched > 0 else { return nil }
                return pending.distance(from: pending.startIndex, to: located.scan.end)
            })

        // A loop rather than `map`: `close` mutates `self`, and mutating self
        // inside a closure reading `events` is an overlapping access.
        var mapped: [LiveEvent] = []
        mapped.reserveCapacity(events.count)
        for event in events {
            switch event {
            case .final(let segment): mapped.append(.final(close(segment)))
            case .partial(let segment): mapped.append(.partial(open(segment)))
            }
        }
        return mapped
    }

    /// A closing segment, with its span and words taken from the tokens its
    /// text is made of.
    private mutating func close(_ segment: Segment) -> Segment {
        var segment = segment
        let floor = finals.last?.end ?? 0
        // Where a boundary cut is authoritative and the word clock is not. The
        // last word before a pause is the one carrying the sentence's final
        // punctuation, and that piece is decoded at the next utterance's onset,
        // so the word's end runs past the silence - the span would cover it and
        // `--refine` would re-transcribe it. Under `.engine` the
        // accumulator's end is a character-fraction estimate and the word clock
        // really is the better answer, which is why this is not simply a `min`
        // for both.
        let ceiling = segmentation == .vad ? segment.end : Double.infinity
        // `locate` rather than `match`, for the case where the cursor has
        // drifted: a word whose text has already gone out sits at the front of
        // the list, and an anchored scan cannot get past it. Skipping leading
        // words is safe in a way that skipping *forward inside the text* is
        // not - the anchor stays at the front of this segment's text, so a
        // one-character word cannot be found in the middle of a later sentence.
        let located = Self.locate(words[consumed...], in: segment.text)
        let matched = Self.covering(located, of: segment.text, in: words[consumed...])
        if !matched.isEmpty {
            let first = matched[matched.startIndex].start
            let last = min(matched[matched.index(before: matched.endIndex)].end, ceiling)
            // Clamped forward rather than monotonic by construction, which is
            // what this comment used to claim and what a review disproved.
            // Token times are a frame index times 0.08 s, and the decoder emits
            // several tokens on one frame, so a word boundary falling between
            // two tokens of the same frame gives the next word a start 40 ms
            // before the previous word's end. The overlap is real; two segments
            // covering the same instant is not something the wire format can
            // say, so the span moves and the word timings keep the times the
            // audio had.
            segment.start = first
            segment.end = max(first, last)
            if wantWords {
                var payload = Array(matched)
                // The same clamp, applied to the one word it can reach: the
                // last word of a segment cut at a pause is the one carrying the
                // late-decoded full stop. Leaving it would publish a word that
                // ends after the segment holding it.
                if let index = payload.indices.last, payload[index].end > segment.end {
                    payload[index].end = max(payload[index].start, segment.end)
                }
                segment.words = payload
            }
        }
        // Outside the branch, because the branch is not where the overlap
        // comes from. A final whose words matched publishes an end taken from
        // the audio, which is routinely later than the character-fraction
        // estimate the accumulator cut on - so the NEXT final, if its words do
        // not match and it keeps that estimate, opens behind the one before it.
        // The clamp belongs to every segment, not to the ones that matched.
        segment.start = max(segment.start, floor)
        segment.end = max(segment.start, segment.end)
        // Past the words this segment published. On a match the count is exact.
        // When the match failed - the text and the word list disagree, which
        // this file's header says is reachable - nothing in the text says which
        // words were published, so the resynchronization is on the clock
        // instead: every word that started before this segment ended was inside
        // it. Without that, `consumed` stayed one word behind for the rest of
        // the session, because the word that straddles a boundary is exactly
        // the one the end-time loop below cannot drop - so every later cut took
        // one word too few and no later segment carried words at all.
        if !matched.isEmpty {
            consumed += located.skipped + matched.count
        } else if located.scan.matched > 0 {
            // A partial match: the text this segment published covers some of
            // the words and then stops agreeing. Advancing by what was found is
            // a better answer than either extreme, and it is what keeps the
            // next cut anchored.
            consumed += located.skipped + located.scan.matched
        } else {
            // Nothing matched from anywhere: the text cannot say which words
            // went out, so the clock does - every word that started before this
            // segment ended was inside it. The re-anchor above would recover
            // without this on the next poll, and what this adds is a guarantee
            // of *progress*: a session whose two lists never agree would
            // otherwise leave the cursor at zero and rescan a growing list on
            // every poll.
            while consumed < words.count, words[consumed].start < segment.end {
                consumed += 1
            }
        }
        while consumed < words.count, words[consumed].end <= segment.end {
            consumed += 1
        }
        finals.append(segment)
        return segment
    }

    /// A partial, whose start is known exactly once its first word is decoded.
    ///
    /// No words on the payload: a partial is text that is still growing, and
    /// its last word is the one most likely to change.
    ///
    /// Clamped forward for the same reason a final is, and against the same
    /// floor. The word that opens a partial is often the one that straddled the
    /// last segment's boundary, so this is not the rarer case of the two.
    private func open(_ segment: Segment) -> Segment {
        var segment = segment
        // The clamp first and the frontier word second, because the case with
        // no frontier word is the one that needs it most: the drop loop takes
        // any word ending exactly where the segment did, which two tokens on
        // one encoder frame produce, and then a partial with no word to open on
        // would keep the accumulator's estimate and sit behind the final before
        // it.
        let floor = finals.last?.end ?? 0
        segment.start = max(consumed < words.count ? words[consumed].start : segment.start, floor)
        segment.end = max(segment.start, segment.end)
        return segment
    }

    /// The words that make up `text`, or nothing at all.
    ///
    /// A scan rather than a count, because the two lists are built by different
    /// code paths in the library - the text by the tokenizer's decoder, the
    /// words by grouping raw token pieces on their boundary marker - and the
    /// only thing making them the same transcript is that they came from the
    /// same tokens.
    ///
    /// Two rules, and a review earned both.
    ///
    /// **Anchored.** Each word must sit at the position the scan has reached,
    /// with only whitespace skipped, rather than anywhere after it. A search
    /// that may skip forward will happily find a one-character word like `!`
    /// inside the middle of the next sentence and hand that sentence the span
    /// of a token from the previous one.
    ///
    /// **All or nothing.** A scan that stops part way through the text returns
    /// nothing rather than a prefix. A prefix looks like a partial success and
    /// is worse than a failure: its last word ends where the scan stopped, so
    /// the segment is published ending in the middle of itself, and everything
    /// that trusts the span - the refinement slice, the audio buffer's discard
    /// point - is cut short with no signal that anything went wrong. Falling
    /// back to the accumulator's estimate is a worse span but an honest one.
    static func match(_ words: ArraySlice<Word>, to text: String) -> ArraySlice<Word> {
        let scan = Self.scan(words, into: text)
        var index = scan.end
        // Trailing whitespace is not a word, and the accumulator trims it
        // anyway; anything else left over means these words are not this text.
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index == text.endIndex else { return words.prefix(0) }
        return words.prefix(scan.matched)
    }

    /// The best anchored match of `words` at the front of `text`, allowing for
    /// a cursor that has drifted past words whose text already went out.
    ///
    /// Tries each starting point in order and stops at the first that matches
    /// anything. The scan itself stays anchored at the front of the text, which
    /// is the rule that matters: a search allowed to skip forward *inside* the
    /// text will find a one-character word like `!` in the middle of the next
    /// sentence and hand it that sentence's span. Skipping leading *words* has
    /// no such hazard - it only asks "does this text begin with that word".
    ///
    /// It exists because one disagreement between the two lists used to be
    /// permanent: with the cursor stuck on a word the text no longer contains,
    /// every later scan failed at position 0, so every later cut fell back to
    /// the no-clock rule and no later segment carried words at all.
    static func locate(
        _ words: ArraySlice<Word>, in text: String
    ) -> (skipped: Int, scan: (matched: Int, end: String.Index)) {
        for start in words.indices {
            let scan = Self.scan(words[start...], into: text)
            if scan.matched > 0 {
                return (words.distance(from: words.startIndex, to: start), scan)
            }
        }
        return (0, (0, text.startIndex))
    }

    /// The words a located scan covers, or nothing when they do not cover the
    /// whole text - the all-or-nothing rule `match` documents, applied to a
    /// scan that may have skipped a stale word first.
    static func covering(
        _ located: (skipped: Int, scan: (matched: Int, end: String.Index)),
        of text: String,
        in words: ArraySlice<Word>
    ) -> ArraySlice<Word> {
        guard located.scan.matched > 0 else { return words.prefix(0) }
        var index = located.scan.end
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index == text.endIndex else { return words.prefix(0) }
        let start = words.index(words.startIndex, offsetBy: located.skipped)
        return words[start...].prefix(located.scan.matched)
    }

    /// How far the leading `words` reach into `text`, by the anchored scan.
    ///
    /// The shared half of three questions: which words make up a finished
    /// segment (`match`, which additionally requires them to reach the end of
    /// it), how many words a segment published when that check failed, and
    /// where in the pending text a boundary falls. Answering all three with one
    /// scan is what keeps them from disagreeing - a cut placed by one rule and
    /// a payload matched by another would put a word in a segment whose span
    /// does not contain it.
    static func scan(_ words: ArraySlice<Word>, into text: String) -> (matched: Int, end: String.Index) {
        var index = text.startIndex
        var matched = 0
        for word in words {
            var cursor = index
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard !word.text.isEmpty, text[cursor...].hasPrefix(word.text) else { break }
            index = text.index(cursor, offsetBy: word.text.count)
            matched += 1
        }
        return (matched, index)
    }
}
