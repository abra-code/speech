// GGMLCatalog.swift - the `ggml` models the catalog carries, where their
// weights come from, and what a complete download looks like on disk.
//
// A `ggml` row is one file. That makes this far simpler than the FluidAudio
// store, which had to reverse-engineer three different directory conventions
// out of one library: here the row directory holds `model.gguf` and nothing
// else, and the only question worth asking is whether that file is a GGUF and
// whether the transfer finished.
//
// The models are data - the `"engine": "ggml"` entries of the catalog - and
// each variant names its own repository file. There used to be a naming rule
// here instead (`handy-computer/<stem>-gguf`, `<stem>-<QUANT>.gguf`); it held
// for every model the rule was written against and for no other, and a model
// from anywhere else is exactly what the catalog now has to accept.

import Foundation
import SpeechCore

/// One variant of a `ggml` model: the quantization an id names, and the file.
struct GGMLVariant: Sendable, Equatable {
    /// Lower-case, as it appears in an id.
    let quant: String
    /// The file inside the model's repository, in the repository's own casing.
    let file: String
}

/// One model in the `ggml` catalog.
struct GGMLRow: Sendable {
    /// The `<model>` part of the catalog id, always lower-case.
    let model: String
    /// The Hugging Face repository the files come from.
    let repo: String
    /// Offered quantizations, best first. The first is the default.
    let variants: [GGMLVariant]
    /// BCP-47 tags as the model spells them, from the catalog entry.
    ///
    /// Advisory, exactly like the Apple rows' list: it is what the catalog
    /// shows before anything is downloaded, and it can lag the weights. The
    /// gate is the loaded model's own list, checked in `prepare`, because that
    /// one cannot be stale.
    let languages: [String]
    /// The model can decide the language itself. When false a hint is required
    /// and `prepare` refuses without one, rather than letting the library pick
    /// a default language and quietly transcribe Polish as English.
    let languageID: Bool
    /// The model has a streaming decoder, so `speech stream` can drive it.
    ///
    /// Advisory, like `languages`: the gate is the loaded model's own
    /// `supportsStreaming`, checked in `makeLiveSession`. Streaming support is
    /// an architecture property, so one measured variant speaks for the model -
    /// and a variant that turns out not to stream refuses in `makeLiveSession`
    /// rather than going silent.
    let streaming: Bool
    /// Word-level timings are available. Whisper is segment-only; Qwen3-ASR and
    /// Moonshine have no timestamps at all.
    let wordTimestamps: Bool
    /// Segment-level timings are available.
    let segmentTimestamps: Bool

    /// Offered quantizations, in catalog order.
    var quants: [String] { variants.map(\.quant) }

    /// The default quantization when an id carries no `@variant`.
    var defaultQuant: String { variants[0].quant }

    /// The repository file for a quantization this model offers.
    func fileName(quant: String) -> String? {
        variants.first { $0.quant == quant }?.file
    }

    /// A catalog entry as a `ggml` row, or why it cannot be one.
    static func make(_ entry: CatalogModel) -> Result<GGMLRow, GGMLCatalog.Problem> {
        func problem(_ message: String) -> Result<GGMLRow, GGMLCatalog.Problem> {
            .failure(GGMLCatalog.Problem(id: entry.key, message: "\(entry.key): \(message)"))
        }
        guard entry.variants?.isEmpty == false else {
            return problem("a ggml model needs 'variants', one per quantization")
        }
        var variants: [GGMLVariant] = []
        for variant in entry.declaredVariants {
            guard let quant = variant.variant else { return problem("a variant has no name") }
            guard (variant.source ?? entry.source) == entry.source else {
                return problem("variant '\(quant)' names its own 'source';"
                    + " a ggml model's files all come from the model's repository")
            }
            guard let file = variant.file ?? entry.file else {
                return problem("variant '\(quant)' has no 'file'")
            }
            guard file.lowercased().hasSuffix(".gguf") else {
                return problem("variant '\(quant)': '\(file)' is not a .gguf file")
            }
            // A repository path, which may have directories in it, but never
            // one that climbs out: the name is sent to the Hugging Face API and
            // compared against its listing, and nothing good comes of "..".
            let parts = file.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else {
                return problem("variant '\(quant)': '\(file)' is not a plain repository path")
            }
            variants.append(GGMLVariant(quant: quant, file: file))
        }
        guard let repo = entry.source, !repo.isEmpty else {
            return problem("a ggml model needs 'source', the Hugging Face repository")
        }
        return .success(GGMLRow(
            model: entry.model,
            repo: repo,
            variants: variants,
            languages: entry.languages ?? [],
            languageID: entry.languageID ?? false,
            streaming: entry.streaming ?? false,
            wordTimestamps: entry.wordTimestamps ?? false,
            segmentTimestamps: entry.segmentTimestamps ?? false))
    }
}

enum GGMLCatalog {
    /// A catalog entry the ggml engine cannot use, and why.
    struct Problem: Error, Sendable, Equatable {
        let id: String
        let message: String
    }

    /// The weights file inside a row directory. Renamed from the repository's
    /// own name on the way in, so nothing downstream has to know the file name
    /// and a row is self-describing.
    static let weightsName = "model.gguf"

    /// Every usable `ggml` model in the catalog, in catalog order.
    static var rows: [GGMLRow] {
        Catalog.models(engine: "ggml").compactMap { try? GGMLRow.make($0).get() }
    }

    /// The `ggml` entries that could not be used, for `speech catalog` to
    /// report. An entry with no file would otherwise simply be missing from
    /// every listing, which is the silent failure a hand-edited file invites.
    static var problems: [Problem] {
        Catalog.models(engine: "ggml").compactMap {
            guard case .failure(let problem) = GGMLRow.make($0) else { return nil }
            return problem
        }
    }

    static func row(model: String) -> GGMLRow? {
        guard let entry = Catalog.model(engine: "ggml", model: model) else { return nil }
        return try? GGMLRow.make(entry).get()
    }

    /// Every `(model, variant)` this build can construct, in catalog order.
    /// Mirrors `FluidEngineFactory.catalogRows` so `speech engines` can list
    /// both without knowing which engine it is looking at.
    static var catalogRows: [(model: String, variant: String?)] {
        rows.flatMap { row in row.quants.map { (model: row.model, variant: Optional($0)) } }
    }

    /// Resolve a catalog id's `@variant` into a quantization this row offers.
    /// A bare id takes the row's first quantization rather than being rejected,
    /// matching how `fluid.parakeet-v3` means `@int8`.
    static func quant(for row: GGMLRow, variant: String?) throws -> String {
        guard let variant else { return row.defaultQuant }
        let normalized = variant.lowercased()
        guard row.quants.contains(normalized) else {
            throw SpeechError.usage(
                "unknown variant '@\(variant)' for \(row.model)"
                + " (want @\(row.quants.joined(separator: " or @")))")
        }
        return normalized
    }

    /// Whether a row directory holds usable weights.
    ///
    /// Checks the GGUF magic and not merely that a file is there. ggml will map
    /// a wrong or truncated file and fail several frames deep with a message
    /// about tensor shapes; four bytes here turns that into "not installed".
    /// Length is not re-checked because the downloader already refused to move
    /// a short file into place, and re-reading a 2 GB file on every `models
    /// list` would make the command unusable.
    static func isComplete(_ directory: URL) -> Bool {
        let weights = directory.appendingPathComponent(weightsName, isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: weights) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4) else { return false }
        return magic == Data("GGUF".utf8)
    }
}
