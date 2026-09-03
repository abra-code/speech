// ScorerTests.swift - the scorer is the instrument every catalog decision is
// made with, so these are hand-computed cases, not golden files. A golden file
// records what the code did; a hand-computed case records what the answer is.

import Testing
@testable import SpeechCore

@Suite("Scorer")
struct ScorerTests {
    @Test("normalization strips punctuation and case but keeps in-word apostrophes")
    func normalization() {
        #expect(Scorer.normalize("Hello, World!") == "hello world")
        #expect(Scorer.normalize("don't") == "don't")
        // The typographic apostrophe an Apple engine emits must compare equal
        // to the ASCII one a corpus reference uses.
        #expect(Scorer.normalize("don\u{2019}t") == "don't")
        // A quote that is not between two letters is punctuation, not part of
        // a word, and becomes a separator.
        #expect(Scorer.normalize("'quoted'") == "quoted")
        #expect(Scorer.normalize("a  b\tc\nd") == "a b c d")
        #expect(Scorer.normalize("50% of $5 + 3") == "50 of 5 3")
        #expect(Scorer.normalize("") == "")
    }

    @Test("normalization is NFC so decomposed diacritics compare equal")
    func polishDiacritics() {
        // "Zażółć gęślą jaźń" written with combining marks where Unicode
        // offers them, against the precomposed form.
        let decomposed = "Zaz\u{0307}o\u{0301}łc\u{0301} ge\u{0328}s\u{0301}la\u{0328} jaz\u{0301}n\u{0301}"
        let precomposed = "Zażółć gęślą jaźń"
        #expect(Scorer.normalize(decomposed, language: "pl") == Scorer.normalize(precomposed, language: "pl"))
        #expect(Scorer.normalize(precomposed, language: "pl") == "zażółć gęślą jaźń")
    }

    @Test("invisible format characters are deleted, not turned into separators")
    func formatCharacters() {
        // A soft hyphen is invisible. Spacing it would split one word into two
        // and charge the engine two edits for a character nobody can see.
        #expect(Scorer.normalize("co\u{00AD}operate") == "cooperate")
        // A zero-width joiner and a word joiner are invisible glue.
        #expect(Scorer.normalize("wo\u{200D}rd") == "word")
        #expect(Scorer.normalize("wo\u{2060}rd") == "word")
        let score = Scorer.score(reference: "co\u{00AD}operate now", hypothesis: "cooperate now")
        #expect(score.wer == 0)
    }

    @Test("zero-width space stays a word boundary, because Thai marks words with it")
    func zeroWidthSpaceSeparates() {
        // U+200B is the one format character whose defined job is a word
        // boundary: Thai, Khmer, Lao and Burmese have no visible word spacing
        // and use it instead, and Thai is one of the languages Apple's
        // dictation engine covers. Deleting it as invisible would glue two
        // words together and score a correct transcript as two errors.
        #expect(Scorer.normalize("zero\u{200B}width") == "zero width")
        let score = Scorer.score(
            reference: "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}\u{200B}\u{0E04}\u{0E23}\u{0E31}\u{0E1A}",
            hypothesis: "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35} \u{0E04}\u{0E23}\u{0E31}\u{0E1A}",
            language: "th")
        #expect(score.wer == 0)
    }

    @Test("identical strings score zero")
    func perfect() {
        let score = Scorer.score(
            reference: "the quick brown fox", hypothesis: "The quick brown fox.")
        #expect(score.wer == 0)
        #expect(score.cer == 0)
        #expect(score.word.referenceCount == 4)
    }

    @Test("one substitution in four words is 25 percent")
    func oneSubstitution() {
        let score = Scorer.score(
            reference: "the quick brown fox", hypothesis: "the quick brown box")
        #expect(score.word.substitutions == 1)
        #expect(score.word.deletions == 0)
        #expect(score.word.insertions == 0)
        #expect(score.wer == 0.25)
    }

    @Test("a dropped trailing word is a deletion, which is how streaming loss shows up")
    func deletion() {
        let score = Scorer.score(
            reference: "one two three four", hypothesis: "one two three")
        #expect(score.word.deletions == 1)
        #expect(score.word.substitutions == 0)
        #expect(score.word.insertions == 0)
        #expect(score.wer == 0.25)
    }

    @Test("an extra word is an insertion")
    func insertion() {
        let score = Scorer.score(
            reference: "one two three", hypothesis: "one two and three")
        #expect(score.word.insertions == 1)
        #expect(score.wer == 1.0 / 3.0)
    }

    @Test("an empty hypothesis loses every reference word")
    func emptyHypothesis() {
        let score = Scorer.score(reference: "one two three", hypothesis: "")
        #expect(score.word.deletions == 3)
        #expect(score.wer == 1.0)
        #expect(score.cer == 1.0)
    }

    @Test("an empty reference has no denominator and cannot make the total infinite")
    func emptyReference() {
        let empty = Scorer.score(reference: "", hypothesis: "")
        #expect(empty.wer == 0)
        let spurious = Scorer.score(reference: "", hypothesis: "hello")
        #expect(spurious.word.referenceCount == 0)
        #expect(spurious.wer == 1.0)
    }

    @Test("numbers are not normalized, which is why the corpus tooling picks the spelled-out column")
    func numbersAreNotNormalized() {
        let score = Scorer.score(reference: "five dozen", hypothesis: "5 dozen")
        #expect(score.word.substitutions == 1)
        #expect(score.wer == 0.5)
    }

    @Test("CER keeps word boundaries")
    func characterErrorRate() {
        // "at one" vs "atone": one deletion of a space over six reference
        // characters.
        let score = Scorer.score(reference: "at one", hypothesis: "atone")
        #expect(score.character.referenceCount == 6)
        #expect(score.character.deletions == 1)
        #expect(score.character.edits == 1)
    }

    @Test("corpus WER is total edits over total reference words, not the mean of the rates")
    func aggregation() {
        // One error in a one-word utterance and none in a nine-word one.
        // Averaging the rates gives 50%; the right answer is 10%.
        let short = Scorer.score(reference: "yes", hypothesis: "no")
        let long = Scorer.score(
            reference: "one two three four five six seven eight nine",
            hypothesis: "one two three four five six seven eight nine")
        let combined = ScoreCounts.combine([short.word, long.word])
        #expect(combined.referenceCount == 10)
        #expect(combined.edits == 1)
        #expect(combined.rate == 0.1)
    }

    @Test("alignment prefers substitution on a tie so the breakdown is reproducible")
    func tieBreaking() {
        let counts = Scorer.align(reference: ["a", "b", "c"], hypothesis: ["a", "x", "c"])
        #expect(counts.substitutions == 1)
        #expect(counts.deletions == 0)
        #expect(counts.insertions == 0)
    }
}
