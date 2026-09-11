// MLXEngineFactory.swift - the registry entry point for the `mlx` prefix.
//
// Mirrors GGMLEngineFactory: synchronous, throws a clear `usage` for an id it
// cannot build, and answers `capabilities(for:)` without instantiating
// anything, so `speech engines` can list rows whose weights are not installed
// and whose helper is not built.
//
// `availability()` is the one thing the other factories have no equivalent of,
// and it is what makes this engine optional rather than merely absent. A build
// with no `speech-mlx` beside it still registers the prefix and still lists the
// rows; what it reports is `unavailable` with a reason that says where it
// looked and how to build the thing it did not find. The alternative - not
// registering the prefix - produces "no engine 'mlx' in this build", which is
// true of a build that is missing a file rather than of one that was compiled
// differently, and sends the reader to the wrong problem.

import Foundation
import SpeechCore

public enum MLXEngineFactory {
    /// Every model this build knows, in catalog order.
    public static var implementedModels: [String] { MLXCatalog.models }

    /// Every `(model, variant)` this build can construct.
    public static var catalogRows: [(model: String, variant: String?)] {
        MLXCatalog.rows.map { ($0.model, $0.variant) }
    }

    /// Where a long recording is cut when a row has a ceiling. The same default
    /// as `ggml`, and replaceable for the same reason.
    public static let defaultSegmenter: any AudioSegmenter = EnergySegmenter()

    /// Whether this build can run `mlx` rows at all, and why not when it
    /// cannot. Checked without starting anything: this is the answer
    /// `speech engines` needs for every row, and spawning a helper per row to
    /// find out would be a Metal initialization per row.
    public static func availability(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<URL, MLXHelperError> {
        MLXHelperProcess.locate(environment: environment)
    }

    public static func make(_ spec: EngineSpec) throws -> any TranscriptionEngine {
        try make(spec, segmenter: defaultSegmenter)
    }

    public static func make(
        _ spec: EngineSpec, segmenter: any AudioSegmenter
    ) throws -> any TranscriptionEngine {
        guard let row = MLXCatalog.row(model: spec.model, variant: spec.variant) else {
            if let entry = Catalog.model(engine: "mlx", model: spec.model),
               case .failure(let problem) = MLXCatalog.make(entry) {
                throw SpeechError.usage("the catalog entry is unusable: \(problem.message)")
            }
            guard MLXCatalog.models.contains(spec.model) else {
                throw SpeechError.usage(
                    "unknown mlx model '\(spec.model)'"
                    + " (have: \(implementedModels.joined(separator: ", ")))")
            }
            let variants = MLXCatalog.variants(of: spec.model)
            throw SpeechError.usage(
                "mlx model '\(spec.model)' has no variant '\(spec.variant ?? "")'"
                + (variants.isEmpty
                    ? " (it has none; drop the '@')"
                    : " (have: \(variants.joined(separator: ", ")))"))
        }
        return MLXEngine(spec: spec, row: row, segmenter: segmenter)
    }

    /// Where a row's files come from. Exposed so the shared catalog can be
    /// checked against the engine that will do the download, rather than
    /// carrying a second copy of the naming rule that nothing compares.
    public static func assets(for model: String, variant: String?) -> (repo: String, files: [String])? {
        guard let row = MLXCatalog.row(model: model, variant: variant) else { return nil }
        return (row.repo, row.assets.map(\.file))
    }

    /// The `mlx` catalog entries this engine cannot use: the entry's
    /// `<engine>.<model>` key and why.
    public static var catalogProblems: [(key: String, message: String)] {
        MLXCatalog.problems.map { (key: $0.key, message: $0.message) }
    }

    /// The download size a row declares, for the shared catalog.
    public static func sizeBytes(for model: String, variant: String?) -> Int64? {
        MLXCatalog.row(model: model, variant: variant)?.sizeBytes
    }

    /// Capabilities without building the engine, for `speech engines`.
    public static func capabilities(for model: String, variant: String?) -> EngineCapabilities? {
        guard let spec = try? EngineSpec.parse(
            catalogID: variant.map { "mlx.\(model)@\($0)" } ?? "mlx.\(model)",
            modelsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        else { return nil }
        return (try? make(spec))?.capabilities
    }
}
