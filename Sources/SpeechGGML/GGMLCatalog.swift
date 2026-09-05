// GGMLCatalog.swift - which GGUF rows exist, where their weights come from, and
// what a complete download looks like on disk.
//
// A `ggml` row is one file. That makes this far simpler than the FluidAudio
// store, which had to reverse-engineer three different directory conventions
// out of one library: here the row directory holds `model.gguf` and nothing
// else, and the only question worth asking is whether that file is a GGUF and
// whether the transfer finished.
//
// The naming rule is mechanical and was checked against every repository this
// catalog names: the repo is `handy-computer/<stem>-gguf` and the file is
// `<stem>-<QUANT>.gguf` with the quantization upper-cased. The catalog id keeps
// the quant lower-cased (`@q8_0`) because ids are path components and the rest
// of the program lower-cases them; the two cases are bridged here and nowhere
// else.

import Foundation
import SpeechCore

/// One family in the `ggml` catalog.
struct GGMLRow: Sendable {
    /// The `<model>` part of the catalog id, always lower-case.
    let model: String
    /// The Hugging Face repository stem, in the repository's own casing -
    /// `Qwen3-ASR-1.7B`, not `qwen3-asr-1.7b`. HF paths are case-sensitive and
    /// the two differ for half these rows.
    let repoStem: String
    /// Offered quantizations, best first. Lower-case, as they appear in an id.
    let quants: [String]
    /// BCP-47 primary subtags, read from the model's own GGUF metadata with
    /// `speech`'s probe rather than copied from a model card.
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
    /// Advisory, like `languages`: it is what the catalog can say about a row
    /// that has not been downloaded. The gate is the loaded model's own
    /// `supportsStreaming`, checked in `makeLiveSession`, because only that one
    /// cannot be stale.
    ///
    /// Measured 2026-09-05 by loading the eight installed GGUFs and printing
    /// `Model.capabilities`. Two of the seven families stream, and which two is
    /// worth knowing before reading the flags below: the fast multilingual row
    /// `parakeet-tdt-0.6b-v3` is **not** one of them, so on this engine live
    /// mode means either an English-only model or the one row that lost to
    /// Apple in all three languages in spike 2.
    ///
    /// **Per family, not per quantization**, and one variant inherits rather
    /// than reports: `nemotron-3.5-asr-streaming-0.6b@q4_k_m` was not among the
    /// eight on disk, so its `live` flag comes from the q8_0 measurement. That
    /// is a reasonable assumption - streaming support is an architecture
    /// property, not a quantization one - but it is an assumption, and it
    /// matters here more than usual because a wrong stream configuration on
    /// this exact family fails by returning an empty transcript while reporting
    /// success. The gate is still the loaded model, so a q4_k_m that turns out
    /// not to stream refuses in `makeLiveSession` rather than going silent.
    let streaming: Bool
    /// Word-level timings are available. Whisper is segment-only; Qwen3-ASR and
    /// Moonshine have no timestamps at all.
    let wordTimestamps: Bool
    /// Segment-level timings are available.
    let segmentTimestamps: Bool

    var repo: String { "handy-computer/\(repoStem)-gguf" }

    /// The repository file for a quantization: `<stem>-<QUANT>.gguf`.
    func fileName(quant: String) -> String {
        "\(repoStem)-\(quant.uppercased()).gguf"
    }

    /// The default quantization when an id carries no `@variant`.
    var defaultQuant: String { quants[0] }
}

enum GGMLCatalog {
    /// The weights file inside a row directory. Renamed from the repository's
    /// own name on the way in, so nothing downstream has to know the naming
    /// rule and a row is self-describing.
    static let weightsName = "model.gguf"

    /// Every row this build implements.
    ///
    /// Every field below was read out of the GGUF itself by loading it and
    /// printing `Model.capabilities` - not copied from a model card. Doing it
    /// that way corrected four assumptions in one pass: Canary has **no
    /// timestamps at all** and a 400-second ceiling, Nemotron **does** identify
    /// its own language, Qwen3-ASR caps a run at about 87 minutes, and
    /// `parakeet-tdt-0.6b-v3` reports 25 languages here where the CoreML row
    /// advertises 28.
    ///
    /// The language strings are stored exactly as the model spells them,
    /// region tags and all, because that spelling is not decoration: Nemotron
    /// accepts `pl-PL` and rejects `pl`, while Canary, Qwen3-ASR and Whisper
    /// accept `pl` and reject `pl-PL`. See `GGMLEngine.resolveLanguage`.
    static let rows: [GGMLRow] = [
        GGMLRow(
            model: "parakeet-tdt-0.6b-v3",
            repoStem: "parakeet-tdt-0.6b-v3",
            quants: ["q8_0", "q4_k_m"],
            languages: [
                "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
            ],
            languageID: true,
            streaming: false,
            wordTimestamps: true,
            segmentTimestamps: true),
        GGMLRow(
            model: "parakeet-unified-en-0.6b",
            repoStem: "parakeet-unified-en-0.6b",
            quants: ["q8_0"],
            languages: ["en"],
            languageID: false,
            streaming: true,
            wordTimestamps: true,
            segmentTimestamps: true),
        GGMLRow(
            model: "canary-1b-v2",
            repoStem: "canary-1b-v2",
            quants: ["q8_0", "q4_k_m"],
            languages: [
                "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
            ],
            // No language identification, and the failure is not an error but a
            // translation: Polish audio with no hint came back as fluent
            // English prose about the same subject. `resolveLanguage` therefore
            // refuses to run this row without one.
            languageID: false,
            streaming: false,
            wordTimestamps: false,
            segmentTimestamps: false),
        GGMLRow(
            model: "qwen3-asr-1.7b",
            repoStem: "Qwen3-ASR-1.7B",
            quants: ["q8_0", "q4_k_m"],
            languages: [
                "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th",
                "vi", "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa",
                "el", "ro", "hu", "mk",
            ],
            languageID: true,
            streaming: false,
            wordTimestamps: false,
            segmentTimestamps: false),
        GGMLRow(
            model: "qwen3-asr-0.6b",
            repoStem: "Qwen3-ASR-0.6B",
            quants: ["q8_0", "q4_k_m"],
            languages: [
                "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th",
                "vi", "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa",
                "el", "ro", "hu", "mk",
            ],
            languageID: true,
            streaming: false,
            wordTimestamps: false,
            segmentTimestamps: false),
        GGMLRow(
            model: "whisper-large-v3-turbo",
            repoStem: "whisper-large-v3-turbo",
            quants: ["q8_0", "q4_k_m"],
            languages: [
                "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca",
                "cs", "cy", "da", "de", "el", "en", "es", "et", "eu", "fa", "fi", "fo", "fr",
                "gl", "gu", "haw", "ha", "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it",
                "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo", "lt", "lv",
                "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no",
                "oc", "pa", "pl", "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn",
                "so", "sq", "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl", "tr",
                "tt", "uk", "ur", "uz", "vi", "yi", "yo", "yue", "zh",
            ],
            languageID: true,
            streaming: false,
            wordTimestamps: false,
            segmentTimestamps: true),
        GGMLRow(
            model: "nemotron-3.5-asr-streaming-0.6b",
            repoStem: "nemotron-3.5-asr-streaming-0.6b",
            quants: ["q8_0", "q4_k_m"],
            // Region tags, and they are load-bearing: this row rejects "pl".
            languages: [
                "en-US", "en-GB", "es-US", "es-ES", "fr-FR", "fr-CA", "it-IT", "pt-BR", "pt-PT",
                "nl-NL", "de-DE", "tr-TR", "ru-RU", "ar-AR", "hi-IN", "ja-JP", "ko-KR", "vi-VN",
                "uk-UA", "pl-PL", "sv-SE", "cs-CZ", "nb-NO", "da-DK", "bg-BG", "fi-FI", "hr-HR",
                "sk-SK", "zh-CN", "hu-HU", "ro-RO", "et-EE",
            ],
            languageID: true,
            streaming: true,
            wordTimestamps: true,
            segmentTimestamps: true),
    ]

    static func row(model: String) -> GGMLRow? {
        rows.first { $0.model == model }
    }

    /// Every `(model, variant)` this build can construct, in catalog order.
    /// Mirrors `FluidEngineFactory.catalogRows` so `speech engines` can list
    /// both without knowing which engine it is looking at.
    static var catalogRows: [(model: String, variant: String?)] {
        rows.flatMap { row in row.quants.map { (model: row.model, variant: Optional($0)) } }
    }

    /// Resolve a catalog id's `@variant` into a quantization this row offers.
    /// A bare id takes the row's best quantization rather than being rejected,
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
