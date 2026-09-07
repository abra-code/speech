// MLXCatalogTests.swift - the join between the shared catalog and the engine
// that will actually do the download.
//
// Two tables describe an `mlx` row: `SpeechCore.Catalog`, which is what a
// caller lists and chooses from, and `MLXCatalog`, which is what the engine
// fetches. Neither can see the other at compile time - the shared catalog must
// not depend on an engine target - so the only thing keeping them honest is
// this file. A row that exists in one and not the other, or that names a
// different repository or a different size in each, is a row that lists as one
// thing and downloads as another.

import Foundation
import Testing
import SpeechCore
@testable import SpeechMLX

@Suite("The MLX catalog")
struct MLXCatalogTests {
    /// Every `mlx.` row the shared catalog publishes.
    private var sharedRows: [CatalogRow] {
        Catalog.rows.filter { $0.engine == "mlx" }
    }

    @Test("the two catalogs describe the same set of rows")
    func theTwoCatalogsAgreeOnWhichRowsExist() {
        let shared = Set(sharedRows.map(\.id))
        let engine = Set(MLXCatalog.rows.map(\.id))
        #expect(shared == engine, "listed: \(shared.sorted()); buildable: \(engine.sorted())")
        // Not vacuous: if both tables were empty this would pass.
        #expect(engine.count >= 5)
    }

    @Test("a listed row names the repository and the size the engine will use")
    func theTwoCatalogsAgreeOnTheFacts() throws {
        for listed in sharedRows {
            let spec = try EngineSpec.parse(
                catalogID: listed.id, modelsDirectory: URL(fileURLWithPath: "/tmp"))
            let row = try #require(
                MLXCatalog.row(model: spec.model, variant: spec.variant),
                "no MLXCatalog row for \(listed.id)")
            #expect(listed.source == row.repo, "\(listed.id) source")
            #expect(listed.sizeBytes == row.sizeBytes, "\(listed.id) size")
            #expect(listed.parametersM == row.parametersM, "\(listed.id) parameters")
            #expect(listed.precision == row.precision, "\(listed.id) precision")
            #expect(listed.label == row.label, "\(listed.id) label")
            // `file` names a single downloadable file, which is a GGUF thing.
            // An MLX row is a directory of them, and MLXCatalog owns the list.
            #expect(listed.file == nil, "\(listed.id) should name no single file")
        }
    }

    @Test("every row builds through the factory and reports what its row claims")
    func everyRowBuilds() throws {
        for row in MLXCatalog.rows {
            let spec = try EngineSpec.parse(
                catalogID: row.id, modelsDirectory: URL(fileURLWithPath: "/tmp"))
            let engine = try MLXEngineFactory.make(spec)
            #expect(engine.id == row.id)
            #expect(engine.capabilities.languages == row.languages)
            #expect(engine.capabilities.languageID == row.languageID)
            #expect(engine.capabilities.segmentTimestamps == row.segmentTimestamps)
            // No row streams: the protocol has no streaming request, and a row
            // that claimed otherwise would be offered to `speech stream` and
            // then refused by the engine.
            #expect(!engine.capabilities.live)
            // And none reports word alignment, because none of the eight types
            // the helper implements returns any.
            #expect(!engine.capabilities.wordTimestamps)
        }
    }

    @Test("an unknown model and an unknown variant fail differently, and both say what exists")
    func unknownIdsExplainThemselves() throws {
        let directory = URL(fileURLWithPath: "/tmp")
        let unknownModel = try EngineSpec.parse(catalogID: "mlx.nope", modelsDirectory: directory)
        #expect(throws: SpeechError.self) { _ = try MLXEngineFactory.make(unknownModel) }
        do {
            _ = try MLXEngineFactory.make(unknownModel)
        } catch let error as SpeechError {
            #expect(error.message.contains("parakeet-tdt-0.6b-v3"))
        }

        // A real model at a precision nobody published. Answering "unknown
        // model" here would send the reader looking for a typo in the half of
        // the id that is correct.
        let unknownVariant = try EngineSpec.parse(
            catalogID: "mlx.qwen3-asr-1.7b@3bit", modelsDirectory: directory)
        do {
            _ = try MLXEngineFactory.make(unknownVariant)
            Issue.record("3bit is not published and should not build")
        } catch let error as SpeechError {
            #expect(error.message.contains("8bit"))
            #expect(error.message.contains("4bit"))
        }
    }

    @Test("every asset a row lists is a plain file name, and every row has weights")
    func assetsAreDownloadable() {
        for row in MLXCatalog.rows {
            #expect(!row.assets.isEmpty, "\(row.id) downloads nothing")
            #expect(row.assets.contains { $0.file.hasSuffix(".safetensors") }, "\(row.id) has no weights")
            #expect(row.assets.contains { $0.file == "config.json" }, "\(row.id) has no config")
            for asset in row.assets {
                // Each becomes a path component under the model directory, so a
                // separator or a traversal in one would write outside the store.
                #expect(!asset.file.contains("/"), "\(row.id): \(asset.file)")
                #expect(!asset.file.hasPrefix("."), "\(row.id): \(asset.file)")
                #expect(asset.repo.split(separator: "/").count == 2, "\(row.id): \(asset.repo)")
            }
        }
    }

    @Test("whisper takes its tokenizer from the repository that has one")
    func whisperBorrowsATokenizer() throws {
        // The MLX conversion ships config.json and weights.safetensors and
        // nothing else, and mlx-audio-swift's loader goes to the network for
        // tokenizer assets when tokenizer.json is absent - which the helper
        // refuses. So this row is the one that downloads from two repositories,
        // and if that ever silently becomes one, the row stops loading offline.
        let row = try #require(MLXCatalog.row(model: "whisper-large-v3-turbo", variant: nil))
        let tokenizer = try #require(row.assets.first { $0.file == "tokenizer.json" })
        #expect(tokenizer.repo == "openai/whisper-large-v3-turbo")
        #expect(tokenizer.repo != row.repo)
        #expect(row.assets.filter { $0.repo == row.repo }.count == 2)

        // And all eight of them, not just the one the loader tests for. A row
        // with tokenizer.json alone downloads, installs, and then fails to load
        // with `missingConfig` - which is what the first version of this row
        // did. The list is mlx-audio-swift's own.
        let wanted = Set([
            "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
            "added_tokens.json", "vocab.json", "merges.txt", "normalizer.json",
            "generation_config.json",
        ])
        let fetched = Set(row.assets.filter { $0.repo == tokenizer.repo }.map(\.file))
        #expect(fetched == wanted, "missing: \(wanted.subtracting(fetched).sorted())")
    }

    @Test("a directory is complete when the row's own files are there, and not before")
    func completenessAsksTheRowWhatItFetched() throws {
        // A config plus any .safetensors is not enough to say: a Parakeet row
        // needs its tokenizer.model, tokenizer.vocab and vocab.txt, and nothing
        // generic would notice those missing. What the check must NOT require
        // is a file the library writes for itself - the Qwen3-ASR loader puts
        // its own tokenizer.json in the directory, and it is in no asset list.
        let row = try #require(MLXCatalog.row(model: "parakeet-tdt_ctc-110m", variant: nil))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!MLXCatalog.isComplete(directory, row: row))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("w".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        #expect(
            !MLXCatalog.isComplete(directory, row: row),
            "a config and weights with no tokenizer is not a loadable Parakeet")

        for asset in row.assets {
            try? Data("x".utf8).write(to: directory.appendingPathComponent(asset.file))
        }
        #expect(MLXCatalog.isComplete(directory, row: row))

        // And a file the library writes later neither helps nor is required.
        let written = directory.appendingPathComponent("tokenizer.json")
        #expect(!row.assets.contains { $0.file == "tokenizer.json" })
        try Data("{}".utf8).write(to: written)
        #expect(MLXCatalog.isComplete(directory, row: row))
    }

    @Test("every row puts a ceiling on how much audio the helper holds at once")
    func everyRowBoundsWhatItHandsOver() {
        // The helper transcribes what it is given, and a recording is as long
        // as a user's recording. Measured on one hour of continuous speech,
        // with no ceiling: Parakeet v3 peaked at 21.91 GB and ran at 41.9x,
        // against 4.55 GB and 153.4x with one; Qwen3-ASR scored 21.66% WER
        // against 15.13%, because `max_tokens` is one budget spent across a
        // whole request and the tail runs out of it; Whisper, which cuts its
        // own input, still held 5.27 GB against 4.31 GB.
        //
        // So this is not a per-model tuning knob to be set where it seems to
        // help. It is an invariant: a row with no ceiling is a row whose cost
        // is set by the length of the file someone opens.
        for row in MLXCatalog.rows {
            #expect(row.maxSeconds > 0, "\(row.id) would hand the helper a whole recording")
            #expect(row.maxSeconds <= 600, "\(row.id) has a ceiling too high to be one")
        }
        #expect(MLXCatalog.rows.count >= 5)
    }

    @Test("a chunk's timestamps are placed where the chunk was")
    func segmentsAreOffsetIntoTheRecording() {
        // The helper is never told where its buffer came from, so this is the
        // only place a second chunk's spans can be put back in the file they
        // came out of. Getting it wrong produces a transcript whose text is
        // right and whose timings all belong to the first chunk.
        let result = MLXTranscription(
            segments: [
                .init(id: 2, index: 0, start: 0.5, end: 1.5, text: "first"),
                // In the middle, not at the end, and that placement is the
                // test: a blank span numbered before it is dropped leaves a
                // hole in the ids, and a blank one at the end would not.
                .init(id: 2, index: 1, start: 1.5, end: 2.0, text: "   "),
                .init(id: 2, index: 2, start: 2.0, end: 2.5, text: "  second  "),
            ],
            done: .init(id: 2, seconds: 0.1, segments: 3, synthesized: false))
        let segments = MLXEngine.segments(from: result, offset: 30, firstID: 4, language: "pl")

        // The blank one is dropped: a span with no text is not a transcript of
        // anything, and it would score as an insertion.
        #expect(segments.count == 2)
        #expect(segments[0].start == 30.5)
        #expect(segments[0].end == 31.5)
        #expect(segments[0].id == 4)
        #expect(segments[1].text == "second")
        #expect(segments[1].start == 32.0)
        // Contiguous, not merely increasing. The next chunk is numbered from
        // the count of what came back, so a gap here - which is what numbering
        // before dropping the blank span produces - collides with it.
        #expect(segments[1].id == 5)
        #expect(segments[0].language == "pl")
        #expect(segments[0].words == nil)
    }
}
