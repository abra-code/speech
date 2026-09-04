// FluidEngineFactory.swift - the registry entry point for the `fluid` prefix.
//
// Mirrors AppleEngineFactory: synchronous, throws a clear `usage` or
// `unavailable` for an id it cannot build, and answers `capabilities(for:)`
// without instantiating anything so `speech engines` can list rows the machine
// cannot actually run.

import Foundation
import SpeechCore

public enum FluidEngineFactory {
    /// Every FluidAudio family this build implements. Stage 1's four are
    /// complete; a row is listed here only once `make` can build it, so
    /// `speech engines` never advertises one it would then reject.
    public static let implementedModels = [
        "parakeet-v3", "nemotron-multilingual", "canary-1b-v2", "parakeet-unified",
        "parakeet-ctc-110m",
    ]

    /// Every `(model, variant)` this build can construct, in catalog order.
    ///
    /// Lives here rather than in the `engines` verb so that the list and the
    /// `make` switch below cannot drift: a variant listed and not buildable is
    /// a row a user is invited to download and then refused. The variant sets
    /// are read from the flavor types for the same reason.
    public static let catalogRows: [(model: String, variant: String?)] = buildCatalogRows()

    /// Built in a function rather than as one chained expression: the type
    /// checker gives up on a long `+` chain of tuple literals with optional
    /// members.
    private static func buildCatalogRows() -> [(model: String, variant: String?)] {
        var rows: [(model: String, variant: String?)] = []
        for variant in ["int8", "int4"] {
            rows.append((model: "parakeet-v3", variant: variant))
        }
        for tier in NemotronFlavor.chunkTiers {
            rows.append((model: "nemotron-multilingual", variant: String(tier)))
        }
        rows.append((model: "canary-1b-v2", variant: "int4"))
        for variant in ["int8", "fp16"] {
            rows.append((model: "parakeet-unified", variant: variant))
        }
        // The spotter has no variants and is not a transcriber, but it is a row
        // a user downloads and deletes, so it belongs in the listing.
        rows.append((model: "parakeet-ctc-110m", variant: nil))
        return rows
    }

    public static func make(_ spec: EngineSpec) throws -> any TranscriptionEngine {
        // FluidAudio's CoreML packages are compiled for the Neural Engine and
        // its sources do not build for x86_64 at all, so a Rosetta or Intel
        // process gets a reason rather than a CoreML error from three frames
        // deep.
        #if !arch(arm64)
        throw SpeechError.unavailable("FluidAudio engines need Apple Silicon")
        #else
        switch spec.model {
        case "parakeet-v3":
            return ParakeetEngine(spec: spec, flavor: try ParakeetFlavor.parse(
                model: spec.model, variant: spec.variant))
        case "nemotron-multilingual":
            return NemotronEngine(spec: spec, flavor: try NemotronFlavor.parse(
                model: spec.model, variant: spec.variant))
        case "canary-1b-v2":
            return CanaryEngine(spec: spec, flavor: try CanaryFlavor.parse(
                model: spec.model, variant: spec.variant))
        case "parakeet-unified":
            return UnifiedEngine(spec: spec, flavor: try UnifiedFlavor.parse(
                model: spec.model, variant: spec.variant))
        case "parakeet-ctc-110m":
            guard spec.variant == nil else {
                throw SpeechError.usage("'\(spec.model)' has no variants")
            }
            return SpotterEngine(spec: spec)
        default:
            throw SpeechError.usage(
                "unknown FluidAudio model '\(spec.model)'"
                + " (have: \(implementedModels.joined(separator: ", ")))")
        }
        #endif
    }

    /// Capabilities without building the engine. Returns nil for an id this
    /// build does not know, which the caller reports as unknown rather than
    /// unavailable - a different statement.
    public static func capabilities(for model: String, variant: String?) -> EngineCapabilities? {
        guard let spec = try? EngineSpec.parse(
            catalogID: variant.map { "fluid.\(model)@\($0)" } ?? "fluid.\(model)",
            modelsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        else { return nil }
        return (try? make(spec))?.capabilities
    }
}
