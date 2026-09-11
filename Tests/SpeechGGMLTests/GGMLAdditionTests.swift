// GGMLAdditionTests.swift - the guesses `speech models add` makes from a
// repository listing and a file name, and the entry it writes from a loaded
// model. The network and the model are the command's business; these are the
// parts that can be wrong without either.

import Foundation
import Testing

@testable import SpeechCore
@testable import SpeechGGML

@Suite("Adding a ggml model")
struct GGMLAdditionTests {
    @Test("a file name splits into its model and its quantization")
    func split() {
        #expect(GGMLAddition.split("Qwen3-ASR-1.7B-Q4_K_M.gguf") == ("Qwen3-ASR-1.7B", "Q4_K_M"))
        #expect(GGMLAddition.split("granite-speech-4.1-2b-Q8_0.gguf") == ("granite-speech-4.1-2b", "Q8_0"))
        #expect(GGMLAddition.split("sub/dir/model-IQ4_XS.gguf") == ("model", "IQ4_XS"))
        #expect(GGMLAddition.split("whisper-large-v3-turbo-BF16.gguf") == ("whisper-large-v3-turbo", "BF16"))
        // No quantization in the name: the whole stem, and none.
        #expect(GGMLAddition.split("model.gguf") == ("model", nil))
        #expect(GGMLAddition.split("parakeet-tdt-0.6b-v3.gguf") == ("parakeet-tdt-0.6b-v3", nil))
    }

    static let listing = [
        "README.md",
        "granite-speech-4.1-2b-BF16.gguf",
        "granite-speech-4.1-2b-Q4_K_M.gguf",
        "granite-speech-4.1-2b-Q8_0.gguf",
    ]

    @Test("the file: explicit, then by quantization, then the only one or Q8_0")
    func choose() throws {
        let repo = "o/r"
        #expect(try GGMLAddition.chooseFile(from: Self.listing, quant: nil, file: nil, repo: repo)
            == "granite-speech-4.1-2b-Q8_0.gguf")
        #expect(try GGMLAddition.chooseFile(from: Self.listing, quant: "q4_k_m", file: nil, repo: repo)
            == "granite-speech-4.1-2b-Q4_K_M.gguf")
        #expect(try GGMLAddition.chooseFile(
            from: Self.listing, quant: nil, file: "granite-speech-4.1-2b-BF16.gguf", repo: repo)
            == "granite-speech-4.1-2b-BF16.gguf")
        #expect(try GGMLAddition.chooseFile(from: ["x.gguf"], quant: nil, file: nil, repo: repo) == "x.gguf")
    }

    @Test("an ambiguous or impossible choice asks, and says what there is")
    func chooseRefuses() {
        func message(_ listing: [String], quant: String? = nil, file: String? = nil) -> String? {
            do {
                _ = try GGMLAddition.chooseFile(from: listing, quant: quant, file: file, repo: "o/r")
                return nil
            } catch let error as SpeechError {
                return error.message
            } catch {
                return "\(error)"
            }
        }
        #expect(message(["README.md"])?.contains("no .gguf files") == true)
        #expect(message(Self.listing, quant: "q6_k")?.contains("no Q6_K file") == true)
        #expect(message(Self.listing, file: "nope.gguf")?.contains("does not list 'nope.gguf'") == true)
        // Several files and no Q8_0: nothing is picked for the user.
        let noQ8 = ["m-Q4_K_M.gguf", "m-Q6_K.gguf"]
        let several = message(noQ8)
        #expect(several?.contains("--quant") == true)
        #expect(several?.contains("m-Q6_K.gguf") == true)
    }

    @Test("names become id components, or nothing")
    func names() {
        #expect(GGMLAddition.idName("Qwen3-ASR-1.7B") == "qwen3-asr-1.7b")
        #expect(GGMLAddition.idName("granite_nar") == "granite_nar")
        #expect(GGMLAddition.idName("My Model!") == "my-model-")
        #expect(GGMLAddition.idName("--") == nil)
        #expect(GGMLAddition.modelName(stem: "Granite-Speech-4.1-2B", repo: "o/x-gguf") == "granite-speech-4.1-2b")
        #expect(GGMLAddition.modelName(stem: "__", repo: "o/Some-Model-GGUF") == "some-model")
        // Architectures are spelled with underscores, families with hyphens.
        #expect(GGMLAddition.family(architecture: "qwen3_asr") == .qwen3ASR)
        #expect(GGMLAddition.family(architecture: "granite_speech").rawValue == "granite-speech")
        #expect(GGMLAddition.family(architecture: "").rawValue == "unknown")
    }

    @Test("a new entry records what the loaded model said, and loads back unchanged")
    func entryFromProbe() throws {
        let probe = GGMLProbe(
            architecture: "granite", variant: "", languages: ["en", "fr", "de"], languageID: true,
            streaming: false, wordTimestamps: false, segmentTimestamps: true, maxAudioSeconds: 600)
        let variant = GGMLAddition.variant(
            name: "q8_0", file: "g-Q8_0.gguf", sizeBytes: 42, label: "g (Q8_0)")
        let entry = GGMLAddition.entry(
            model: "g", repo: "o/g-gguf", variant: variant, probe: probe,
            date: Date(timeIntervalSince1970: 1_788_000_000))
        #expect(entry.key == "ggml.g")
        #expect(entry.family.rawValue == "granite")
        #expect(entry.languages == ["en", "fr", "de"])
        #expect(entry.languageID == true && entry.streaming == false)
        #expect(entry.wordTimestamps == false && entry.segmentTimestamps == true)
        #expect(entry.note?.contains("architecture granite") == true)
        #expect(entry.note?.contains("600 s") == true)
        #expect(entry.problem() == nil)
        let row = try GGMLRow.make(entry).get()
        #expect(row.fileName(quant: "q8_0") == "g-Q8_0.gguf")

        // What `models add` writes is what the next run reads.
        let data = try LoadedCatalog.documentData(models: [entry])
        let decoded = try JSONDecoder().decode(CatalogDocument.self, from: data)
        #expect(decoded.schema == 1)
        #expect(try decoded.models.first?.get() == entry)
        // Written deterministically, and without nulls or defaults a person
        // would not have typed.
        #expect(try LoadedCatalog.documentData(models: [entry]) == data)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("null"))
        #expect(!text.contains("\"role\"") && !text.contains("\"hidden\""))
        #expect(text.hasSuffix("\n"))
    }
}

@Suite("Stream settings in the catalog")
struct CatalogStreamTests {
    static func decode(_ json: String) throws -> CatalogStream {
        try JSONDecoder().decode(CatalogStream.self, from: Data(json.utf8))
    }

    @Test("each kind takes its own settings and no others")
    func kinds() throws {
        let nemotron = try Self.decode(#"{"kind": "parakeet_stream", "att_context_right": 0}"#)
        #expect(nemotron.kind == "parakeet_stream" && nemotron.attContextRight == 0)
        let buffered = try Self.decode(#"{"kind": "parakeet_buffered", "chunk_ms": 1000}"#)
        #expect(buffered.chunkMs == 1000 && buffered.leftMs == nil)
        #expect(try Self.decode(#"{"kind": "none"}"#).kind == "none")

        // A setting given to the wrong kind would be silently ignored.
        #expect(throws: DecodingError.self) {
            _ = try Self.decode(#"{"kind": "parakeet_buffered", "att_context_right": 0}"#)
        }
        #expect(throws: DecodingError.self) { _ = try Self.decode(#"{"kind": "moonshine"}"#) }
        #expect(throws: DecodingError.self) { _ = try Self.decode(#"{"kind": "none", "speed": 2}"#) }
    }

    /// The two streaming models in the built-in catalog carry the settings the
    /// engine used to choose in code; this is what keeps them from drifting.
    @Test("the built-in streaming models name the extension they were measured with")
    func builtinStreams() throws {
        let catalog = try LoadedCatalog.load(builtin: try Catalog.builtinDirectory())
        let nemotron = try #require(catalog.models.first { $0.key == "ggml.nemotron-3.5-asr-streaming-0.6b" })
        #expect(nemotron.stream == CatalogStream(kind: "parakeet_stream", attContextRight: 0))
        let unified = try #require(catalog.models.first { $0.key == "ggml.parakeet-unified-en-0.6b" })
        #expect(unified.stream == CatalogStream(kind: "parakeet_buffered"))
        // Every ggml model that claims to stream says how.
        for model in catalog.models where model.engine == "ggml" && model.streaming == true {
            #expect(model.stream != nil, "\(model.key)")
        }
    }
}
