// Manifest.swift - the corpus format, deliberately the dumbest thing that works.
//
//   audio_path <TAB> reference_text [<TAB> language]
//
// UTF-8, no header, `#` comments, blank lines skipped. Relative audio paths
// resolve against the manifest's own directory, so a corpus folder can be moved
// or shared without rewriting it.
//
// Row order is the file's order and never shuffled: `--limit 200` must select
// the same 200 utterances for every engine, or the comparison between engines
// stops meaning anything.

import Foundation

public struct ManifestRow: Sendable, Equatable {
    /// 1-based, as reported in `eval.row` events and in the worst-rows table.
    public var index: Int
    public var audioURL: URL
    public var reference: String
    /// Per-row language, for mixed-language manifests. Falls back to the
    /// evaluator's --language when absent.
    public var language: String?

    public init(index: Int, audioURL: URL, reference: String, language: String? = nil) {
        self.index = index
        self.audioURL = audioURL
        self.reference = reference
        self.language = language
    }
}

public enum Manifest {
    public static func load(_ url: URL) throws -> [ManifestRow] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SpeechError.usage("cannot read manifest \(url.path): \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SpeechError.usage("manifest \(url.path) is not valid UTF-8")
        }
        return try parse(text, baseDirectory: url.deletingLastPathComponent())
    }

    public static func parse(_ text: String, baseDirectory: URL) throws -> [ManifestRow] {
        var rows: [ManifestRow] = []
        var lineNumber = 0
        // CR, LF and CRLF, and nothing else. A CRLF pair is a single Swift
        // Character, so `split(separator: "\n")` never matches it and a manifest
        // saved by a Windows editor parses as one enormous row, with the rest
        // of the file inside the first row's language column.
        //
        // Deliberately narrower than `Character.isNewline`, which also matches
        // NEL (U+0085), LINE SEPARATOR and PARAGRAPH SEPARATOR. A reference
        // containing one of those - U+0085 is what a CP1252 ellipsis becomes
        // after a bad Latin-1 conversion - would split into a malformed row and
        // abort the whole run, where before it was just a character the scorer
        // turned into a space.
        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        {
            lineNumber += 1
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("#") { continue }

            // Split on the first two tabs only: a reference text may legally
            // contain nothing but the language column must stay the third
            // field, and references never contain tabs.
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else {
                throw SpeechError.usage(
                    "manifest line \(lineNumber): expected 'audio<TAB>reference[<TAB>language]'")
            }
            let path = String(fields[0]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else {
                throw SpeechError.usage("manifest line \(lineNumber): empty audio path")
            }
            let reference = String(fields[1])
            let language = fields.count > 2
                ? String(fields[2]).trimmingCharacters(in: .whitespaces)
                : nil

            let audioURL = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: path, relativeTo: baseDirectory).standardizedFileURL

            rows.append(ManifestRow(
                index: rows.count + 1,
                audioURL: audioURL,
                reference: reference,
                language: (language?.isEmpty ?? true) ? nil : language))
        }
        guard !rows.isEmpty else {
            throw SpeechError.usage("manifest has no rows")
        }
        return rows
    }
}
