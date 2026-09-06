// UnifiedStreamingTests.swift - the streaming half of Parakeet Unified: which
// variant names which tier, and which files on disk make one of them complete.
//
// The interesting property here is one the offline row does not have. Its two
// rows differ in the encoder's *precision*, so the file names differ by a
// suffix nobody would confuse. These four rows differ in the encoder's baked-in
// attention context, share every other file in the repository, and land in
// directories that differ only by a number. If the completeness check named the
// encoder generically, a `@stream-320` download would report `@stream-2080` as
// installed - and `prepare` would then fail to open a bundle the store had just
// called complete, which is exactly the failure mode the store's contract with
// the engine exists to prevent.

import FluidAudio
import Foundation
import Testing
@testable import SpeechFluid
@testable import SpeechCore

@Suite("Parakeet Unified streaming rows")
struct UnifiedStreamingTests {
    private func makeRow() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-unified-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBundle(_ directory: URL, _ name: String) throws {
        let bundle = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 16).write(
            to: bundle.appendingPathComponent("coremldata.bin"))
    }

    /// The loader's own `requiredFiles`, spelled out here so a change to the
    /// check has to be a deliberate change to this list too.
    private func required(_ tier: UnifiedStreamTier) -> [String] {
        let names = ModelNames.ParakeetUnified.self
        return [
            names.streamingEncoderFile(precision: .int8, contextSuffix: tier.contextSuffix),
            names.decoderFile,
            names.jointDecisionFile,
            names.vocab,
        ]
    }

    private func populate(_ row: URL, tier: UnifiedStreamTier) throws {
        let repo = FluidPaths.unifiedRepo(in: row)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for name in required(tier) {
            if name.hasSuffix(".mlmodelc") {
                try makeBundle(repo, name)
            } else {
                try Data(repeating: 0x7B, count: 32).write(to: repo.appendingPathComponent(name))
            }
        }
    }

    private func tier(_ latencyMs: Int) throws -> UnifiedStreamTier {
        try #require(UnifiedStreamTier.all.first { $0.latencyMs == latencyMs })
    }

    // MARK: - Tiers

    @Test("a tier's latency is chunk plus look-ahead, and names its own file")
    func tiersDeriveTheirNames() throws {
        // The four published exports, with the numbers taken from the file names
        // in the repository rather than from the library's default config.
        let expected = [
            (suffix: "70_13_13", latencyMs: 2080),
            (suffix: "70_7_7", latencyMs: 1120),
            (suffix: "70_7_1", latencyMs: 640),
            (suffix: "70_2_2", latencyMs: 320),
        ]
        #expect(UnifiedStreamTier.all.count == expected.count)
        for (tier, want) in zip(UnifiedStreamTier.all, expected) {
            #expect(tier.contextSuffix == want.suffix)
            #expect(tier.latencyMs == want.latencyMs)
            #expect(tier.variant == "stream-\(want.latencyMs)")
            // The encoder bundle the manager will open. This is the whole
            // reason the tier is part of the row identity.
            #expect(
                ModelNames.ParakeetUnified.streamingEncoderFile(
                    precision: .int8, contextSuffix: tier.contextSuffix)
                    == "parakeet_unified_encoder_streaming_\(want.suffix)_int8.mlmodelc")
        }
    }

    @Test("no two tiers share a latency, a suffix or a variant")
    func tiersAreDistinct() {
        // The variant is a path component in the model store, so two tiers
        // agreeing on one would have them overwrite each other's download.
        #expect(Set(UnifiedStreamTier.all.map(\.variant)).count == UnifiedStreamTier.all.count)
        #expect(Set(UnifiedStreamTier.all.map(\.contextSuffix)).count == UnifiedStreamTier.all.count)
    }

    @Test("every tier round-trips through its variant, and nothing else does")
    func variantsResolve() throws {
        for tier in UnifiedStreamTier.all {
            #expect(UnifiedStreamTier.tier(forVariant: tier.variant) == tier)
        }
        // A tier that exists in the library but is not published as a bundle,
        // a spelling that would parse as a number, and the offline variants.
        for rejected in [
            "stream-641", "stream-0640", "stream-640ms", "stream-", "stream",
            "int8", "fp16", "",
        ] {
            #expect(
                UnifiedStreamTier.tier(forVariant: rejected) == nil,
                "'\(rejected)' should not name a tier")
        }
    }

    @Test("the variant grammar routes both halves of the family")
    func flavorParsingRoutes() throws {
        #expect(try UnifiedFlavor.parse(model: "parakeet-unified", variant: nil) == .offline(.int8))
        #expect(
            try UnifiedFlavor.parse(model: "parakeet-unified", variant: "fp16") == .offline(.fp16))
        #expect(
            try UnifiedFlavor.parse(model: "parakeet-unified", variant: "stream-1120")
                == .streaming(try tier(1120)))
        // The streaming rows are int8 whatever else they are; there is no fp16
        // streaming row to download.
        #expect(
            try UnifiedFlavor.parse(model: "parakeet-unified", variant: "stream-320").precision
                == .int8)
        #expect(throws: SpeechError.self) {
            _ = try UnifiedFlavor.parse(model: "parakeet-unified", variant: "stream-641")
        }
    }

    // MARK: - Completeness

    @Test("a populated row is complete")
    func populatedRowIsComplete() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }
        let tier = try tier(2080)

        try populate(row, tier: tier)
        #expect(FluidModelFiles.unifiedStreaming(tier: tier)(row) == true)
    }

    @Test("each required file is required")
    func everyRequirementBites() throws {
        let tier = try tier(1120)
        for missing in required(tier) {
            let row = try makeRow()
            defer { try? FileManager.default.removeItem(at: row) }

            try populate(row, tier: tier)
            try FileManager.default.removeItem(
                at: FluidPaths.unifiedRepo(in: row).appendingPathComponent(missing))
            #expect(
                FluidModelFiles.unifiedStreaming(tier: tier)(row) == false,
                "removing \(missing) should leave the row incomplete")
        }
    }

    @Test("one tier's download does not satisfy another tier's row")
    func tiersDoNotSatisfyEachOther() throws {
        // The four differ by a single file inside a repository directory they
        // all spell the same way, so this is the only thing keeping the rows
        // apart on disk.
        var rows: [(tier: UnifiedStreamTier, row: URL)] = []
        defer { for entry in rows { try? FileManager.default.removeItem(at: entry.row) } }
        for tier in UnifiedStreamTier.all {
            let row = try makeRow()
            try populate(row, tier: tier)
            rows.append((tier, row))
        }
        for installed in rows {
            for candidate in rows {
                let complete = FluidModelFiles.unifiedStreaming(tier: candidate.tier)(installed.row)
                #expect(
                    complete == (candidate.tier == installed.tier),
                    "\(candidate.tier.variant) against a \(installed.tier.variant) download")
            }
        }
    }

    @Test("an offline download does not satisfy a streaming row, or the reverse")
    func exportsDoNotSatisfyEachOther() throws {
        let streamingRow = try makeRow()
        let offlineRow = try makeRow()
        defer {
            try? FileManager.default.removeItem(at: streamingRow)
            try? FileManager.default.removeItem(at: offlineRow)
        }
        let tier = try tier(2080)

        try populate(streamingRow, tier: tier)
        // What `fluid.parakeet-unified@int8` puts on disk: the same repository
        // folder, the same decoder, joint and vocabulary, and the full-attention
        // encoder instead of the chunked one.
        let repo = FluidPaths.unifiedRepo(in: offlineRow)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let names = ModelNames.ParakeetUnified.self
        for name in [
            names.offlineEncoderFile(precision: .int8), names.decoderFile, names.jointDecisionFile,
        ] {
            try makeBundle(repo, name)
        }
        try Data(repeating: 0x7B, count: 32).write(to: repo.appendingPathComponent(names.vocab))

        #expect(FluidModelFiles.unifiedStreaming(tier: tier)(offlineRow) == false)
        #expect(FluidModelFiles.unified(precision: .int8)(streamingRow) == false)
    }

    @Test("a bundle directory the downloader has not filled is not a bundle")
    func emptyBundleIsIncomplete() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }
        let tier = try tier(640)

        try populate(row, tier: tier)
        let encoder = FluidPaths.unifiedRepo(in: row).appendingPathComponent(
            ModelNames.ParakeetUnified.streamingEncoderFile(
                precision: .int8, contextSuffix: tier.contextSuffix))
        try FileManager.default.removeItem(at: encoder.appendingPathComponent("coremldata.bin"))
        #expect(FluidModelFiles.unifiedStreaming(tier: tier)(row) == false)
    }

    @Test("a staging file left inside a bundle makes it incomplete")
    func partialStagingFileIsIncomplete() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }
        let tier = try tier(320)

        try populate(row, tier: tier)
        #expect(FluidModelFiles.unifiedStreaming(tier: tier)(row) == true)

        let weights = FluidPaths.unifiedRepo(in: row)
            .appendingPathComponent(
                ModelNames.ParakeetUnified.streamingEncoderFile(
                    precision: .int8, contextSuffix: tier.contextSuffix))
            .appendingPathComponent("weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data().write(to: weights.appendingPathComponent("weight.bin.partial"))
        #expect(FluidModelFiles.unifiedStreaming(tier: tier)(row) == false)
    }

    @Test("files loose in the row do not count as an install")
    func rowLevelFilesDoNotCount() throws {
        let row = try makeRow()
        defer { try? FileManager.default.removeItem(at: row) }
        let tier = try tier(2080)

        // Everything present, one level too high. FluidAudio opens
        // `<row>/<repo folder>`, so a check reading the row directory itself
        // would call this installed and `prepare` would then find nothing.
        for name in required(tier) {
            if name.hasSuffix(".mlmodelc") {
                try makeBundle(row, name)
            } else {
                try Data(repeating: 0x7B, count: 32).write(to: row.appendingPathComponent(name))
            }
        }
        #expect(FluidModelFiles.unifiedStreaming(tier: tier)(row) == false)
    }

    // MARK: - Rows

    @Test("every streaming tier is a catalog row the factory can build")
    func rowsAreBuildable() throws {
        let listed = FluidEngineFactory.catalogRows
            .filter { $0.model == "parakeet-unified" }
            .compactMap(\.variant)
            .filter { $0.hasPrefix(UnifiedStreamTier.prefix) }
        #expect(listed == UnifiedStreamTier.variants)

        for variant in listed {
            let capabilities = try #require(
                FluidEngineFactory.capabilities(for: "parakeet-unified", variant: variant))
            #expect(capabilities.batch == true)
            #expect(capabilities.wordTimestamps == true)
            #expect(capabilities.languages == ["en"])
            // The streaming manager's boosting path is a second model and a
            // retroactive rewrite, and neither has been measured on this row.
            #expect(capabilities.vocabulary == false)
        }
    }

    @Test("each streaming row gets its own directory in the store")
    func rowsDoNotShareADirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        var directories: Set<String> = []
        for variant in UnifiedStreamTier.variants {
            let spec = try EngineSpec.parse(
                catalogID: "fluid.parakeet-unified@\(variant)", modelsDirectory: root)
            directories.insert(spec.directory.path)
        }
        #expect(directories.count == UnifiedStreamTier.variants.count)
    }
}
