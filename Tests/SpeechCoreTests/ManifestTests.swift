// ManifestTests.swift - the corpus format and the catalog id grammar.
//
// Manifest order is load-bearing: `--limit 200` has to mean the same 200 rows
// for every engine or no two measurements can be compared, so the parser must
// not reorder or deduplicate anything.

import Foundation
import Testing
@testable import SpeechCore

@Suite("Manifest and catalog ids")
struct ManifestTests {
    private let base = URL(fileURLWithPath: "/corpus/pl_pl", isDirectory: true)

    @Test("two and three column rows both parse, in file order")
    func parsing() throws {
        let text = """
            # a comment
            a.wav\tpierwsze zdanie

            b.wav\tdrugie zdanie\tpl
            /elsewhere/c.wav\tthird sentence\ten-US
            """
        let rows = try Manifest.parse(text, baseDirectory: base)
        #expect(rows.count == 3)
        #expect(rows.map(\.index) == [1, 2, 3])
        #expect(rows[0].audioURL.path == "/corpus/pl_pl/a.wav")
        #expect(rows[0].reference == "pierwsze zdanie")
        #expect(rows[0].language == nil)
        #expect(rows[1].language == "pl")
        // An absolute path is taken as written, not appended to the base.
        #expect(rows[2].audioURL.path == "/elsewhere/c.wav")
        #expect(rows[2].language == "en-US")
    }

    @Test("only the first two tabs split, so a reference may contain anything else")
    func referenceWithPunctuation() throws {
        let rows = try Manifest.parse("a.wav\thello, world - yes!\tpl", baseDirectory: base)
        #expect(rows[0].reference == "hello, world - yes!")
        #expect(rows[0].language == "pl")
    }

    @Test("CRLF line endings split into rows")
    func crlf() throws {
        // "\r\n" is a single Swift Character, so split(separator: "\n") never
        // matches it: a manifest saved by a Windows editor used to parse as one
        // row with the rest of the file inside its language column.
        let rows = try Manifest.parse(
            "a.wav\tfirst ref\tpl\r\nb.wav\tsecond ref\tpl\r\n", baseDirectory: base)
        #expect(rows.count == 2)
        #expect(rows[0].language == "pl")
        #expect(rows[1].reference == "second ref")
        // A lone CR, as a classic Mac editor would write, too.
        #expect(try Manifest.parse("a.wav\tone\rb.wav\ttwo", baseDirectory: base).count == 2)
    }

    @Test("only real line endings split a row, not every Unicode line break")
    func exoticLineBreaksStayInTheReference() throws {
        // Character.isNewline also matches NEL (U+0085), LINE SEPARATOR and
        // PARAGRAPH SEPARATOR. U+0085 is what a CP1252 ellipsis turns into
        // after a bad Latin-1 conversion, and splitting on it would produce a
        // malformed second row that aborts the whole eval before any row runs.
        let rows = try Manifest.parse("a.wav\thalf\u{0085}other half", baseDirectory: base)
        #expect(rows.count == 1)
        #expect(rows[0].reference.contains("\u{0085}"))
        // The scorer turns it into a separator, so it costs nothing to keep.
        #expect(Scorer.normalize(rows[0].reference) == "half other half")
    }

    @Test("a row without a reference column is a usage error, not a silent skip")
    func malformedRow() {
        #expect(throws: SpeechError.self) {
            _ = try Manifest.parse("a.wav", baseDirectory: base)
        }
        #expect(throws: SpeechError.self) {
            _ = try Manifest.parse("# only comments\n", baseDirectory: base)
        }
    }

    @Test("catalog ids split into engine, model and variant")
    func catalogIDs() throws {
        let models = URL(fileURLWithPath: "/models", isDirectory: true)
        let plain = try EngineSpec.parse(catalogID: "apple.transcriber", modelsDirectory: models)
        #expect(plain.engine == "apple")
        #expect(plain.model == "transcriber")
        #expect(plain.variant == nil)
        #expect(plain.directory.path == "/models/apple/transcriber")

        let variant = try EngineSpec.parse(catalogID: "fluid.parakeet-v3@int8", modelsDirectory: models)
        #expect(variant.engine == "fluid")
        #expect(variant.model == "parakeet-v3")
        #expect(variant.variant == "int8")
        #expect(variant.directory.path == "/models/fluid/parakeet-v3@int8")

        // Only the first dot separates the engine, so a model name may hold
        // dots of its own.
        let dotted = try EngineSpec.parse(
            catalogID: "ggml.nemotron-3.5-asr@q8_0", modelsDirectory: models)
        #expect(dotted.engine == "ggml")
        #expect(dotted.model == "nemotron-3.5-asr")
        #expect(dotted.variant == "q8_0")
    }

    @Test("a malformed catalog id is rejected")
    func badCatalogIDs() {
        let models = URL(fileURLWithPath: "/models", isDirectory: true)
        for bad in ["apple", "", ".transcriber", "apple.", "apple.transcriber@"] {
            #expect(throws: SpeechError.self) {
                _ = try EngineSpec.parse(catalogID: bad, modelsDirectory: models)
            }
        }
    }

    @Test("language support compares primary subtags")
    func languageMatching() {
        let capabilities = EngineCapabilities(languages: ["en", "pl", "pt"])
        #expect(capabilities.supports(language: "pl-PL"))
        #expect(capabilities.supports(language: "pl_pl"))
        #expect(capabilities.supports(language: "PT-BR"))
        #expect(!capabilities.supports(language: "de"))
        // No language named means no constraint.
        #expect(capabilities.supports(language: nil))
        // An empty list is the "any language" engine, like Whisper.
        #expect(EngineCapabilities(languages: []).supports(language: "sw"))
    }

    @Test("canonical tags uppercase the region and lowercase the language")
    func canonicalTags() {
        #expect(Language.canonical("pl_pl") == "pl-PL")
        #expect(Language.canonical("EN-us") == "en-US")
        #expect(Language.canonical("zh-hant-tw") == "zh-Hant-TW")
        #expect(Language.primarySubtag("pt_BR") == "pt")
    }
}
