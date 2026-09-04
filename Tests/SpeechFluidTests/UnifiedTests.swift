// UnifiedTests.swift - where the Unified row's files land, and what makes it
// complete.
//
// This family is the best-behaved of the four: its downloader validates each
// bundle it fetched and purges a cache that fails to load, so none of the
// repair machinery Canary and Nemotron needed appears here. What still has to
// be pinned is the half `install` does not cover - `prepare` never downloads,
// so the completeness check must recognize a half-written bundle on its own,
// and it must look in the directory the loader will actually open.

import FluidAudio
import Foundation
import Testing
@testable import SpeechFluid
@testable import SpeechCore

@Suite("Parakeet Unified paths and completeness")
struct UnifiedTests {
    private func makeRow() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-unified-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBundle(_ directory: URL, _ name: String) throws {
        let bundle = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 16).write(
            to: bundle.appendingPathComponent("coremldata.bin"))
    }

    private func required(_ precision: UnifiedEncoderPrecision) -> [String] {
        let names = ModelNames.ParakeetUnified.self
        return [
            names.offlineEncoderFile(precision: precision),
            names.decoderFile,
            names.jointDecisionFile,
            names.vocab,
        ]
    }

    private func populate(_ row: URL, precision: UnifiedEncoderPrecision) throws {
        let repo = FluidPaths.unifiedRepo(in: row)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for name in required(precision) {
            if name.hasSuffix(".mlmodelc") {
                try makeBundle(repo, name)
            } else {
                try Data(repeating: 0x7B, count: 32).write(to: repo.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Paths

    @Test("the repo directory is inside the row, one component down")
    func repoIsInsideTheRow() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let repo = FluidPaths.unifiedRepo(in: row)
        // This family appends rather than rewriting the last component, so the
        // files stay under the row this program owns and can delete - unlike
        // AsrModels, which sent the first Parakeet download to a sibling.
        #expect(repo.deletingLastPathComponent().standardizedFileURL == row.standardizedFileURL)
        // Pinned to FluidAudio's own folder name rather than a literal, so a
        // pin bump that renames the repo moves the check with it. Note it is a
        // single component here; several other families' folder names are two.
        #expect(repo.lastPathComponent == Repo.parakeetUnified.folderName)
        #expect(!Repo.parakeetUnified.folderName.contains("/"))
    }

    // MARK: - Completeness

    @Test("a complete download reads as installed")
    func completeRowIsInstalled() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let check = FluidModelFiles.unified(precision: .int8)
        #expect(check(row) == false)
        try populate(row, precision: .int8)
        #expect(check(row) == true)
    }

    @Test("each required file is required")
    func everyRequirementBites() throws {
        for missing in required(.int8) {
            let row = try makeRow()
            defer { try? FileManager.default.removeItem(at: row) }

            try populate(row, precision: .int8)
            try FileManager.default.removeItem(
                at: FluidPaths.unifiedRepo(in: row).appendingPathComponent(missing))
            #expect(
                FluidModelFiles.unified(precision: .int8)(row) == false,
                "removing \(missing) should leave the row incomplete")
        }
    }

    @Test("a bundle directory the downloader has not filled is not a bundle")
    func emptyBundleIsIncomplete() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        try populate(row, precision: .int8)
        // What an interrupted fetch leaves: the downloader creates each bundle
        // directory before it fetches the files inside. `prepare` never
        // downloads, so if this read as installed the failure would surface as
        // a load error rather than as exit 3 and a download instruction.
        let encoder = FluidPaths.unifiedRepo(in: row)
            .appendingPathComponent(ModelNames.ParakeetUnified.offlineEncoderInt8File)
        try FileManager.default.removeItem(at: encoder.appendingPathComponent("coremldata.bin"))
        #expect(FluidModelFiles.unified(precision: .int8)(row) == false)
    }

    @Test("a staging file left inside a bundle makes it incomplete")
    func partialStagingFileIsIncomplete() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        try populate(row, precision: .int8)
        #expect(FluidModelFiles.unified(precision: .int8)(row) == true)

        // The second half of FluidAudio's own bundle validator, and the reason
        // `coremldata.bin` alone is not enough: files are staged as
        // `<name>.partial`, so a bundle can carry its manifest and still be
        // missing the weights that were in flight when the download died.
        let weights = FluidPaths.unifiedRepo(in: row)
            .appendingPathComponent(ModelNames.ParakeetUnified.offlineEncoderInt8File)
            .appendingPathComponent("weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data().write(to: weights.appendingPathComponent("weight.bin.partial"))
        #expect(FluidModelFiles.unified(precision: .int8)(row) == false)
    }

    @Test("an int8 download cannot satisfy an fp16 row, or the reverse")
    func precisionsDoNotSatisfyEachOther() throws {
        let int8Row = try makeRow()
        let fp16Row = try makeRow()
        defer {
            try? FileManager.default.removeItem(at: int8Row)
            try? FileManager.default.removeItem(at: fp16Row)
        }

        try populate(int8Row, precision: .int8)
        try populate(fp16Row, precision: .fp16)

        // The two encoders share a repo folder name and differ only in the
        // encoder file, so this is what stops one download from making the
        // other row look installed.
        #expect(FluidModelFiles.unified(precision: .int8)(int8Row) == true)
        #expect(FluidModelFiles.unified(precision: .fp16)(fp16Row) == true)
        #expect(FluidModelFiles.unified(precision: .fp16)(int8Row) == false)
        #expect(FluidModelFiles.unified(precision: .int8)(fp16Row) == false)
    }

    @Test("files loose in the row do not count as an install")
    func rowLevelFilesDoNotCount() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        // A check applied at the wrong level passes against files the loader
        // will never open - the Parakeet sibling bug in a different shape.
        for name in required(.int8) {
            if name.hasSuffix(".mlmodelc") {
                try makeBundle(row, name)
            } else {
                try Data(repeating: 0x7B, count: 32).write(to: row.appendingPathComponent(name))
            }
        }
        #expect(FluidModelFiles.unified(precision: .int8)(row) == false)
    }

    @Test("the preprocessor bundles the repo ships are not requirements")
    func preprocessorIsNotRequired() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        // The repository ships `parakeet_unified_preprocessor` and
        // `parakeet_unified_mel_encoder`, and the loader opens neither: the mel
        // front end is computed in Swift. Requiring what a repo happens to
        // contain rather than what the loader opens is the mistake that made
        // the Nemotron row uninstallable, so it is pinned here too.
        //
        // The assertion has to be that a row *carrying* those bundles still
        // reads complete. Asserting they are absent from a fixture that never
        // created them proves nothing and cannot fail.
        try populate(row, precision: .int8)
        let repo = FluidPaths.unifiedRepo(in: row)
        try makeBundle(repo, "parakeet_unified_preprocessor.mlmodelc")
        try makeBundle(repo, "parakeet_unified_mel_encoder.mlmodelc")
        #expect(FluidModelFiles.unified(precision: .int8)(row) == true)

        // And that removing them changes nothing, which is the half that would
        // fail if either were added to the required list.
        try FileManager.default.removeItem(
            at: repo.appendingPathComponent("parakeet_unified_preprocessor.mlmodelc"))
        try FileManager.default.removeItem(
            at: repo.appendingPathComponent("parakeet_unified_mel_encoder.mlmodelc"))
        #expect(FluidModelFiles.unified(precision: .int8)(row) == true)
    }

    // MARK: - Flavors

    @Test("both precisions parse, and a typo is a usage error")
    func flavorParsing() throws {
        #expect(try UnifiedFlavor.parse(model: "parakeet-unified", variant: "int8").precision == .int8)
        #expect(try UnifiedFlavor.parse(model: "parakeet-unified", variant: "fp16").precision == .fp16)
        // A bare id is the default precision, matching the other rows.
        #expect(try UnifiedFlavor.parse(model: "parakeet-unified", variant: nil).precision == .int8)

        // Both precisions really are published for this repo - checked against
        // the repository listing, after the Canary row turned out to declare a
        // precision the model repo does not ship.
        #expect(throws: SpeechError.self) {
            _ = try UnifiedFlavor.parse(model: "parakeet-unified", variant: "int4")
        }
        #expect(throws: SpeechError.self) {
            _ = try UnifiedFlavor.parse(model: "parakeet-unified-en", variant: "int8")
        }
    }

    @Test("the row is English only, and says so")
    func englishOnly() {
        let capabilities = FluidEngineFactory.capabilities(for: "parakeet-unified", variant: "int8")
        #expect(capabilities?.languages == ["en"])
        // A closed list rather than the Nemotron row's empty "any", so
        // `transcribe` warns on another tag instead of returning confident
        // English-shaped nonsense for Polish audio.
        #expect(capabilities?.supports(language: "en-US") == true)
        #expect(capabilities?.supports(language: "pl") == false)
    }
}
