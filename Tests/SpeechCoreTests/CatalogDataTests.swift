// CatalogDataTests.swift - the catalog as data: the JSON documents, the strict
// decoder, and the merge of a user's files over the built-in ones.
//
// Every test here loads into a value rather than installing it with
// `Catalog.install`: Swift Testing runs tests in parallel, and a test that
// swapped the process-wide catalog would change what every other test reads.

import Foundation
import Testing

@testable import SpeechCore

@Suite("Catalog documents")
struct CatalogDataTests {
    /// A fresh directory holding the given files, removed by the caller.
    static func directory(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: url.appendingPathComponent(name))
        }
        return url
    }

    static func document(_ models: String) -> String {
        #"{"schema": 1, "models": [\#(models)]}"#
    }

    static let whisper = #"""
        {"engine": "ggml", "model": "whisper", "family": "whisper",
         "source": "a/whisper-gguf", "precision": "q8_0", "label": "Whisper",
         "variants": [{"variant": "q8_0", "file": "w.gguf"}]}
        """#

    @Test("the built-in catalog loads with no problems")
    func builtinLoadsClean() throws {
        let catalog = try LoadedCatalog.load(builtin: try Catalog.builtinDirectory())
        #expect(catalog.problems.isEmpty, "\(catalog.problems)")
        #expect(Set(catalog.models.map(\.engine)) == ["apple", "fluid", "ggml", "mlx"])
        // One entry per engine and model: a user file replaces by this key, so
        // two built-in entries sharing one would make "replace" ambiguous.
        #expect(Set(catalog.models.map(\.key)).count == catalog.models.count)
    }

    @Test("a variant inherits every field it does not set")
    func inheritance() throws {
        let data = Data(Self.document(#"""
            {"engine": "mlx", "model": "m", "family": "f", "source": "org/m",
             "precision": "int8", "params_m": 100, "label": "M",
             "variants": [
               {"variant": "a"},
               {"variant": "b", "source": "org/m-b", "precision": "int4", "label": "M b",
                "size_bytes": 7, "hidden": true}
             ]}
            """#).utf8)
        let document = try JSONDecoder().decode(CatalogDocument.self, from: data)
        let model = try #require(try document.models.first?.get())
        let rows = model.declaredVariants.map { model.row($0) }
        #expect(rows.map(\.id) == ["mlx.m@a", "mlx.m@b"])
        #expect(rows[0].source == "org/m" && rows[0].precision == "int8" && rows[0].label == "M")
        #expect(rows[0].parametersM == 100 && rows[0].sizeBytes == nil)
        #expect(rows[1].source == "org/m-b" && rows[1].precision == "int4" && rows[1].label == "M b")
        #expect(rows[1].parametersM == 100 && rows[1].sizeBytes == 7)
        #expect(!model.isHidden(model.declaredVariants[0]))
        #expect(model.isHidden(model.declaredVariants[1]))
    }

    @Test("a model with no variants is one row with no @")
    func implicitVariant() throws {
        let model = CatalogModel(
            engine: "apple", model: "transcriber", family: .apple, precision: "system", label: "A")
        #expect(model.declaredVariants.count == 1)
        #expect(model.row(model.declaredVariants[0]).id == "apple.transcriber")
        #expect(model.problem() == nil)
    }

    /// A misspelled key in a hand-edited file is the likeliest mistake, and
    /// ignoring it would be a model that claims every language.
    @Test("an unknown field costs its entry and names the field; the rest loads")
    func unknownField() throws {
        let builtin = try Self.directory(["a.json": Self.document(Self.whisper + "," + #"""
            {"engine": "ggml", "model": "typo", "family": "whisper", "precision": "q8_0",
             "label": "T", "langauges": ["pl"]}
            """#)])
        defer { try? FileManager.default.removeItem(at: builtin) }
        let catalog = try LoadedCatalog.load(builtin: builtin)
        #expect(catalog.models.map(\.key) == ["ggml.whisper"])
        #expect(catalog.problems.count == 1)
        #expect(catalog.problems.first?.contains("a.json") == true)
        #expect(catalog.problems.first?.contains("'langauges'") == true)
    }

    @Test("names that are not path-safe lowercase are refused")
    func names() {
        for bad in ["", "Whisper", "../x", ".hidden", "a b", "a/b", "caf\u{E9}"] {
            #expect(!CatalogModel.isName(bad), "\(bad)")
        }
        for good in ["whisper", "qwen3-asr-1.7b", "parakeet-tdt_ctc-110m", "2240"] {
            #expect(CatalogModel.isName(good), "\(good)")
        }
        var model = CatalogModel(
            engine: "ggml", model: "m", family: .whisper, precision: "q8_0", label: "M",
            variants: [CatalogVariant(variant: "q8_0"), CatalogVariant(variant: "q8_0")])
        #expect(model.problem()?.contains("twice") == true)
        model.variants = []
        #expect(model.problem()?.contains("empty") == true)
        model.variants = [CatalogVariant(variant: nil)]
        #expect(model.problem()?.contains("no 'variant' name") == true)
        model.variants = nil
        model.label = "tab\there"
        #expect(model.problem()?.contains("control character") == true)
    }

    @Test("a user entry replaces a built-in one in place, and a new one is appended")
    func userOverride() throws {
        let builtin = try Self.directory([
            "a.json": Self.document(Self.whisper + "," + #"""
                {"engine": "apple", "model": "dictation", "family": "apple",
                 "precision": "system", "label": "Dictation"}
                """#),
        ])
        let user = try Self.directory([
            "mine.json": Self.document(#"""
                {"engine": "ggml", "model": "whisper", "family": "whisper", "hidden": true,
                 "source": "b/whisper-gguf", "precision": "q4_k_m", "label": "Mine",
                 "variants": [{"variant": "q4_k_m", "file": "w4.gguf"}]},
                {"engine": "ggml", "model": "granite", "family": "granite",
                 "source": "c/granite-gguf", "precision": "q8_0", "label": "Granite",
                 "variants": [{"variant": "q8_0", "file": "g.gguf"}]}
                """#),
            "notes.txt": "not a catalog",
        ])
        defer {
            try? FileManager.default.removeItem(at: builtin)
            try? FileManager.default.removeItem(at: user)
        }
        let catalog = try LoadedCatalog.load(builtin: builtin, user: user)
        #expect(catalog.problems.isEmpty, "\(catalog.problems)")
        #expect(catalog.models.map(\.key) == ["ggml.whisper", "apple.dictation", "ggml.granite"])
        #expect(catalog.models[0].source == "b/whisper-gguf")
        #expect(catalog.models[0].hidden)
        #expect(catalog.userDirectory == user)
    }

    @Test("a missing user directory is no user entries, not a problem")
    func noUserDirectory() throws {
        let builtin = try Self.directory(["a.json": Self.document(Self.whisper)])
        defer { try? FileManager.default.removeItem(at: builtin) }
        let catalog = try LoadedCatalog.load(
            builtin: builtin, user: builtin.appendingPathComponent("absent"))
        #expect(catalog.problems.isEmpty)
        #expect(catalog.models.count == 1)
    }

    @Test("two user files defining one model: the later name wins, and it is reported")
    func userDuplicate() throws {
        let builtin = try Self.directory(["a.json": Self.document(Self.whisper)])
        let entry = { (label: String) in Self.document(#"""
            {"engine": "ggml", "model": "x", "family": "x", "source": "o/x", "precision": "q8_0",
             "label": "\#(label)", "variants": [{"variant": "q8_0", "file": "x.gguf"}]}
            """#) }
        let user = try Self.directory(["1.json": entry("first"), "2.json": entry("second")])
        defer {
            try? FileManager.default.removeItem(at: builtin)
            try? FileManager.default.removeItem(at: user)
        }
        let catalog = try LoadedCatalog.load(builtin: builtin, user: user)
        #expect(catalog.models.last?.label == "second")
        #expect(catalog.problems.count == 1)
        #expect(catalog.problems.first?.contains("2.json") == true)
    }

    @Test("a broken or future file is skipped whole, and the others load")
    func brokenFiles() throws {
        let builtin = try Self.directory(["a.json": Self.document(Self.whisper)])
        let user = try Self.directory([
            "broken.json": "{ not json",
            "future.json": #"{"schema": 2, "models": []}"#,
            "extra.json": #"{"schema": 1, "models": [], "comment": "x"}"#,
        ])
        defer {
            try? FileManager.default.removeItem(at: builtin)
            try? FileManager.default.removeItem(at: user)
        }
        let catalog = try LoadedCatalog.load(builtin: builtin, user: user)
        #expect(catalog.models.map(\.key) == ["ggml.whisper"])
        let problems = catalog.problems.joined(separator: "\n")
        #expect(problems.contains("broken.json"))
        #expect(problems.contains("future.json: schema 2"))
        #expect(problems.contains("extra.json") && problems.contains("'comment'"))
    }

    /// The one fatal case: without the built-in catalog nothing can be listed
    /// or run, and the message has to say where it looked.
    @Test("a built-in catalog that is missing or empty is an error")
    func builtinRequired() throws {
        let empty = try Self.directory([:])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: SpeechError.self) { _ = try LoadedCatalog.load(builtin: empty) }
        #expect(throws: (any Error).self) {
            _ = try LoadedCatalog.load(builtin: empty.appendingPathComponent("absent"))
        }
        let broken = try Self.directory(["a.json": "{}"])
        defer { try? FileManager.default.removeItem(at: broken) }
        #expect(throws: SpeechError.self) { _ = try LoadedCatalog.load(builtin: broken) }
    }

    @Test("the built-in directory: the override, then beside the binary, and it says where it looked")
    func builtinLocation() throws {
        let beside = try Self.directory([:])
        defer { try? FileManager.default.removeItem(at: beside) }
        let installed = beside.appendingPathComponent(Catalog.builtinDirectoryName)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        // Paths, not URLs: a URL built for a directory that exists carries a
        // trailing slash that one built before it existed does not.
        #expect(try Catalog.builtinDirectory(environment: [:], executableDirectory: beside).path
            == installed.path)
        #expect(try Catalog.builtinDirectory(
            environment: ["SPEECH_BUILTIN_CATALOG_DIR": beside.path],
            executableDirectory: beside).path == beside.path)
        #expect(throws: SpeechError.self) {
            _ = try Catalog.builtinDirectory(
                environment: ["SPEECH_BUILTIN_CATALOG_DIR": beside.appendingPathComponent("no").path],
                executableDirectory: beside)
        }
        #expect(Catalog.userDirectory(environment: ["SPEECH_CATALOG_DIR": "/x/y"]).path == "/x/y")
        #expect(Catalog.userDirectory(environment: [:]).path
            .hasSuffix("Library/Application Support/Speech/Catalog"))
    }
}
