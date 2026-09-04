// NemotronTests.swift - the three Nemotron assumptions a dependency bump can
// break without breaking the build.
//
// Where the row's files land, which files make it complete, and how a language
// tag becomes a prompt. All three are read out of FluidAudio at runtime rather
// than restated here, so each test drives their code and fails when their
// answer changes.

import FluidAudio
import Foundation
import Testing
@testable import SpeechFluid
@testable import SpeechCore

@Suite("Nemotron multilingual paths, completeness and prompts")
struct NemotronTests {
    private func makeRow() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-nemotron-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    /// A compiled CoreML bundle is a directory holding, among other things,
    /// `coremldata.bin`. The manifest matters: the check requires it precisely
    /// so that a directory the downloader created but has not filled does not
    /// read as a finished bundle.
    private func makeBundle(_ directory: URL, _ name: String) throws {
        let bundle = directory.appendingPathComponent("\(name).mlmodelc")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: bundle.appendingPathComponent("coremldata.bin"))
    }

    // MARK: - Paths

    @Test("the variant directory is inside the row, three components down")
    func variantIsInsideTheRow() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let variant = FluidPaths.nemotronVariant(in: row, chunkMs: 1120)
        // Containment is the property that matters: unlike AsrModels, this
        // family appends to what it is given, so the files stay under the row
        // this program owns and can delete.
        #expect(variant.path.hasPrefix(row.path + "/"))
        #expect(variant.lastPathComponent == "1120ms")
        // Both derived components, pinned against the FluidAudio values the
        // comment says they are read from. Containment and depth alone would
        // still hold if either were hardcoded to the wrong string, which is
        // exactly the mistake a pin bump makes.
        #expect(variant.path.hasSuffix(
            "/\(Repo.nemotronMultilingual.folderName)"
            + "/\(StreamingNemotronMultilingualAsrManager.languageDirectory(for: FluidPaths.nemotronLanguageCode))"
            + "/1120ms"))
        // Exactly three components below the row: <repo>/<language>/<chunk>ms.
        // A fourth would mean FluidAudio grew a level this code does not know
        // about, and the completeness check would be looking one directory up.
        #expect(variant.pathComponents.count == row.pathComponents.count + 3)
    }

    @Test("every chunk tier is its own directory")
    func tiersDoNotCollide() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let directories = NemotronFlavor.chunkTiers.map {
            FluidPaths.nemotronVariant(in: row, chunkMs: $0).path
        }
        #expect(Set(directories).count == NemotronFlavor.chunkTiers.count)
    }

    @Test("auto routes to the full-vocabulary ship, and a language would not")
    func autoAvoidsTheVocabPrunedShip() {
        // The reason `nemotronLanguageCode` is a constant rather than the
        // caller's language. FluidAudio sends Latin-script hints to a
        // vocab-pruned model, so one catalog id would mean two different sets
        // of weights depending on the language of the first download.
        //
        // Driving their function rather than restating its output: if the
        // routing is ever removed this test stops being meaningful, but if it
        // changes shape - a third ship, a different bucket for "auto" - the
        // first assertion fails.
        #expect(StreamingNemotronMultilingualAsrManager.languageDirectory(
            for: FluidPaths.nemotronLanguageCode) == "multilingual")
        #expect(StreamingNemotronMultilingualAsrManager.languageDirectory(for: "de-DE") == "latin")
        #expect(StreamingNemotronMultilingualAsrManager.languageDirectory(for: "en-US") == "latin")
        #expect(StreamingNemotronMultilingualAsrManager.languageDirectory(for: "pl-PL")
            == "multilingual")
    }

    // MARK: - Completeness

    /// The lean "B1" layout: no preprocessor, no separate decoder or joint, a
    /// fused `decoder_joint` instead. This is a complete, loadable download.
    private func populateLean(_ variant: URL) throws {
        try touch(variant.appendingPathComponent("metadata.json"))
        try touch(variant.appendingPathComponent("tokenizer.json"))
        try makeBundle(variant, "encoder")
        try makeBundle(variant, "decoder_joint")
    }

    @Test("a lean ship with no separate decoder or joint counts as installed")
    func leanShipIsComplete() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let check = FluidModelFiles.nemotronMultilingual(chunkMs: 2240)
        #expect(check(row) == false)

        try populateLean(FluidPaths.nemotronVariant(in: row, chunkMs: 2240))
        // The regression this test exists for: requiring preprocessor.mlmodelc,
        // decoder.mlmodelc and joint.mlmodelc - the file list in the plan's
        // appendix - reports `partial` here, and `finishInstall` then refuses
        // to clear the marker, which is an install that can never succeed.
        #expect(check(row) == true)
    }

    @Test("the classic layout, with a separate decoder and joint, also counts")
    func classicShipIsComplete() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let variant = FluidPaths.nemotronVariant(in: row, chunkMs: 1120)
        try touch(variant.appendingPathComponent("metadata.json"))
        try touch(variant.appendingPathComponent("tokenizer.json"))
        try makeBundle(variant, "encoder")
        try makeBundle(variant, "decoder")
        try makeBundle(variant, "joint")

        #expect(FluidModelFiles.nemotronMultilingual(chunkMs: 1120)(row) == true)
    }

    @Test("a decoder without a joint is not a decode path")
    func halfADecodePathIsIncomplete() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let variant = FluidPaths.nemotronVariant(in: row, chunkMs: 2240)
        try touch(variant.appendingPathComponent("metadata.json"))
        try touch(variant.appendingPathComponent("tokenizer.json"))
        try makeBundle(variant, "encoder")
        try makeBundle(variant, "decoder")

        // `process(samples:)` throws `notInitialized` for exactly this layout,
        // so reporting it installed would turn a resumable download into a
        // runtime failure.
        #expect(FluidModelFiles.nemotronMultilingual(chunkMs: 2240)(row) == false)
    }

    @Test("each required file is required")
    func everyRequirementBites() throws {
        for missing in ["metadata.json", "tokenizer.json", "encoder.mlmodelc", "decoder_joint.mlmodelc"] {
            let row = try makeRow()
            defer { try? FileManager.default.removeItem(at: row) }

            let variant = FluidPaths.nemotronVariant(in: row, chunkMs: 560)
            try populateLean(variant)
            try FileManager.default.removeItem(at: variant.appendingPathComponent(missing))
            #expect(
                FluidModelFiles.nemotronMultilingual(chunkMs: 560)(row) == false,
                "removing \(missing) should leave the row incomplete")
        }
    }

    @Test("a bundle directory the downloader has not filled is not a bundle")
    func halfWrittenBundleIsIncomplete() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let variant = FluidPaths.nemotronVariant(in: row, chunkMs: 2240)
        try populateLean(variant)
        // What an interrupted download leaves: `ensure` creates the bundle
        // directory before fetching the files inside it, and returns
        // `.alreadyPresent` on a later run because the directory exists. Testing
        // the directory alone therefore reports installed, `finishInstall`
        // clears the partial marker, and the failure resurfaces as a load error
        // instead of exit 3 and a download instruction.
        try FileManager.default.removeItem(
            at: variant.appendingPathComponent("encoder.mlmodelc/coremldata.bin"))
        #expect(FluidModelFiles.nemotronMultilingual(chunkMs: 2240)(row) == false)
    }

    @Test("an uncompiled mlpackage satisfies the check, as it does the loader")
    func mlpackageCountsToo() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        let variant = FluidPaths.nemotronVariant(in: row, chunkMs: 1120)
        try touch(variant.appendingPathComponent("metadata.json"))
        try touch(variant.appendingPathComponent("tokenizer.json"))
        // `locateModelBundle` compiles an .mlpackage to a sibling .mlmodelc on
        // first load, so a package-only download is usable and must not be
        // called partial.
        try FileManager.default.createDirectory(
            at: variant.appendingPathComponent("encoder.mlpackage"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: variant.appendingPathComponent("decoder_joint.mlpackage"),
            withIntermediateDirectories: true)

        #expect(FluidModelFiles.nemotronMultilingual(chunkMs: 1120)(row) == true)
    }

    @Test("files loose in the row do not count as an install")
    func rowLevelFilesDoNotCount() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        // The Parakeet bug in a different shape: a check applied at the wrong
        // level passes against files the loader will never open.
        try populateLean(row)
        #expect(FluidModelFiles.nemotronMultilingual(chunkMs: 2240)(row) == false)
    }

    @Test("one tier's download does not make another tier look installed")
    func tiersDoNotSatisfyEachOther() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }

        try populateLean(FluidPaths.nemotronVariant(in: row, chunkMs: 1120))
        #expect(FluidModelFiles.nemotronMultilingual(chunkMs: 1120)(row) == true)
        #expect(FluidModelFiles.nemotronMultilingual(chunkMs: 2240)(row) == false)
    }

    // MARK: - Prompts

    /// A metadata.json in the shape `NemotronMultilingualStreamingConfig`
    /// parses, with a prompt dictionary whose ids are all distinct from the
    /// default. That last part is what makes the mirror test sharp: if any
    /// language shared the default id, "resolved to that language" and "fell
    /// back to auto" would be indistinguishable in the assertion.
    private func writeMetadata(_ directory: URL) throws -> NemotronMultilingualStreamingConfig {
        let url = directory.appendingPathComponent("metadata.json")
        let json: [String: Any] = [
            "default_prompt_id": 101,
            "prompt_dictionary": [
                "auto": 101, "en": 1, "en-US": 2, "pl-PL": 3, "de-DE": 4, "zh-CN": 5,
            ],
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return try NemotronMultilingualStreamingConfig(from: url)
    }

    @Test("our prompt key agrees with FluidAudio's prompt id, tag for tag")
    func promptKeyMirrorsTheResolver() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }
        let config = try writeMetadata(row)

        // Exact hits, each normalization step, and two misses. The point is
        // that FluidAudio's answer - an id - and ours - which key produced it -
        // never disagree, so a normalization rule added or dropped upstream
        // fails here instead of transcribing Polish with an English prompt.
        for tag in ["en-US", "en_us", "EN-us", "en-GB", "pl-PL", "pl_pl", "de-DE", "zh-CN",
                    "en", "fr-FR", "xx", ""] {
            let theirs = config.promptId(forLanguage: tag.isEmpty ? nil : tag)
            let ours = NemotronEngine.promptKey(
                for: tag.isEmpty ? nil : tag, in: config.promptDictionary)
            if let ours {
                #expect(
                    config.promptDictionary[ours] == theirs,
                    "\(tag): we chose key '\(ours)' but FluidAudio resolved to id \(theirs)")
            } else {
                #expect(
                    theirs == config.defaultPromptId,
                    "\(tag): we found no key but FluidAudio resolved to id \(theirs)")
            }
        }
    }

    @Test("a region falls back to the bare language, and an unknown tag to nothing")
    func promptKeyFallbacks() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }
        let config = try writeMetadata(row)
        let dictionary = config.promptDictionary

        #expect(NemotronEngine.promptKey(for: "pl-PL", in: dictionary) == "pl-PL")
        #expect(NemotronEngine.promptKey(for: "pl_pl", in: dictionary) == "pl-PL")
        // "en-GB" is not a key; the bare "en" is, so the hint survives.
        #expect(NemotronEngine.promptKey(for: "en-GB", in: dictionary) == "en")
        // Nothing to fall back to. `prepare` reports this as "auto", which is
        // the only signal a caller gets that the hint was dropped.
        #expect(NemotronEngine.promptKey(for: "fr-FR", in: dictionary) == nil)
        #expect(NemotronEngine.promptKey(for: nil, in: dictionary) == nil)
        #expect(NemotronEngine.promptKey(for: "", in: dictionary) == nil)
    }

    // MARK: - Flavors

    @Test("the chunk tier is part of the row identity, and a typo is a usage error")
    func flavorParsing() throws {
        for tier in NemotronFlavor.chunkTiers {
            #expect(try NemotronFlavor.parse(
                model: "nemotron-multilingual", variant: String(tier)).chunkMs == tier)
        }
        // A bare id means FluidAudio's recommended tier rather than being
        // rejected, the same rule Parakeet's bare id follows.
        #expect(try NemotronFlavor.parse(model: "nemotron-multilingual", variant: nil).chunkMs
            == NemotronFlavor.defaultChunkMs)
        #expect(NemotronFlavor.chunkTiers.contains(NemotronFlavor.defaultChunkMs))

        // 4480 is a real FluidAudio tier that this build deliberately does not
        // offer, so it has to be rejected rather than silently downloaded.
        #expect(throws: SpeechError.self) {
            _ = try NemotronFlavor.parse(model: "nemotron-multilingual", variant: "4480")
        }
        #expect(throws: SpeechError.self) {
            _ = try NemotronFlavor.parse(model: "nemotron-multilingual", variant: "1120ms")
        }
        #expect(throws: SpeechError.self) {
            _ = try NemotronFlavor.parse(model: "nemotron-english", variant: "1120")
        }
    }

    @Test("every catalog row the factory advertises can actually be built")
    func catalogRowsAreBuildable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        for row in FluidEngineFactory.catalogRows {
            let id = row.variant.map { "fluid.\(row.model)@\($0)" } ?? "fluid.\(row.model)"
            let spec = try EngineSpec.parse(catalogID: id, modelsDirectory: root)
            // Constructing an engine touches no files and no network; it is the
            // listing in `speech engines` that must not promise a row `make`
            // would reject.
            #expect(throws: Never.self) { _ = try FluidEngineFactory.make(spec) }
        }
    }
}
