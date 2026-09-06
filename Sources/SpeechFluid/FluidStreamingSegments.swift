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

    private var accumulator: StreamSegmentAccumulator
    /// Every word decoded so far, replaced on each poll.
    private var words: [Word] = []
    /// How many of them are already inside a closed segment.
    private var consumed = 0

    init(language: String?, wantWords: Bool, maxUtteranceSeconds: Double = 15) {
        self.wantWords = wantWords
        self.accumulator = StreamSegmentAccumulator(
            maxUtteranceSeconds: maxUtteranceSeconds, language: language)
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
        let events = accumulator.absorb(
            committed: transcript,
            tentative: "",
            committedMs: Int64((committed * 1000).rounded()),
            receivedMs: Int64((max(committed, receivedSeconds) * 1000).rounded()),
            isFinal: isFinal)

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
        let matched = Self.match(words[consumed...], to: segment.text)
        if !matched.isEmpty {
            let first = matched[matched.startIndex].start
            let last = matched[matched.index(before: matched.endIndex)].end
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
            if wantWords { segment.words = Array(matched) }
        }
        // Outside the branch, because the branch is not where the overlap
        // comes from. A final whose words matched publishes an end taken from
        // the audio, which is routinely later than the character-fraction
        // estimate the accumulator cut on - so the NEXT final, if its words do
        // not match and it keeps that estimate, opens behind the one before it.
        // The clamp belongs to every segment, not to the ones that matched.
        segment.start = max(segment.start, floor)
        segment.end = max(segment.start, segment.end)
        consumed += matched.count
        // Whether or not they matched. A word that ended before this segment
        // did belongs to audio the segment already covered, and carrying it
        // forward would put it inside the next segment's span.
        //
        // A word that straddles the boundary - it started inside this segment
        // and ends after it - is deliberately kept for the next one, since it
        // still has text nobody has published. What stops it opening that
        // segment behind this one is the clamp above, not this loop.
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
        var index = text.startIndex
        var matched = 0
        for word in words {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard !word.text.isEmpty, text[index...].hasPrefix(word.text) else { break }
            index = text.index(index, offsetBy: word.text.count)
            matched += 1
        }
        // Trailing whitespace is not a word, and the accumulator trims it
        // anyway; anything else left over means these words are not this text.
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index == text.endIndex else { return words.prefix(0) }
        return words.prefix(matched)
    }
}
