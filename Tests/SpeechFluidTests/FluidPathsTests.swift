// FluidPathsTests.swift - pins the one assumption in this module that a
// dependency bump can silently break.
//
// FluidAudio rewrites every directory it is handed through a private
// `repoPath(from:)`, and `FluidPaths.parakeetRepo` works only because
// `<row>/<folderName>` is a fixed point of that rewrite. That holds while
// `folderName` is a single path component. It is one for all four
// `AsrModelVersion` repos today, and it is two for several other FluidAudio
// families (`nemotron-streaming/560ms`, `ls-eend/ami`), so the day a pin bump
// moves Parakeet to a nested repo name the workaround stops working - and it
// stops working *silently*, by downloading to a sibling directory and then
// passing its own completeness check against those sibling files while the row
// this program owns sits empty. That is not hypothetical; it is what happened
// on the first real download, before the workaround existed.
//
// These tests fabricate the file layout rather than downloading half a
// gigabyte, so they run in milliseconds and need no network.

import FluidAudio
import Foundation
import Testing
@testable import SpeechFluid
@testable import SpeechCore

@Suite("FluidAudio paths and completeness")
struct FluidPathsTests {
    private func makeRow() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-fluid-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The files `requiredModelsV3` asks for, minus the encoder, which is the
    /// one that differs by precision and is therefore the interesting part.
    private func populate(_ repo: URL, encoder: String) throws {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for name in ["Preprocessor.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
                     "parakeet_vocab.json", encoder] {
            try FileManager.default.createDirectory(
                at: repo.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    @Test("the repo directory sits inside the row, not beside it")
    func repoIsInsideTheRow() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        // The only non-tautological thing that can be said without invoking
        // FluidAudio: the repo must be a direct child of the row. This fails if
        // `folderName` ever gains a slash, as it has for several other
        // FluidAudio families (nemotron-streaming/560ms, ls-eend/ami), because
        // the rewrite has no fixed point for a multi-component name.
        //
        // Restating FluidAudio's formula here would prove nothing - derived
        // from `repo.lastPathComponent` it holds for any folder name at all,
        // including a wrong one. The real tripwire is
        // `completenessSeesOurFiles`, which drives their actual rewrite.
        let repo = FluidPaths.parakeetRepo(in: row, version: .v3)
        #expect(repo.deletingLastPathComponent().standardizedFileURL == row.standardizedFileURL)
    }

    @Test("modelsExist agrees with our layout, through FluidAudio's rewrite")
    func completenessSeesOurFiles() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let check = FluidModelFiles.parakeet(version: .v3, precision: .int8)
        #expect(check(row) == false)

        try populate(FluidPaths.parakeetRepo(in: row, version: .v3), encoder: "Encoder.mlmodelc")
        // If this fails, FluidAudio is looking somewhere other than where we
        // put the files - the original bug.
        #expect(check(row) == true)

        // The discriminating pair. Handed the repo directory, FluidAudio's own
        // rewrite is a no-op and finds the files; handed the *row* directory it
        // rewrites to a sibling and must not. Asserting both pins where the
        // rewrite lands rather than merely that the files are findable, which
        // is what makes this fail on a pin bump that renames the repo.
        #expect(AsrModels.modelsExist(
            at: FluidPaths.parakeetRepo(in: row, version: .v3),
            version: .v3, encoderPrecision: .int8) == true)
        #expect(AsrModels.modelsExist(
            at: row, version: .v3, encoderPrecision: .int8) == false)
    }

    @Test("an int8 download cannot satisfy an int4 row, or the reverse")
    func precisionsDoNotSatisfyEachOther() throws {
        let int8Row = try makeRow()
        let int4Row = try makeRow()
        defer {
            try? FileManager.default.removeItem(at: int8Row)
            try? FileManager.default.removeItem(at: int4Row)
        }

        try populate(FluidPaths.parakeetRepo(in: int8Row, version: .v3), encoder: "Encoder.mlmodelc")
        try populate(FluidPaths.parakeetRepo(in: int4Row, version: .v3), encoder: "EncoderInt4.mlmodelc")

        let int8 = FluidModelFiles.parakeet(version: .v3, precision: .int8)
        let int4 = FluidModelFiles.parakeet(version: .v3, precision: .int4)

        #expect(int8(int8Row) == true)
        #expect(int4(int4Row) == true)
        // The two rows share a repo folder name, so this is the check that
        // stops one download from making the other row look installed.
        #expect(int4(int8Row) == false)
        #expect(int8(int4Row) == false)
    }

    @Test("a variant is part of the row identity, and a typo is a usage error")
    func flavorParsing() throws {
        #expect(try ParakeetFlavor.parse(model: "parakeet-v3", variant: "int8").precision == .int8)
        #expect(try ParakeetFlavor.parse(model: "parakeet-v3", variant: "int4").precision == .int4)
        // A bare id means the default precision rather than being rejected.
        #expect(try ParakeetFlavor.parse(model: "parakeet-v3", variant: nil).precision == .int8)

        #expect(throws: SpeechError.self) {
            _ = try ParakeetFlavor.parse(model: "parakeet-v3", variant: "int9")
        }
        #expect(throws: SpeechError.self) {
            _ = try ParakeetFlavor.parse(model: "parakeet-v2", variant: "int8")
        }
    }

    @Test("loading never reports itself as downloading")
    func progressPhases() {
        // FluidAudio reports .downloading while merely checking a cache during
        // a load. Passed through, an installed model puts a download bar in
        // front of a user who is not downloading.
        let downloading = DownloadProgress(
            fractionCompleted: 0.5, phase: .downloading(completedFiles: 3, totalFiles: 11))
        #expect(FluidProgress.map(downloading, during: .loading).phase == .compiling)
        #expect(FluidProgress.map(downloading, during: .installing).phase == .downloading)

        // File counts, not an off-by-one: `completedFiles` is a finished count,
        // so rendering `completed + 1` printed "file 12 of 11" on the last event.
        let last = DownloadProgress(
            fractionCompleted: 1, phase: .downloading(completedFiles: 11, totalFiles: 11))
        #expect(FluidProgress.map(last, during: .installing).file == "11 of 11 files")

        // An empty model name is FluidAudio's placeholder and must not become
        // a blank filename in a status line.
        let empty = DownloadProgress(fractionCompleted: 1, phase: .compiling(modelName: ""))
        #expect(FluidProgress.map(empty, during: .loading).file == nil)
    }

    @Test("language hints map by primary subtag, and unknown ones are nil rather than fatal")
    func languageMapping() {
        #expect(FluidLanguage.parakeet("pl-PL")?.rawValue == "pl")
        #expect(FluidLanguage.parakeet("en")?.rawValue == "en")
        #expect(FluidLanguage.parakeet(nil) == nil)
        #expect(FluidLanguage.parakeet("") == nil)
        // Parakeet v3 is the European set; Japanese belongs to another family.
        #expect(FluidLanguage.parakeet("ja") == nil)

        // The languages the catalog advertises must be the ones it can map, or
        // `engines` lists a language that silently loses its hint.
        for tag in FluidLanguage.parakeetLanguages {
            #expect(FluidLanguage.parakeet(tag) != nil, "\(tag) is advertised but does not map")
        }
        // The rows that justify this engine existing at all: Apple ships no
        // model for any of these.
        for tag in ["pl", "cs", "uk", "sl", "bg", "et", "lv", "lt", "mt"] {
            #expect(FluidLanguage.parakeet(tag) != nil, "\(tag) should be supported")
        }
    }
}
