// Language.swift - BCP-47 handling, kept to the two operations the tool actually
// needs so that nothing else grows a private copy of them.
//
// Everywhere in this tool a "language" may arrive as a full tag ("pt-BR"), a
// bare subtag ("pt"), or an underscore form from a corpus directory name
// ("pt_br"). Catalog rows list primary subtags. Comparison is therefore always
// on the primary subtag, and the full tag is only preserved for the engines
// that genuinely resolve regional models (Apple's locales, Nemotron's prompts).

import Foundation

public enum Language {
    /// "pt-BR", "pt_br", "PT" -> "pt". Anything unparseable comes back
    /// lowercased and untouched, which keeps the comparison total.
    public static func primarySubtag(_ tag: String) -> String {
        let normalized = tag.replacingOccurrences(of: "_", with: "-")
        let head = normalized.split(separator: "-", maxSplits: 1).first.map(String.init) ?? normalized
        return head.lowercased()
    }

    /// A canonical BCP-47-ish tag for display and for handing to engines:
    /// primary subtag lowercased, region uppercased. "pl_pl" -> "pl-PL".
    /// The list's own spelling of a requested language, or nil if it has none.
    ///
    /// Prefers an exact tag, then a bare primary subtag, then the variant for
    /// the language's main region, then the first regional variant of the same
    /// language - so `pt-BR` finds itself where a model lists both Brazilian
    /// and European Portuguese, a bare `es` lands on `es-ES` even when the
    /// model names `es-US` first, and a language with no main-region variant
    /// is still matched rather than refused.
    ///
    /// It hands back the LIST's string rather than the caller's, and that is
    /// the whole point of it. Measured on the ggml weights: the Nemotron rows
    /// accept `pl-PL` and reject `pl`, while Canary, Qwen3-ASR and Whisper
    /// accept `pl` and reject `pl-PL`. Normalizing to a primary subtag breaks
    /// one half of the catalog and passing the caller's tag through unchanged
    /// breaks the other; returning what the model itself said is the only rule
    /// that works for both. Shared rather than copied for exactly that reason -
    /// a second copy of this would be a second chance to get it wrong.
    public static func match(_ requested: String, in supported: [String]) -> String? {
        let canonical = canonical(requested)
        if let exact = supported.first(where: {
            $0.caseInsensitiveCompare(canonical) == .orderedSame
        }) {
            return exact
        }
        let primary = primarySubtag(requested)
        guard !primary.isEmpty else { return nil }
        if let bare = supported.first(where: {
            $0.caseInsensitiveCompare(primary) == .orderedSame
        }) {
            return bare
        }
        let variants = supported.filter { primarySubtag($0) == primary }
        if let main = mainRegion(requested),
           let preferred = variants.first(where: { region($0) == main }) {
            return preferred
        }
        return variants.first
    }

    /// The region a tag names, if any: "pt-BR" -> "BR", "zh-Hant-TW" -> "TW",
    /// "es-419" -> "419", "pt" -> nil. Underscore forms count ("it_IT").
    public static func region(_ tag: String) -> String? {
        let parts = canonical(tag).split(separator: "-").dropFirst()
        return parts.first { part in
            (part.count == 2 && part.allSatisfy(\.isLetter))
                || (part.count == 3 && part.allSatisfy(\.isNumber))
        }.map(String.init)
    }

    /// The region a language is mainly spoken in, for a tag that names no
    /// region: "it" -> "IT", "nl" -> "NL", "pt" -> "BR", "zh-Hant" -> "TW".
    /// nil when the tag already names a region, or when there is no answer.
    ///
    /// From CLDR's likely subtags, which Foundation ships as
    /// `Locale.Language.maximalIdentifier`. A bare language must never land on
    /// a minority variant because a list happened to name it first: Apple's
    /// `supportedLocale(equivalentTo:)` turned "it" into it_CH and "nl" into
    /// nl_BE on macOS 26.6.2, and the ggml Nemotron list names es-US before
    /// es-ES.
    public static func mainRegion(_ tag: String) -> String? {
        guard region(tag) == nil else { return nil }
        let maximal = Locale.Language(identifier: canonical(tag)).maximalIdentifier
        return region(maximal)
    }

    public static func canonical(_ tag: String) -> String {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard let first = parts.first else { return tag }
        var out = first.lowercased()
        for part in parts.dropFirst() {
            if part.count == 2, part.allSatisfy({ $0.isLetter }) {
                out += "-" + part.uppercased()
            } else if part.count == 4, part.allSatisfy({ $0.isLetter }) {
                out += "-" + part.prefix(1).uppercased() + part.dropFirst().lowercased()
            } else {
                out += "-" + part.lowercased()
            }
        }
        return out
    }
}
