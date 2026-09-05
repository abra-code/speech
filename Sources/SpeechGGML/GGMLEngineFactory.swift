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
              let quant = try? GGMLCatalog.quant(for: row, variant: variant)
        else { return nil }
        return (row.repo, row.fileName(quant: quant))
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
