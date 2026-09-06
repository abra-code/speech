// SileroVadTests.swift - the `fluid.silero-vad` row: what it claims, where its
// one bundle has to be, and what it refuses to do.
//
// The interesting part is the path. This family uses a third directory
// convention - the loader appends `Models` to what it is handed before the
// downloader appends the repo folder - so the download target and the load
// target are two different directories that have to agree.
//
// What the check below pins is our spelling of that convention, not the
// library's: it asserts where `FluidPaths.vadRepo` points and that the
// completeness check looks there. A pin bump that moved FluidAudio's own
// layout would still pass here and fail at load, which is the same limit
// every path test in this suite has.

import FluidAudio
import Foundation
import Testing
@testable import SpeechCore
@testable import SpeechFluid

@Suite("Silero VAD row")
struct SileroVadTests {
    private func makeRow() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-silero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBundle(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 16).write(to: url.appendingPathComponent("coremldata.bin"))
    }

    private func spec(_ row: URL) throws -> EngineSpec {
        try EngineSpec.parse(
            catalogID: "fluid.silero-vad", modelsDirectory: row.appendingPathComponent("store"))
    }

    // MARK: - The row

    @Test("the row is in the factory's listing and builds")
    func rowIsBuildable() throws {
        let listed = FluidEngineFactory.catalogRows.contains {
            $0.model == "silero-vad" && $0.variant == nil
        }
        #expect(listed)

        let row = try makeRow()
        let engine = try FluidEngineFactory.make(try spec(row))
        #expect(engine.id == "fluid.silero-vad")

        // No variants. The repository ships six exports of this model and the
        // loader opens exactly one of them, so a variant would name a row that
        // downloads the same bytes under a second id.
        #expect(throws: SpeechError.self) {
            _ = try FluidEngineFactory.make(try EngineSpec.parse(
                catalogID: "fluid.silero-vad@v6", modelsDirectory: row))
        }
    }

    @Test("it claims nothing, in any language")
    func capabilitiesAreEmpty() throws {
        let engine = try FluidEngineFactory.make(try spec(try makeRow()))
        let capabilities = engine.capabilities
        #expect(!capabilities.batch)
        #expect(!capabilities.live)
        #expect(!capabilities.wordTimestamps)
        #expect(!capabilities.segmentTimestamps)
        #expect(!capabilities.vocabulary)
        #expect(!capabilities.diarization)
        #expect(!capabilities.languageID)
        #expect(!capabilities.languageHint)
        // Empty is this record's "any language", and for a model that hears
        // speech as an acoustic event it is the literal truth.
        #expect(capabilities.languages.isEmpty)
    }

    @Test("the catalog row and the factory agree about the repository")
    func catalogAgreesWithTheFactory() throws {
        let row = try #require(Catalog.row(id: "fluid.silero-vad"))
        #expect(row.role == .helper)
        #expect(row.family == .silero)
        #expect(row.source == FluidEngineFactory.source(for: "silero-vad", variant: nil))
        // A helper row is still a download a user has to be able to size.
        #expect((row.sizeBytes ?? 0) > 0)
        // No parameter count is published for this export, and the field is in
        // millions, so a number here could only be a misleading zero.
        #expect(row.parametersM == nil)
    }

    @Test("it refuses to transcribe rather than pretending to")
    func refusesTranscription() async throws {
        let engine = try FluidEngineFactory.make(try spec(try makeRow()))
        await #expect(throws: SpeechError.self) {
            _ = try await engine.prepare(language: "en") { _ in }
        }
        await #expect(throws: SpeechError.self) {
            _ = try await engine.transcribe(samples: [0, 0, 0], options: TranscribeOptions())
        }
        await #expect(throws: SpeechError.self) {
            _ = try await engine.makeLiveSession(options: TranscribeOptions())
        }
    }

    // MARK: - Completeness

    @Test("completeness names the bundle the loader opens, where the loader looks")
    func completenessFollowsTheLoader() throws {
        let row = try makeRow()
        let check = try #require(
            try FluidEngineFactory.make(try spec(row)).completenessCheck)

        #expect(!check(row), "an empty row is not installed")

        // The trap this check exists for: the right bundle in the directory the
        // downloader would use if it were handed the row instead of the models
        // directory below it.
        let sibling = row.appendingPathComponent(Repo.vad.folderName, isDirectory: true)
        try makeBundle(sibling.appendingPathComponent(ModelNames.VAD.sileroVadFile))
        #expect(!check(row), "a bundle one component away is not this row's")

        // Where the loader will look, spelled out: `VadManager` appends
        // `Models` to the directory it is handed and `ModelHub` appends the
        // repo folder to that.
        let repo = FluidPaths.vadRepo(in: row)
        #expect(repo.path == row.appendingPathComponent("Models/silero-vad").path)

        // Another export from the same repository is not the one the loader
        // asks `ModelHub` for.
        try makeBundle(repo.appendingPathComponent("silero-vad-unified-256ms-v6.0.0.mlmodelc"))
        #expect(!check(row), "a different export of the same model is not this row")

        let bundle = repo.appendingPathComponent(ModelNames.VAD.sileroVadFile)
        try makeBundle(bundle)
        #expect(check(row))
    }

    @Test("a half-written bundle is not a model")
    func halfWrittenBundlesFail() throws {
        let row = try makeRow()
        let check = try #require(
            try FluidEngineFactory.make(try spec(row)).completenessCheck)
        let bundle = FluidPaths.vadRepo(in: row)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile)

        // The downloader creates the bundle directory before it fetches a
        // single file into it.
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(!check(row), "an empty bundle directory is not a model")

        try makeBundle(bundle)
        #expect(check(row))

        // And it stages each file as `<name>.partial`, so a bundle can hold its
        // manifest and still be missing the weights that were in flight.
        let staging = bundle.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4).write(
            to: staging.appendingPathComponent("weight.bin.partial"))
        #expect(!check(row), "a staging file left behind means the download is unfinished")
    }
}
