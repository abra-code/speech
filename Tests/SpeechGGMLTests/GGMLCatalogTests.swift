import Foundation
import Testing

@testable import SpeechCore
@testable import SpeechGGML

@Suite("ggml catalog")
struct GGMLCatalogTests {
    /// The repo and file names are data now, and this is the test that stands
    /// between a typo in catalog/ggml.json and a 404 halfway through `models
    /// download`. The expected strings below were checked against the live
    /// tree API.
    @Test("the built-in repository and file names are the published ones")
    func naming() throws {
        let parakeet = try #require(GGMLCatalog.row(model: "parakeet-tdt-0.6b-v3"))
        #expect(parakeet.repo == "handy-computer/parakeet-tdt-0.6b-v3-gguf")
        #expect(parakeet.fileName(quant: "q8_0") == "parakeet-tdt-0.6b-v3-Q8_0.gguf")
        #expect(parakeet.fileName(quant: "q4_k_m") == "parakeet-tdt-0.6b-v3-Q4_K_M.gguf")

        // The case difference is the trap: HF paths are case-sensitive and this
        // row's repository is spelled `Qwen3-ASR-1.7B` while its catalog id is
        // lower-case throughout.
        let qwen = try #require(GGMLCatalog.row(model: "qwen3-asr-1.7b"))
        #expect(qwen.repo == "handy-computer/Qwen3-ASR-1.7B-gguf")
        #expect(qwen.fileName(quant: "q4_k_m") == "Qwen3-ASR-1.7B-Q4_K_M.gguf")
    }

    @Test("a bare id takes the row's best quantization")
    func defaultQuant() throws {
        let row = try #require(GGMLCatalog.row(model: "parakeet-tdt-0.6b-v3"))
        #expect(try GGMLCatalog.quant(for: row, variant: nil) == "q8_0")
        #expect(try GGMLCatalog.quant(for: row, variant: "Q4_K_M") == "q4_k_m")
    }

    @Test("an unknown quantization names the ones that exist")
    func unknownQuant() throws {
        let row = try #require(GGMLCatalog.row(model: "parakeet-tdt-0.6b-v3"))
        #expect(throws: SpeechError.self) {
            _ = try GGMLCatalog.quant(for: row, variant: "q3")
        }
    }

    @Test("every catalog row can actually be built")
    func everyRowBuilds() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        for (model, variant) in GGMLEngineFactory.catalogRows {
            let id = variant.map { "ggml.\(model)@\($0)" } ?? "ggml.\(model)"
            let spec = try EngineSpec.parse(catalogID: id, modelsDirectory: directory)
            let engine = try GGMLEngineFactory.make(spec)
            #expect(engine.id == id)
            // A row that is offered must never claim a capability the family
            // does not have; `vocabulary` is the one the whole library lacks.
            #expect(engine.capabilities.vocabulary == false)
        }
    }

    /// A model from any repository under any file name - the reason the naming
    /// rule went away - and each way an entry can be unusable, named.
    @Test("an entry becomes a row from its own file names, or says why it cannot")
    func entriesFromData() throws {
        let good = CatalogModel(
            engine: "ggml", model: "granite-speech-4.1-2b", family: CatalogFamily(rawValue: "granite"),
            source: "someone/Granite-GGUF", languages: ["en", "fr"], languageID: true,
            variants: [
                CatalogVariant(variant: "q8_0", file: "granite-q8.gguf", precision: "q8_0", label: "G (Q8)"),
                CatalogVariant(variant: "q4_k_m", file: "sub/granite-q4.gguf", precision: "q4_k_m", label: "G (Q4)"),
            ])
        let row = try GGMLRow.make(good).get()
        #expect(row.repo == "someone/Granite-GGUF")
        #expect(row.quants == ["q8_0", "q4_k_m"])
        #expect(row.defaultQuant == "q8_0")
        #expect(row.fileName(quant: "q4_k_m") == "sub/granite-q4.gguf")
        #expect(row.fileName(quant: "q6_k") == nil)
        #expect(row.languages == ["en", "fr"])
        #expect(row.languageID)
        // Flags the entry leaves out are claimed by nobody.
        #expect(!row.streaming && !row.wordTimestamps && !row.segmentTimestamps)

        func problem(_ edit: (inout CatalogModel) -> Void) -> String? {
            var entry = good
            edit(&entry)
            guard case .failure(let problem) = GGMLRow.make(entry) else { return nil }
            return problem.message
        }
        #expect(problem { $0.source = nil }?.contains("'source'") == true)
        #expect(problem { $0.variants = nil }?.contains("'variants'") == true)
        #expect(problem { $0.variants?[1].file = nil }?.contains("no 'file'") == true)
        #expect(problem { $0.variants?[0].file = "granite.bin" }?.contains("not a .gguf") == true)
        #expect(problem { $0.variants?[0].file = "../x.gguf" }?.contains("plain repository path") == true)
        #expect(problem { $0.variants?[0].file = "/x.gguf" }?.contains("plain repository path") == true)
        #expect(problem { $0.variants?[0].source = "elsewhere/repo" }?.contains("own 'source'") == true)
    }

    /// Presence is not enough: ggml maps a wrong file and fails several frames
    /// deep with a message about tensor shapes.
    @Test("completeness checks the GGUF magic, not just the file")
    func completeness() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(GGMLCatalog.isComplete(directory) == false, "empty directory")

        let weights = directory.appendingPathComponent(GGMLCatalog.weightsName)
        try Data("NOPE....".utf8).write(to: weights)
        #expect(GGMLCatalog.isComplete(directory) == false, "wrong magic")

        try Data("GGUF".utf8 + [0, 0, 0, 3]).write(to: weights)
        #expect(GGMLCatalog.isComplete(directory) == true)

        try Data().write(to: weights)
        #expect(GGMLCatalog.isComplete(directory) == false, "empty file")
    }
}
