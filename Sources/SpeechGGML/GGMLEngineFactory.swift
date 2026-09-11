// GGMLEngineFactory.swift - the registry entry point for the `ggml` prefix.
//
// Mirrors FluidEngineFactory: synchronous, throws a clear `usage` for an id it
// cannot build, and answers `capabilities(for:)` without instantiating anything
// so `speech engines` can list rows that are not installed.
//
// The one thing it carries that the other factories do not is the segmenter.
// Chunking a long file needs a policy about where to cut, that policy will one
// day be a voice-activity model, and the model that would provide it lives in
// SpeechFluid. Passing it in here - rather than importing it - is what keeps
// this target free of that dependency.

import Foundation
import SpeechCore

/// What a loaded GGUF says about itself: the facts a catalog entry records.
public struct GGMLProbe: Sendable, Equatable {
    /// The GGUF's `general.architecture`, e.g. "parakeet" or "granite".
    public let architecture: String
    /// The GGUF's `stt.variant`, empty when it has none.
    public let variant: String
    /// Language tags exactly as the model spells them; empty means it names
    /// none.
    public let languages: [String]
    public let languageID: Bool
    public let streaming: Bool
    public let wordTimestamps: Bool
    public let segmentTimestamps: Bool
    /// The longest audio one run accepts, nil for no limit.
    public let maxAudioSeconds: Double?

    public init(
        architecture: String, variant: String, languages: [String], languageID: Bool,
        streaming: Bool, wordTimestamps: Bool, segmentTimestamps: Bool, maxAudioSeconds: Double?
    ) {
        self.architecture = architecture
        self.variant = variant
        self.languages = languages
        self.languageID = languageID
        self.streaming = streaming
        self.wordTimestamps = wordTimestamps
        self.segmentTimestamps = segmentTimestamps
        self.maxAudioSeconds = maxAudioSeconds
    }
}

public enum GGMLEngineFactory {
    /// Every family this build implements, in catalog order.
    public static var implementedModels: [String] { GGMLCatalog.rows.map(\.model) }

    /// Every `(model, variant)` this build can construct.
    public static var catalogRows: [(model: String, variant: String?)] { GGMLCatalog.catalogRows }

    /// How long audio is cut up for families with a hard ceiling. Replaceable
    /// so stage 4's voice-activity detector can take over without this file
    /// changing; the default needs no model and no download.
    public static let defaultSegmenter: any AudioSegmenter = EnergySegmenter()

    public static func make(_ spec: EngineSpec) throws -> any TranscriptionEngine {
        try make(spec, segmenter: defaultSegmenter)
    }

    public static func make(
        _ spec: EngineSpec, segmenter: any AudioSegmenter
    ) throws -> any TranscriptionEngine {
        guard let row = GGMLCatalog.row(model: spec.model) else {
            // A catalog entry that exists but could not be used says why,
            // rather than claiming the model is unknown.
            if let problem = GGMLCatalog.problems.first(where: { $0.id == "ggml.\(spec.model)" }) {
                throw SpeechError.usage("the catalog entry is unusable: \(problem.message)")
            }
            throw SpeechError.usage(
                "unknown ggml model '\(spec.model)'"
                + " (have: \(implementedModels.joined(separator: ", ")))")
        }
        let quant = try GGMLCatalog.quant(for: row, variant: spec.variant)
        return GGMLEngine(spec: spec, row: row, quant: quant, segmenter: segmenter)
    }

    /// Where a row's weights come from: the repository and the single file
    /// inside it. Exposed so the catalog can be checked against the engine that
    /// will actually do the download, rather than carrying a second copy of the
    /// naming rule that nothing compares.
    public static func weights(for model: String, variant: String?) -> (repo: String, file: String)? {
        guard let row = GGMLCatalog.row(model: model),
              let quant = try? GGMLCatalog.quant(for: row, variant: variant),
              let file = row.fileName(quant: quant)
        else { return nil }
        return (row.repo, file)
    }

    /// The `ggml` catalog entries this engine cannot use: the entry's
    /// `<engine>.<model>` key and why.
    public static var catalogProblems: [(key: String, message: String)] {
        GGMLCatalog.problems.map { (key: $0.id, message: $0.message) }
    }

    /// Loads an installed `ggml` row and reports what the weights say about
    /// themselves, then releases them. Throws the library's own reason when it
    /// cannot load the file - an architecture transcribe.cpp does not know
    /// fails here, which is how `speech models add` tells a model it can run
    /// from one it cannot.
    public static func probe(_ spec: EngineSpec) async throws -> GGMLProbe {
        guard let engine = try make(spec) as? GGMLEngine else {
            throw SpeechError.runtime("'\(spec.catalogID)' is not a ggml row")
        }
        return try await engine.probe()
    }

    /// Capabilities without building the engine, for `speech engines`.
    public static func capabilities(for model: String, variant: String?) -> EngineCapabilities? {
        guard let spec = try? EngineSpec.parse(
            catalogID: variant.map { "ggml.\(model)@\($0)" } ?? "ggml.\(model)",
            modelsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        else { return nil }
        return (try? make(spec))?.capabilities
    }
}
