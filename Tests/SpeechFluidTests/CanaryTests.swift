// CanaryTests.swift - the completeness check that decides whether an
// interrupted Canary download can ever be repaired.
//
// FluidAudio's `CanaryModels.modelsExist` is `fileExists` over five names, four
// of which are `.mlmodelc` *directories*, and its downloader creates each of
// those directories before it fetches a single file inside. So for most of a
// 569 MB download all five paths exist and none of the weights do. Two things
// in this module depend on getting that window right, and both are tested here
// without downloading anything: whether a row reads as installed, and whether a
// retry actually re-fetches instead of short-circuiting forever.

import FluidAudio
import Foundation
import Testing
@testable import SpeechFluid
@testable import SpeechCore

@Suite("Canary completeness and cache repair")
struct CanaryTests {
    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-canary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The bundle directories the downloader creates before filling them.
    private func makeEmptyBundles(_ directory: URL) throws {
        for name in FluidModelFiles.canaryBundles(precision: .int4) {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("\(name).mlmodelc"),
                withIntermediateDirectories: true)
        }
    }

    private func fill(_ directory: URL, _ name: String) throws {
        try Data(repeating: 0x42, count: 16).write(
            to: directory.appendingPathComponent("\(name).mlmodelc/coremldata.bin"))
    }

    private func writeVocabulary(_ directory: URL, bytes: Int = 32) throws {
        try Data(repeating: 0x7B, count: bytes).write(
            to: directory.appendingPathComponent(ModelNames.Canary.vocabularyFile))
    }

    @Test("empty bundle directories are not an installed model")
    func emptyBundlesAreNotInstalled() throws {
        let row = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: row) }

        // Exactly what an interruption a few seconds into the download leaves,
        // and exactly what FluidAudio's own check calls complete. Reported as
        // installed, this row clears its partial marker, shows 0 B in
        // `models list`, and fails at `MLModel(contentsOf:)` much later instead
        // of at exit 3 with a download instruction.
        try makeEmptyBundles(row)
        try writeVocabulary(row)
        #expect(CanaryModels.modelsExist(at: row, precision: .int4) == true)
        #expect(FluidModelFiles.canary(precision: .int4)(row) == false)
    }

    @Test("a filled bundle set is an installed model")
    func filledBundlesAreInstalled() throws {
        let row = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: row) }

        try makeEmptyBundles(row)
        try writeVocabulary(row)
        for name in FluidModelFiles.canaryBundles(precision: .int4) {
            try fill(row, name)
        }
        #expect(FluidModelFiles.canary(precision: .int4)(row) == true)
    }

    @Test("every bundle is required, one at a time")
    func everyBundleBites() throws {
        for missing in FluidModelFiles.canaryBundles(precision: .int4) {
            let row = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: row) }

            try makeEmptyBundles(row)
            try writeVocabulary(row)
            for name in FluidModelFiles.canaryBundles(precision: .int4) where name != missing {
                try fill(row, name)
            }
            #expect(
                FluidModelFiles.canary(precision: .int4)(row) == false,
                "an unfilled \(missing) should leave the row incomplete")
        }
    }

    @Test("an int4 row is not satisfied by fp16 weights")
    func precisionsDoNotSatisfyEachOther() throws {
        let row = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: row) }

        // The shared cache is keyed by repository, not by precision, so this is
        // the layout another application's download produces in the very
        // directory an int4 install writes into.
        try writeVocabulary(row)
        for name in FluidModelFiles.canaryBundles(precision: .fp16) {
            try FileManager.default.createDirectory(
                at: row.appendingPathComponent("\(name).mlmodelc"),
                withIntermediateDirectories: true)
            try fill(row, name)
        }
        #expect(FluidModelFiles.canary(precision: .fp16)(row) == true)
        #expect(FluidModelFiles.canary(precision: .int4)(row) == false)
    }

    @Test("a staging file left inside a bundle makes it incomplete")
    func partialStagingFileIsIncomplete() throws {
        let row = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: row) }

        try makeEmptyBundles(row)
        try writeVocabulary(row)
        for name in FluidModelFiles.canaryBundles(precision: .int4) {
            try fill(row, name)
        }
        #expect(FluidModelFiles.canary(precision: .int4)(row) == true)

        // The half this check was missing until it moved onto FluidAudio's own
        // bundle validator: files are staged as `<name>.partial`, so a bundle
        // can carry its manifest and still be missing the weights that were in
        // flight when the download died.
        let weights = row.appendingPathComponent("EncoderInt4.mlmodelc/weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data().write(to: weights.appendingPathComponent("weight.bin.partial"))
        #expect(FluidModelFiles.canary(precision: .int4)(row) == false)
    }

    @Test("eviction clears the wreckage that would block a retry")
    func evictionUnblocksARetry() throws {
        let cache = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }

        try makeEmptyBundles(cache)
        try writeVocabulary(cache, bytes: 0)
        // FluidAudio's downloader early-returns on its own check, so while this
        // holds, every retry fetches nothing and the install can never
        // complete. The user is told to retry, and retrying cannot work.
        #expect(CanaryModels.modelsExist(at: cache, precision: .int4) == true)

        FluidModelFiles.evictIncompleteCanary(at: cache, precision: .int4)

        #expect(CanaryModels.modelsExist(at: cache, precision: .int4) == false)
        for name in FluidModelFiles.canaryBundles(precision: .int4) {
            #expect(!FileManager.default.fileExists(
                atPath: cache.appendingPathComponent("\(name).mlmodelc").path))
        }
        // An empty vocab.json passes their check and then throws inside the
        // tokenizer, which is the same failure one step later.
        #expect(!FileManager.default.fileExists(
            atPath: cache.appendingPathComponent(ModelNames.Canary.vocabularyFile).path))
    }

    @Test("eviction never touches a complete model, whoever downloaded it")
    func evictionSparesCompleteFiles() throws {
        let cache = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }

        // Another application's fp16 set, complete, sharing the repository
        // directory. This is why eviction is per entry rather than the one-line
        // `force: true` FluidAudio offers, which removes the whole directory.
        for name in FluidModelFiles.canaryBundles(precision: .fp16) {
            try FileManager.default.createDirectory(
                at: cache.appendingPathComponent("\(name).mlmodelc"),
                withIntermediateDirectories: true)
            try fill(cache, name)
        }
        try writeVocabulary(cache)
        // Our own half-finished int4 encoder alongside it.
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("EncoderInt4.mlmodelc"),
            withIntermediateDirectories: true)

        FluidModelFiles.evictIncompleteCanary(at: cache, precision: .int4)

        #expect(!FileManager.default.fileExists(
            atPath: cache.appendingPathComponent("EncoderInt4.mlmodelc").path))
        #expect(FluidModelFiles.canary(precision: .fp16)(cache) == true)
        #expect(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent(ModelNames.Canary.vocabularyFile).path))
    }

    @Test("eviction on a cache that does not exist is a no-op")
    func evictionToleratesAnAbsentCache() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The first install on a clean machine.
        FluidModelFiles.evictIncompleteCanary(
            at: root.appendingPathComponent("never-created"), precision: .int4)
    }

    @Test("the entries a row adopts are its own, and never the marker")
    func adoptedEntries() {
        let entries = FluidModelFiles.canaryEntries(precision: .int4)
        #expect(entries.contains("EncoderInt4.mlmodelc"))
        #expect(entries.contains("DecoderInt4.mlmodelc"))
        #expect(entries.contains(ModelNames.Canary.vocabularyFile))
        // An fp16 neighbor in the shared cache must not be dragged into an int4
        // row, where `models delete` would later remove it.
        #expect(!entries.contains("Encoder.mlmodelc"))
        #expect(!entries.contains("Decoder.mlmodelc"))
        #expect(!entries.contains(ModelStore.partialMarkerName))
    }

    @Test("only int4 is offered, and the other two say why")
    func flavorParsing() throws {
        #expect(try CanaryFlavor.parse(model: "canary-1b-v2", variant: "int4").precision == .int4)
        #expect(try CanaryFlavor.parse(model: "canary-1b-v2", variant: nil).precision == .int4)
        // Not "unknown variant": FluidAudio declares both precisions and the
        // model repo publishes neither, so the answer has to survive being
        // asked again in six months.
        for variant in ["fp16", "int8"] {
            #expect(throws: SpeechError.self) {
                _ = try CanaryFlavor.parse(model: "canary-1b-v2", variant: variant)
            }
        }
        #expect(throws: SpeechError.self) {
            _ = try CanaryFlavor.parse(model: "canary-1b-v2", variant: "int2")
        }
        #expect(throws: SpeechError.self) {
            _ = try CanaryFlavor.parse(model: "canary-1b", variant: "int4")
        }
    }

    @Test("the row declares the macOS floor its weights actually need")
    func osFloor() throws {
        // There is no fp16 build published, so this row has no macOS 14 path at
        // all - which is why the whole binary's deployment target is 15. The
        // floor is a real requirement, not documentation, and this pins the
        // value the applet's Info.plist has to agree with.
        #expect(try CanaryFlavor.parse(model: "canary-1b-v2", variant: "int4").minimumMacOS == "15.0")
        #expect(FluidEngineFactory.capabilities(for: "canary-1b-v2", variant: "int4")?
            .minimumMacOS == "15.0")
    }

    @Test("the advertised languages are the trained ones, not the vocabulary")
    func trainedLanguages() {
        let languages = CanaryEngine.trainedLanguages
        // The model card's 25: the EU's official languages minus Irish, plus
        // Russian and Ukrainian. The vocabulary carries all 183 ISO 639-1 tags
        // and accepts a prompt built from any of them, so deriving this list
        // from the weights would advertise 158 languages that return confident
        // nonsense.
        #expect(languages.count == 25)
        #expect(languages == languages.sorted())
        #expect(Set(languages).count == 25)
        for expected in ["en", "de", "pl", "ru", "uk", "mt", "el"] {
            #expect(languages.contains(expected))
        }
        #expect(!languages.contains("ga"))
        // Parakeet v3's set is a superset - it adds Bosnian, Belarusian and
        // Serbian - so the two rows are not interchangeable in either
        // direction, and neither should be substituted for the other.
        for extra in ["bs", "be", "sr"] {
            #expect(!languages.contains(extra))
        }
        for tag in languages {
            #expect(FluidLanguage.parakeetLanguages.contains(tag), "\(tag) missing from Parakeet")
        }
        #expect(FluidEngineFactory.capabilities(for: "canary-1b-v2", variant: "int4")?
            .languages == languages)
    }
}
