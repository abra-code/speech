// VocabularyTests.swift - the CTC spotter row: where it lands, what makes it
// complete, and that it refuses to pretend to be a transcriber.
//
// The rescoring itself needs 103 MB of weights and real audio, so it is
// measured by hand rather than here. What is testable without a download is the
// part that decides whether the feature can work at all: a path convention that
// differs from every other family in this module, and a required file
// FluidAudio's own check does not ask for.

import FluidAudio
import Foundation
import Testing
@testable import SpeechFluid
@testable import SpeechCore

@Suite("Vocabulary spotter row")
struct VocabularyTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-vocab-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBundle(_ directory: URL, _ name: String) throws {
        let bundle = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 16).write(
            to: bundle.appendingPathComponent("coremldata.bin"))
    }

    /// Everything the row needs to be usable, which is not the same as
    /// everything FluidAudio's own check asks for.
    private func populate(_ row: URL) throws {
        let repo = FluidPaths.ctcRepo(in: row)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try makeBundle(repo, ModelNames.CTC.melSpectrogramPath)
        try makeBundle(repo, ModelNames.CTC.audioEncoderPath)
        try Data(repeating: 0x7B, count: 32).write(
            to: repo.appendingPathComponent(ModelNames.CTC.vocabularyPath))
        try Data(repeating: 0x7B, count: 32).write(
            to: repo.appendingPathComponent("tokenizer.json"))
    }

    // MARK: - Paths

    @Test("the repo directory is inside the row, one component down")
    func repoIsInsideTheRow() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try VocabularySpotter.directory(modelsDirectory: root)

        // This family uses the `AsrModels` convention: `download(to:)` takes
        // the target directory and hands its *parent* to ModelHub, which
        // appends the repo folder back on. Handing it the row would therefore
        // write to the row's sibling - the original Parakeet bug - so the fixed
        // point is `<row>/<folderName>`.
        let repo = FluidPaths.ctcRepo(in: row)
        #expect(repo.deletingLastPathComponent().standardizedFileURL == row.standardizedFileURL)
        // The property that makes the round trip work, and the one a pin bump
        // can break: the folder name has to be a single component. Several
        // other families' names are two ("nemotron-streaming/2240ms",
        // "kokoro-82m-coreml/ANE"), and for one of those the parent-then-append
        // dance would land somewhere else entirely.
        #expect(!CtcModelVariant.ctc110m.repo.folderName.contains("/"))
    }

    @Test("the spotter row is inside the store, so delete can reach it")
    func rowIsDeletable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The point of the whole exercise. Asked through the store's own
        // containment check - the one `delete` consults before an `rm -rf` -
        // rather than by comparing prefixes, because that check is the thing
        // that has to say yes.
        let store = ModelStore(root: root)
        let row = try VocabularySpotter.directory(modelsDirectory: root)
        #expect(store.isContained(FluidPaths.ctcRepo(in: row)))
        #expect(try store.delete(
            VocabularySpotter.spec(modelsDirectory: root)) == false)  // nothing there yet

        try populate(row)
        #expect(try store.delete(VocabularySpotter.spec(modelsDirectory: root)) == true)
        #expect(!FileManager.default.fileExists(atPath: row.path))
    }

    // MARK: - Completeness

    @Test("a complete spotter row reads as installed")
    func completeRowIsInstalled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try VocabularySpotter.directory(modelsDirectory: root)

        #expect(FluidModelFiles.ctc(row) == false)
        try populate(row)
        #expect(FluidModelFiles.ctc(row) == true)
    }

    @Test("tokenizer.json is required, though FluidAudio's own check ignores it")
    func tokenizerIsRequired() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try VocabularySpotter.directory(modelsDirectory: root)
        let repo = FluidPaths.ctcRepo(in: row)

        try populate(row)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("tokenizer.json"))

        // Their `modelsExist` covers the two bundles and vocab.json and is
        // satisfied here. The spotter itself never opens tokenizer.json - but
        // `VocabularyRescorer.create` does, through `CtcTokenizer`, so without
        // this the row would install cleanly, report `installed`, and fail the
        // first time somebody passed --vocab.
        #expect(CtcModels.modelsExist(at: repo) == true)
        #expect(FluidModelFiles.ctc(row) == false)
    }

    @Test("each required file is required")
    func everyRequirementBites() throws {
        let names = [
            ModelNames.CTC.melSpectrogramPath,
            ModelNames.CTC.audioEncoderPath,
            ModelNames.CTC.vocabularyPath,
            "tokenizer.json",
        ]
        for missing in names {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let row = try VocabularySpotter.directory(modelsDirectory: root)

            try populate(row)
            try FileManager.default.removeItem(
                at: FluidPaths.ctcRepo(in: row).appendingPathComponent(missing))
            #expect(
                FluidModelFiles.ctc(row) == false,
                "removing \(missing) should leave the row incomplete")
        }
    }

    @Test("an unfilled bundle is not a bundle here either")
    func emptyBundleIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try VocabularySpotter.directory(modelsDirectory: root)

        try populate(row)
        try FileManager.default.removeItem(
            at: FluidPaths.ctcRepo(in: row)
                .appendingPathComponent(ModelNames.CTC.audioEncoderPath)
                .appendingPathComponent("coremldata.bin"))
        #expect(FluidModelFiles.ctc(row) == false)
    }

    @Test("a staging file left inside a bundle makes it incomplete")
    func partialStagingFileIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try VocabularySpotter.directory(modelsDirectory: root)

        try populate(row)
        #expect(FluidModelFiles.ctc(row) == true)
        // The half of the bundle validator the other rows' tests cover and this
        // one did not: files are staged as `<name>.partial`, so a bundle can
        // carry its manifest and still be missing the weights that were in
        // flight. This is also the state an interrupted CTC download leaves.
        let weights = FluidPaths.ctcRepo(in: row)
            .appendingPathComponent(ModelNames.CTC.audioEncoderPath)
            .appendingPathComponent("weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data().write(to: weights.appendingPathComponent("weight.bin.partial"))
        #expect(FluidModelFiles.ctc(row) == false)
    }

    @Test("files loose in the row do not count as an install")
    func rowLevelFilesDoNotCount() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try VocabularySpotter.directory(modelsDirectory: root)
        try FileManager.default.createDirectory(at: row, withIntermediateDirectories: true)

        try makeBundle(row, ModelNames.CTC.melSpectrogramPath)
        try makeBundle(row, ModelNames.CTC.audioEncoderPath)
        try Data().write(to: row.appendingPathComponent(ModelNames.CTC.vocabularyPath))
        try Data().write(to: row.appendingPathComponent("tokenizer.json"))
        // The sibling-directory bug in its other form: a check applied one
        // level up passes against files the loader will never open.
        #expect(FluidModelFiles.ctc(row) == false)
    }

    // MARK: - The row is not a transcriber

    @Test("the spotter claims no capability at all")
    func spotterClaimsNothing() {
        let capabilities = FluidEngineFactory.capabilities(
            for: "parakeet-ctc-110m", variant: nil)
        #expect(capabilities?.batch == false)
        #expect(capabilities?.live == false)
        #expect(capabilities?.wordTimestamps == false)
        #expect(capabilities?.segmentTimestamps == false)
        // Emphatically not `vocabulary: true`: this row *is* the vocabulary
        // machinery for other rows, and claiming the capability would file it
        // under engines that accept hotwords.
        #expect(capabilities?.vocabulary == false)
    }

    @Test("preparing or transcribing the spotter is a usage error, not a crash")
    func spotterRefusesToTranscribe() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try FluidEngineFactory.make(
            try EngineSpec.parse(
                catalogID: VocabularySpotter.catalogID, modelsDirectory: root))

        await #expect(throws: SpeechError.self) {
            _ = try await engine.prepare(language: nil) { _ in }
        }
        await #expect(throws: SpeechError.self) {
            _ = try await engine.transcribe(samples: [0, 0, 0], options: TranscribeOptions())
        }
        // It still owns a completeness check, because that is how `models
        // status` and `models list` report it.
        #expect(engine.completenessCheck != nil)
    }

    @Test("the spotter has no variants")
    func spotterHasNoVariants() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: SpeechError.self) {
            _ = try FluidEngineFactory.make(
                try EngineSpec.parse(
                    catalogID: "fluid.parakeet-ctc-110m@int8", modelsDirectory: root))
        }
    }

    @Test("the rows that can use a vocabulary say so")
    func hostRowsAdvertiseVocabulary() {
        #expect(FluidEngineFactory.capabilities(for: "parakeet-v3", variant: "int8")?
            .vocabulary == true)
        #expect(FluidEngineFactory.capabilities(for: "parakeet-unified", variant: "int8")?
            .vocabulary == true)
        // Not wired for these two. Canary has its own keyword booster with a
        // different mechanism, and the Nemotron manager exposes no hook at all.
        #expect(FluidEngineFactory.capabilities(for: "canary-1b-v2", variant: "int4")?
            .vocabulary == false)
        #expect(FluidEngineFactory.capabilities(for: "nemotron-multilingual", variant: "2240")?
            .vocabulary == false)
    }
}
