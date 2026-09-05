import Foundation
import Testing

@testable import SpeechCore
@testable import SpeechGGML

@Suite("ggml catalog")
struct GGMLCatalogTests {
    /// The repo and file names are derived, not listed, so this is the test
    /// that stands between a typo and a 404 halfway through `models download`.
    /// The expected strings below were checked against the live tree API.
    @Test("repository and file names follow the naming rule")
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
