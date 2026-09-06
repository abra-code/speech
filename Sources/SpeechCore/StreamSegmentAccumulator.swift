// StreamSegmentAccumulator.swift - the state machine that turns a growing
// hypothesis into segments.
//
// Two engine families produce that shape and neither produces utterance
// boundaries: transcribe.cpp hands over a `committed` prefix plus a volatile
// suffix, and FluidAudio's two cache-aware streaming managers hand over a
// transcript that only ever grows. Both need the same decision made for them -
// where does one segment end and the next begin - so the rule lives here, in
// SpeechCore, rather than once per family.
//
// Extracted from `GGMLLiveSession` because it could not be tested there. The
// session is an actor that cannot be constructed without a `GGMLSession`, which
// needs a 750 MB GGUF and a Metal device, so every test written against it
// tested the one pure function that happened to be `static` - and a review's
// mutation matrix showed that function's coverage was already the only real
// coverage in the file. Three defects were sitting in the untested part: text
// lost at grapheme boundaries, punctuation-only segments, and decimals split at
// a commit boundary. All three are pinned by tests here now.
//
// The same argument moved it into SpeechCore: a fluid live session cannot be
// constructed without four compiled CoreML models, so a mapping that lived
// inside one would be just as untestable as this one was.
//
// A plain struct, deliberately: no isolation, no dependencies, one method that
// takes what a feed reported and returns what to emit.
//
// It now carries two boundary rules rather than one. `.engine` is the sentence
// scan below, which is all a row can do on its own. `.vad` takes cuts from
// `mark` - times a voice activity detector found in the audio - and the
// difference is not a refinement of the same idea: the sentence rule decides
// *where* from text and estimates *when* by interpolating a character position
// into a commit span, while a boundary is a measured time and carries no
// opinion about the text at all. What survives in both modes is the backstop,
// because neither rule is guaranteed to fire: a model can drop punctuation, and
// a speaker can talk for a minute without pausing.

import Foundation

public struct StreamSegmentAccumulator {
    /// Close a segment after this much audio even with no punctuation in sight.
    ///
    /// A speaker who does not pause, a model that drops punctuation, or a
    /// language whose sentences run long would otherwise produce one segment
    /// covering the whole session - which reaches the transcript as a single
    /// unbreakable paragraph and gives refinement one enormous span to chew on.
    public var maxUtteranceSeconds: Double = 15
    /// Stamped on every segment, as a primary subtag.
    public var language: String?
    /// Which rule cuts. Fixed at construction: a run that changed its mind
    /// halfway would produce a transcript segmented two ways with nothing
    /// saying where the join was.
    public let segmentation: LiveSegmentation

    public private(set) var finals: [Segment] = []

    /// Unicode scalars of `committed` already folded into a segment.
    ///
    /// Scalars, not Characters, and that distinction is the whole reason this
    /// is a named field rather than an index. A commit can *extend an existing
    /// grapheme cluster* rather than append a new one - `e` becoming `e` plus a
    /// combining acute, a Hangul jamo composing into a syllable, a Devanagari
    /// consonant taking a virama. The Character count does not change, so a
    /// Character watermark sees no new text and drops the scalars silently: no
    /// error, no event, just a wrong transcript. The rows that stream here list
    /// ko-KR, hi-IN, vi-VN, zh-CN, fr-FR and cs-CZ, which is exactly where a
    /// byte-level tokenizer commits prefixes that end mid-cluster.
    ///
    /// Scalars are exact for a string the library documents as append-only. A
    /// revision that keeps the same length - `their` becoming `there` - is
    /// outside that contract and is not detectable by any count; it would also
    /// be unfixable, since the earlier text has already been emitted.
    private var consumedScalars = 0
    private var pendingText = ""
    private var pendingStart: Double = 0
    private var lastPartialText = ""
    private var nextID = 0

    /// Boundaries reported but not yet reached by the committed audio.
    ///
    /// Bounded by the engine's own commit lag rather than by a cap, and the
    /// difference matters: a boundary is honored as soon as the engine has
    /// decoded past it, so this holds one entry per utterance boundary inside
    /// the lag - a handful. The case that would grow it without limit is an
    /// engine that has stopped committing entirely, and that session is already
    /// dropping audio and saying so.
    private var boundaries: [SpeechBoundary] = []
    /// A cut that could not be made without breaking a word in half, carried to
    /// the next commit. See `closeAtBoundaries`.
    private var deferredCut: Double?
    /// The start that was carried with it, so the segment the carried cut
    /// eventually opens does not begin in the silence before its speech.
    private var deferredStart: Double?

    public init(
        maxUtteranceSeconds: Double = 15,
        language: String? = nil,
        segmentation: LiveSegmentation = .engine
    ) {
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.language = language
        self.segmentation = segmentation
    }

    /// Record where the audio said speech started or stopped.
    ///
    /// Not acted on here. A boundary is a time, and the text that belongs to it
    /// does not exist until the engine has decoded that far, so the cut happens
    /// in `absorb` when the commit watermark passes it - which is also what
    /// makes the rule work with an engine running seconds behind the speaker.
    ///
    /// Ignored under `.engine`, rather than quietly changing the rule: which
    /// segmenter is running is a property of the run, and a caller that marks
    /// boundaries into a sentence-cutting accumulator has a wiring bug, not a
    /// second opinion.
    public mutating func mark(_ boundary: SpeechBoundary) {
        guard segmentation == .vad else { return }
        boundaries.append(boundary)
    }

    /// Fold one feed's result in, and say what to emit.
    ///
    /// - Parameter isFinal: this is the flush at end of stream. It closes
    ///   whatever is pending and suppresses the partial, and it is also what
    ///   makes "a terminator at the end of the text" count as a sentence - see
    ///   `endOfFirstSentence`.
    /// - Parameter settledText: given a boundary and the text pending, how many
    ///   of that text's Characters were spoken before it - for a caller that
    ///   has a word clock. Without it a boundary cut can only take the text as
    ///   it stands, which is a decode step too much - see `closeAtBoundaries`.
    ///   In Characters rather than in words because the languages that need
    ///   this most write no spaces: a count of words is a count of whitespace
    ///   runs, and Chinese has none. Nil is "I cannot tell" - the caller's word
    ///   list and this text disagree - and falls back to the rule a caller with
    ///   no clock at all gets. Never called under `.engine`.
    public mutating func absorb(
        committed: String,
        tentative: String,
        committedMs: Int64,
        receivedMs: Int64,
        isFinal: Bool,
        settledText: ((Double, String) -> Int?)? = nil
    ) -> [LiveEvent] {
        let committedSeconds = max(0, Double(committedMs) / 1000)
        let receivedSeconds = max(committedSeconds, Double(receivedMs) / 1000)

        let scalars = committed.unicodeScalars
        // Defensive: the contract is append-only, and if a family ever breaks
        // it the watermark would index past the end and take the run with it.
        if scalars.count < consumedScalars { consumedScalars = scalars.count }
        if scalars.count > consumedScalars {
            pendingText += String(String.UnicodeScalarView(scalars.dropFirst(consumedScalars)))
            consumedScalars = scalars.count
        }

        var events: [LiveEvent]
        switch segmentation {
        case .engine:
            events = closeSentences(committedThrough: committedSeconds, atEnd: isFinal)
        case .vad:
            events = closeAtBoundaries(
                committedThrough: committedSeconds, settledText: settledText)
        }

        let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let longEnough = committedSeconds - pendingStart >= maxUtteranceSeconds
        if !trimmed.isEmpty, isFinal || longEnough {
            // The flush takes everything - there is no next commit to finish a
            // word in - while the backstop leaves the last word behind for the
            // same reason a boundary cut does.
            if isFinal {
                events.append(.final(emitFinal(text: trimmed, end: committedSeconds)))
            } else if let (head, tail) = Self.splitAtLastWord(trimmed) {
                let trailing = Self.trailingWhitespace(of: pendingText)
                events.append(.final(emitFinal(text: head, end: committedSeconds)))
                pendingText = tail.isEmpty ? "" : tail + trailing
            } else {
                // No word boundary to hold anything back at, and unlike a
                // boundary cut there is nothing to carry it to: the backstop
                // fires because this utterance has already run long.
                events.append(.final(emitFinal(text: trimmed, end: committedSeconds)))
            }
        }

        guard !isFinal else { return events }
        // The partial is everything not yet finalized: whatever is still
        // pending plus the volatile suffix. Sending only `tentative` would make
        // text that has already been committed disappear from the status line
        // until the segment closes - and on the rows measured here `tentative`
        // is always empty, so that would mean no partials at all.
        let partial = (pendingText + tentative)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty, partial != lastPartialText else { return events }
        lastPartialText = partial
        events.append(.partial(Segment(
            id: nextID,
            start: pendingStart,
            // The same guard the final gets. An end before its start is
            // nonsense on the wire whichever event carries it.
            end: max(pendingStart, receivedSeconds),
            text: partial,
            language: language.map(Language.primarySubtag))))
        return events
    }

    /// Cut at the boundaries the audio has already reached.
    ///
    /// **At most one cut per call, at the last boundary the commit watermark
    /// has passed.** Where the text is cut is a different question from where
    /// the audio said, and only `settledWords` can answer it: without a word
    /// clock this holds a string and a span, with nothing to say which half of
    /// it belongs to which side of a time. So when an engine hands over one
    /// commit covering three utterances - which is what a burst after a stall
    /// looks like - honoring the first boundary and then the rest would emit
    /// one segment holding all three utterances' text stamped with the
    /// *earliest* of the three end times, then two empty ones. Taking the last
    /// keeps the text in one piece and gives it a span that covers it.
    ///
    /// With a word clock the three cuts could be made properly, and are not:
    /// each one would have to re-derive its count against a text the previous
    /// cut has shortened, and a burst of three utterances in one commit is a
    /// stalled engine rather than a working one. The cost is that a stall
    /// merges the utterances it swallowed, which is visible in the transcript
    /// and does not lose a word.
    ///
    /// A `.start` matters only when nothing is pending. Text already decoded
    /// belongs to the utterance that was open when it arrived, so a start
    /// cannot move that segment's beginning; with nothing pending, it is what
    /// keeps the next segment from beginning in the silence before it.
    ///
    /// That rule is conservative in one direction on purpose. When a commit
    /// arrives carrying both new text and the boundaries around it - an engine
    /// running behind, or a burst after a stall - the text is folded in before
    /// the drain, so the start is not applied and the segment keeps the
    /// previous cut as its beginning. The cost is a segment that includes the
    /// pause in front of it, which is silence in a refine span and a start time
    /// a little early. The alternative costs a segment whose start is later
    /// than words it already contains, and audio that no span covers.
    private mutating func closeAtBoundaries(
        committedThrough committedSeconds: Double,
        settledText: ((Double, String) -> Int?)?
    ) -> [LiveEvent] {
        let inherited = deferredCut
        var cut: Double? = inherited
        var opened: Double? = deferredStart
        deferredCut = nil
        deferredStart = nil
        while let boundary = boundaries.first, boundary.seconds <= committedSeconds {
            boundaries.removeFirst()
            switch boundary.kind {
            case .end:
                cut = boundary.seconds
            case .start:
                opened = boundary.seconds
            }
        }
        // Whether the cut about to be made is one that already waited a commit
        // for a word to finish. A newer boundary drained above replaces it, and
        // then this is a first attempt again.
        let carried = cut != nil && cut == inherited

        var events: [LiveEvent] = []
        if let cut {
            let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // The detector heard speech and the engine transcribed nothing
                // from it: room noise, a cough, a word too quiet to decode. The
                // clock still moves, so the next segment does not claim the
                // silence that just went by.
                pendingStart = max(pendingStart, cut)
                pendingText = ""
                lastPartialText = ""
            } else if let settled = settledText?(cut, trimmed) {
                let (head, tail) = Self.split(trimmed, afterCharacters: settled)
                if head.isEmpty {
                    // The word clock is definite: none of this text was spoken
                    // before the boundary, so there is nothing to publish and
                    // the text belongs to what comes next.
                    pendingStart = max(pendingStart, cut)
                } else {
                    let trailing = Self.trailingWhitespace(of: pendingText)
                    events.append(.final(emitFinal(text: head, end: cut)))
                    pendingText = tail.isEmpty ? "" : tail + trailing
                }
            } else if let (head, tail) = Self.splitAtLastWord(trimmed) {
                let trailing = Self.trailingWhitespace(of: pendingText)
                events.append(.final(emitFinal(text: head, end: cut)))
                pendingText = tail.isEmpty ? "" : tail + trailing
            } else if carried {
                // Whitespace never arrived. One commit was enough for a word
                // that was still growing; a second means this text has no word
                // boundary in it at all, which is what Chinese and Japanese
                // look like on a row with no word clock - so cut it rather than
                // holding the utterance open until the backstop.
                events.append(.final(emitFinal(text: trimmed, end: cut)))
            } else {
                // Nothing here can be cut without breaking a word. Carry the
                // boundary to the next commit rather than dropping it: the word
                // finishes a chunk later and the cut still lands at the time
                // the audio reported. The start is carried with it, or the
                // segment it eventually opens would begin in the silence.
                deferredCut = cut
                deferredStart = opened
                return events
            }
        }

        // `max`, and it is what makes the order of a drained start and end
        // harmless: a start belonging to the span the cut just closed is always
        // earlier than the cut, so it cannot pull the clock backwards. A
        // boundary that arrives out of order - which this detector does not
        // produce and the wire must survive anyway - is clamped by the same
        // rule rather than producing a segment that starts before the one
        // before it ended.
        if let opened, pendingText.isEmpty {
            pendingStart = max(pendingStart, opened)
        }
        return events
    }

    /// The whitespace `text` ends with, which trimming a cut's halves drops.
    ///
    /// A commit is a growing string, and the piece appended next carries a
    /// leading space only if the tokenizer put one there. So a cut that trimmed
    /// `one two ` down to `two` would have the next piece arrive as `three` and
    /// publish `twothree`: one word where there were two, in the middle of a
    /// transcript, with nothing to say it happened.
    static func trailingWhitespace(of text: String) -> String {
        String(text.reversed().prefix { $0.isWhitespace }.reversed())
    }

    /// Splits pending text after `count` Characters, for a caller that knows
    /// exactly how much of it was spoken before the boundary.
    ///
    /// **This is what makes a boundary cut land where the audio said.** Without
    /// a word clock the cut can only take the text as it stands, and the text
    /// at that moment is a decode step too long: the cut fires on the first
    /// commit whose watermark passes the boundary, and on a real pause that is
    /// the commit carrying the *next* utterance's first words. Measured on one
    /// 53.7 s recording, segments ran 1.1 to 2.4 seconds past the pause they
    /// were cut at, which is the next sentence's opening words sitting at the
    /// end of the previous segment.
    ///
    /// A count of Characters rather than of words, because the caller finds the
    /// position by matching its own word texts against this text - which works
    /// in a script that separates words with spaces and in one that does not.
    /// A count of words could only be a count of whitespace runs, and Chinese
    /// has none: every count would take the whole text, boundary or no
    /// boundary.
    ///
    /// Both halves are trimmed, so a cut never leaves leading whitespace at the
    /// front of the next segment; the caller's own words carry no spaces, so
    /// nothing is lost by it.
    static func split(_ text: String, afterCharacters count: Int) -> (head: String, tail: String) {
        guard count > 0 else { return ("", text) }
        guard count < text.count else { return (text, "") }
        let index = text.index(text.startIndex, offsetBy: count)
        return (
            String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Nil when there is no whitespace to cut at: one word, which may be
    /// finished or may be half of a longer one, and nothing in the text says
    /// which. The caller gives it a commit to grow in and then cuts it whole -
    /// which is also what makes this terminate for Chinese and Japanese, where
    /// the rows that stream here emit no spaces at all and a "word" is a
    /// tokenizer artifact.
    static func splitAtLastWord(_ text: String) -> (head: String, tail: String)? {
        guard let index = text.lastIndex(where: { $0.isWhitespace }) else { return nil }
        let head = String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }
        return (head, String(text[text.index(after: index)...]))
    }

    /// Close every complete sentence sitting in the pending text.
    ///
    /// A loop rather than a test on the tail, and that is the whole point.
    /// Commits do not land on sentence boundaries - measured on
    /// `parakeet-unified-en-0.6b`, they arrive about once a second in 8 to 20
    /// character increments, so a full stop is almost always in the *middle* of
    /// what just arrived. Asking "does the pending text end in a period" was
    /// the first version of this and it never once fired: a ten-second
    /// two-sentence dictation came back as a single segment closed only by the
    /// end of the stream.
    private mutating func closeSentences(
        committedThrough committedSeconds: Double, atEnd: Bool
    ) -> [LiveEvent] {
        var events: [LiveEvent] = []
        while let index = Self.endOfFirstSentence(in: pendingText, atEnd: atEnd) {
            let head = String(pendingText[..<index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(pendingText[index...])
            // A head with no letters or digits is punctuation, not a sentence.
            // Without this, `Really?!` emits `Really?` and then a segment
            // containing only `!` - a real event on the wire, and one that
            // `--refine` would spend a whole model inference re-transcribing.
            guard head.contains(where: { $0.isLetter || $0.isNumber }) else {
                pendingText = rest
                continue
            }
            // Where that sentence ended in time, by character fraction of the
            // span the pending text covers. An estimate, and named as one: the
            // library reports when audio was *committed*, not where a sentence
            // sat inside it. Stage 4.3's voice activity detection is what
            // replaces the estimate with a boundary taken from the audio.
            //
            // Character distance, not a UTF-16 offset: `count` below is in
            // Characters, and mixing the two units skews the fraction for any
            // language with multi-unit graphemes.
            let total = max(1, pendingText.count)
            let consumed = pendingText.distance(from: pendingText.startIndex, to: index)
            let fraction = Double(min(consumed, total)) / Double(total)
            let span = max(0, committedSeconds - pendingStart)
            events.append(.final(emitFinal(text: head, end: pendingStart + fraction * span)))
            pendingText = rest
        }
        return events
    }

    /// Publishes `text` and resets everything that describes what was pending.
    ///
    /// The carried cut is part of that. A boundary held back for want of a word
    /// boundary describes text that is being published here - by the backstop,
    /// by the flush, or by a later boundary - and inheriting it into the next
    /// commit would cut that commit's unrelated text at a time the clock has
    /// already passed, which reaches the wire as a segment of zero length
    /// stamped before the audio it came from.
    private mutating func emitFinal(text: String, end: Double) -> Segment {
        let segment = Segment(
            id: nextID,
            start: pendingStart,
            // A commit can land on the same millisecond the segment started;
            // an end before its start would be nonsense on the wire.
            end: max(pendingStart, end),
            text: text,
            language: language.map(Language.primarySubtag))
        finals.append(segment)
        nextID += 1
        pendingText = ""
        pendingStart = max(pendingStart, end)
        lastPartialText = ""
        deferredCut = nil
        deferredStart = nil
        return segment
    }

    /// The index just past the first sentence in `text`, or nil if there is
    /// none complete.
    ///
    /// Two narrowing rules, both there to avoid cutting a sentence in half -
    /// which is worse than leaving two joined, because it hands refinement a
    /// fragment with no context. A `.` counts only when whitespace follows it,
    /// so `3.5` and `v0.2.3` do not split. Closing quotes and brackets are
    /// absorbed, so `he said "stop."` ends after the quote.
    ///
    /// The whitespace rule is for `.` alone. Chinese and Japanese put no space
    /// after their terminators, so requiring one would mean CJK text never
    /// splits at all.
    ///
    /// - Parameter atEnd: whether `text` is the whole remaining utterance
    ///   rather than the part committed so far. It gates the "a terminator at
    ///   the end of the text closes the sentence" rule, and mid-stream that
    ///   rule is wrong: end-of-committed-text is an arbitrary position, so
    ///   `It runs at 3.` followed by `5 times real time.` in the next commit
    ///   would split a decimal in two. The cost is that the last sentence of a
    ///   run waits one more feed, which is the right trade.
    ///
    /// It does still split `Mr. Smith`. That is a known false positive whose
    /// cost is one short segment.
    public static func endOfFirstSentence(in text: String, atEnd: Bool) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            defer { index = text.index(after: index) }
            let character = text[index]
            guard terminators.contains(character) else { continue }
            var end = text.index(after: index)
            // A run of terminators is one ending, not several. `Really?!` and
            // `Wow!!!` split after the first mark otherwise, and the remainder
            // becomes a segment holding nothing but punctuation - which goes
            // out on the wire as a `segment.final` and costs `--refine` a whole
            // model inference to re-transcribe `!`. Absorbing the run keeps the
            // marks with the words they belong to rather than discarding them.
            while end < text.endIndex, terminators.contains(text[end]) {
                end = text.index(after: end)
            }
            while end < text.endIndex, closers.contains(text[end]) {
                end = text.index(after: end)
            }
            if character == "." {
                let followedBySpace = end < text.endIndex && text[end].isWhitespace
                guard followedBySpace || (atEnd && end == text.endIndex) else { continue }
            }
            return end
        }
        return nil
    }

    /// U+3002 is the ideographic full stop; U+FF01 and U+FF1F are the fullwidth
    /// exclamation and question marks. All three are what the streaming rows
    /// that list `zh-CN` and `ja-JP` actually emit, and without them a Japanese
    /// question runs into the next sentence until the 15-second backstop.
    private static let terminators: Set<Character> = [
        ".", "!", "?", "\u{3002}", "\u{FF01}", "\u{FF1F}",
    ]

    /// Closing marks that belong to the sentence they end. The CJK forms are
    /// here for the same reason the terminators are.
    private static let closers: Set<Character> = [
        "\"", "'", ")", "]", "}",
        "\u{201D}", "\u{2019}", "\u{FF09}", "\u{300D}", "\u{300F}",
    ]
}
