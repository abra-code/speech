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
// takes what a feed reported and returns what to emit. Stage 4.3's voice
// activity detection replaces the boundary rule inside it, and this is the
// shape that makes swapping it out a local change.

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

    public init(maxUtteranceSeconds: Double = 15, language: String? = nil) {
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.language = language
    }

    /// Fold one feed's result in, and say what to emit.
    ///
    /// - Parameter isFinal: this is the flush at end of stream. It closes
    ///   whatever is pending and suppresses the partial, and it is also what
    ///   makes "a terminator at the end of the text" count as a sentence - see
    ///   `endOfFirstSentence`.
    public mutating func absorb(
        committed: String,
        tentative: String,
        committedMs: Int64,
        receivedMs: Int64,
        isFinal: Bool
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

        var events = closeSentences(committedThrough: committedSeconds, atEnd: isFinal)

        let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let longEnough = committedSeconds - pendingStart >= maxUtteranceSeconds
        if !trimmed.isEmpty, isFinal || longEnough {
            events.append(.final(emitFinal(text: trimmed, end: committedSeconds)))
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
