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
