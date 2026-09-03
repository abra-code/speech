// Scorer.swift - the measuring instrument. Built before any engine, on purpose:
// every catalog row, blurb and curation rule in this product is downstream of a
// WER number, so a scorer with a quiet bug would invalidate the entire catalog.
//
// Normalization is the part that decides what counts as an error, and it is
// stated here rather than left to a library so the numbers can be defended:
//
//   1. Unicode NFC, so a decomposed Polish "s" + combining acute compares equal
//      to a precomposed one. Engines disagree about this constantly.
//   2. Lowercase in the reference language's locale (Turkish dotted I is the
//      case this exists for).
//   3. Every Unicode punctuation (P*) and symbol (S*) scalar becomes a space,
//      except an apostrophe between two alphanumerics, which is kept and
//      folded to U+0027 - "don't" and "don\u{2019}t" are the same word, and
//      counting that as an error would measure typography, not recognition.
//   4. Collapse whitespace, split on it.
//
// Numbers are deliberately NOT normalized: "21" and "twenty one" score as
// errors against each other. FLEURS supplies a spelled-out `transcription`
// column for exactly this reason and the corpus tooling selects it.
//
// WER is edits over reference tokens. Corpus WER is total edits over total
// reference tokens - see ScoreCounts.combine - never the mean of per-row rates,
// which would let a three-word utterance outvote a fifty-word one.

import Foundation

/// Substitution / deletion / insertion counts for one alignment. The breakdown
/// is kept rather than just the total because it diagnoses: a run that is
/// almost all deletions is dropping trailing words (the FluidAudio streaming
/// symptom the plan asks us to watch for), while insertions concentrated in one
/// row usually mean the engine hallucinated on silence.
public struct ScoreCounts: Sendable, Equatable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceCount: Int

    public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, referenceCount: Int = 0) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceCount = referenceCount
    }

    public var edits: Int { substitutions + deletions + insertions }

    /// Edits over reference units. An empty reference has no denominator: an
    /// empty hypothesis against it scores 0, and anything else scores 1, which
    /// keeps the aggregate finite instead of infinite. Rows like that should
    /// not be in a manifest, and the evaluator warns when it meets one.
    public var rate: Double {
        if referenceCount == 0 { return edits == 0 ? 0 : 1 }
        return Double(edits) / Double(referenceCount)
    }

    public static func + (lhs: ScoreCounts, rhs: ScoreCounts) -> ScoreCounts {
        ScoreCounts(
            substitutions: lhs.substitutions + rhs.substitutions,
            deletions: lhs.deletions + rhs.deletions,
            insertions: lhs.insertions + rhs.insertions,
            referenceCount: lhs.referenceCount + rhs.referenceCount)
    }

    public static func combine(_ counts: [ScoreCounts]) -> ScoreCounts {
        counts.reduce(ScoreCounts(), +)
    }
}

public struct Score: Sendable, Equatable {
    public var word: ScoreCounts
    public var character: ScoreCounts

    public init(word: ScoreCounts, character: ScoreCounts) {
        self.word = word
        self.character = character
    }

    public var wer: Double { word.rate }
    public var cer: Double { character.rate }
}

/// One dynamic-programming cell of the alignment: the operation breakdown of the
/// cheapest path reaching it. Int32 rather than Int because the table is the
/// hot allocation here - a 4000-character CER alignment is two rows of these -
/// and no utterance in any corpus has two billion edits.
private struct Cell {
    var substitutions: Int32 = 0
    var deletions: Int32 = 0
    var insertions: Int32 = 0
    var total: Int32 { substitutions + deletions + insertions }
}

public enum Scorer {
    /// Apostrophe forms an engine may emit: ASCII, the typographic right single
    /// quote (what iOS and macOS autocorrect produce), the modifier letter
    /// apostrophe used in some transliterations, and the left single quote,
    /// which turns up in text that was typed with the wrong key.
    private static let apostrophes: Set<Unicode.Scalar> = [
        "\u{0027}", "\u{2019}", "\u{02BC}", "\u{2018}",
    ]

    public static func normalize(_ text: String, language: String? = nil) -> String {
        let locale = language.map { Locale(identifier: Language.canonical($0)) }
        let lowered = text.precomposedStringWithCanonicalMapping
            .lowercased(with: locale)
            .precomposedStringWithCanonicalMapping

        let scalars = Array(lowered.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)

        for (index, scalar) in scalars.enumerated() {
            if apostrophes.contains(scalar) {
                let previous = index > 0 ? scalars[index - 1] : nil
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                if let previous, let next, isAlphanumeric(previous), isAlphanumeric(next) {
                    output.append("\u{0027}")
                } else {
                    output.append(" ")
                }
                continue
            }
            // Format characters (Cf) are invisible: a soft hyphen, a zero-width
            // joiner, a bidi mark. They are deleted, not turned into spaces -
            // spacing them would split "co<SHY>operate" into two tokens and
            // charge the engine two edits for a character nobody can see.
            //
            // U+200B is the exception and has to stay a separator: zero-width
            // space is how Thai, Khmer, Lao and Burmese mark a word boundary
            // (Unicode ch. 23.2), and `th` is one of the languages Apple's
            // dictation engine covers. Deleting it would glue two Thai words
            // together and score a correct transcript as two errors.
            if scalar.properties.generalCategory == .format, scalar != "\u{200B}" {
                continue
            }
            if isPunctuationOrSymbol(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                output.append(" ")
                continue
            }
            output.append(scalar)
        }

        return String(output)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    public static func tokens(_ text: String, language: String? = nil) -> [String] {
        let normalized = normalize(text, language: language)
        if normalized.isEmpty { return [] }
        return normalized.split(separator: " ").map(String.init)
    }

    public static func score(reference: String, hypothesis: String, language: String? = nil) -> Score {
        let referenceNormalized = normalize(reference, language: language)
        let hypothesisNormalized = normalize(hypothesis, language: language)

        let referenceTokens = referenceNormalized.isEmpty
            ? [] : referenceNormalized.split(separator: " ").map(String.init)
        let hypothesisTokens = hypothesisNormalized.isEmpty
            ? [] : hypothesisNormalized.split(separator: " ").map(String.init)

        // CER keeps the single spaces between tokens: word boundaries are part
        // of what a character-level score is measuring, and dropping them would
        // score "atone" and "at one" as identical.
        let referenceCharacters = Array(referenceNormalized)
        let hypothesisCharacters = Array(hypothesisNormalized)

        return Score(
            word: align(reference: referenceTokens, hypothesis: hypothesisTokens),
            character: align(reference: referenceCharacters, hypothesis: hypothesisCharacters))
    }

    /// Levenshtein alignment carrying the operation breakdown, two rows at a
    /// time. On a tie the order below prefers substitution, then deletion, then
    /// insertion, which is the conventional choice and keeps the breakdown
    /// deterministic across runs so two reports can be diffed.
    static func align<T: Equatable>(reference: [T], hypothesis: [T]) -> ScoreCounts {
        let n = reference.count
        let m = hypothesis.count
        if n == 0 {
            return ScoreCounts(insertions: m, referenceCount: 0)
        }
        if m == 0 {
            return ScoreCounts(deletions: n, referenceCount: n)
        }

        var previous = [Cell](repeating: Cell(), count: m + 1)
        var current = [Cell](repeating: Cell(), count: m + 1)
        for j in 1...m {
            previous[j] = Cell(substitutions: 0, deletions: 0, insertions: Int32(j))
        }

        for i in 1...n {
            current[0] = Cell(substitutions: 0, deletions: Int32(i), insertions: 0)
            for j in 1...m {
                if reference[i - 1] == hypothesis[j - 1] {
                    current[j] = previous[j - 1]
                    continue
                }
                var best = previous[j - 1]
                best.substitutions += 1
                var deletion = previous[j]
                deletion.deletions += 1
                if deletion.total < best.total { best = deletion }
                var insertion = current[j - 1]
                insertion.insertions += 1
                if insertion.total < best.total { best = insertion }
                current[j] = best
            }
            swap(&previous, &current)
        }

        let result = previous[m]
        return ScoreCounts(
            substitutions: Int(result.substitutions),
            deletions: Int(result.deletions),
            insertions: Int(result.insertions),
            referenceCount: n)
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark:
            return true
        default:
            return false
        }
    }

    private static func isPunctuationOrSymbol(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
