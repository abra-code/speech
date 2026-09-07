// MLXCatalog.swift - which MLX checkpoints this build knows how to fetch and
// hand to the helper, and where each one's files come from.
//
// The same shape as GGMLCatalog and for the same reason: the engine owns its
// own downloads, so the naming rule has to live beside the engine that will
// use it rather than in the shared catalog, which carries only what a caller
// needs in order to list and choose. `theTwoCatalogsAgreeOnWhichRowsExist` and
// `theTwoCatalogsAgreeOnTheFacts` in the tests join the two, so a row cannot
// exist in one and not the other, or name a different repository in each.
//
// WHAT A ROW DOWNLOADS IS A LIST OF FILES, NOT A REPOSITORY. Two reasons, both
// measured rather than anticipated. An `mlx-community` ASR repository holds
// files the loader never opens - a README, a .gitattributes - and fetching a
// repository wholesale would put them in a directory the store then has to call
// complete. And one row's files do not all come from one repository:
// `mlx-community/whisper-large-v3-turbo` ships `config.json` and
// `weights.safetensors` and nothing else, while the loader in mlx-audio-swift
// v0.1.3 goes to the network for tokenizer assets when `tokenizer.json` is
// absent - which the helper refuses, because a helper that downloads is a
// helper that can write into the model store from outside every rule the store
// has. So `speech` fetches those eight files from `openai/whisper-large-v3-turbo`
// instead, and the row says so.

import Foundation
import SpeechCore

/// One file a row needs, and the repository it comes from.
public struct MLXAsset: Sendable, Equatable {
    public var repo: String
    public var file: String

    public init(repo: String, file: String) {
        self.repo = repo
        self.file = file
    }
}

/// One installable MLX row.
public struct MLXRow: Sendable, Equatable {
    public var model: String
    public var variant: String?
    /// The repository most of the files come from; also what a listing shows.
    public var repo: String
    public var assets: [MLXAsset]
    /// What the helper calls this architecture, as `config.json` spells it
    /// where the file says at all. Sent with `load` so the helper does not have
    /// to guess: the NeMo configs the Parakeet rows ship carry no `model_type`
    /// field of any kind, and the helper's fallback is the directory name,
    /// which is a naming convention rather than a fact.
    public var type: String
    /// Advisory, and only until the weights are read. The `loaded` reply
    /// reports what the checkpoint itself names, and that is what gates; this
    /// is what `speech engines` can say before a download exists.
    public var languages: [String]
    public var languageID: Bool
    public var segmentTimestamps: Bool
    /// Seconds of audio the model may hold in one decoding chunk, passed
    /// through on every `transcribe`.
    ///
    /// Not a tuning knob. mlx-audio-swift's default is 1200 seconds, and its
    /// issue #248 reports that default building a roughly 7 GB KV cache and
    /// hanging a 108-minute file on a 48 GB machine. nil means the model does
    /// not chunk and the field does not apply.
    public var chunkSeconds: Double?
    /// Longest buffer this row is given in one request, or zero for no limit.
    /// `speech` cuts anything longer at a silence and offsets the timestamps,
    /// which is the same thing it does for the `ggml` rows with a hard ceiling.
    public var maxSeconds: Double
    public var parametersM: Int
    public var precision: String
    public var sizeBytes: Int64
    public var label: String

    public var id: String {
        variant.map { "mlx.\(model)@\($0)" } ?? "mlx.\(model)"
    }

    public init(
        model: String, variant: String? = nil, repo: String, assets: [MLXAsset],
        type: String, languages: [String], languageID: Bool, segmentTimestamps: Bool,
        chunkSeconds: Double? = nil, maxSeconds: Double = 0,
        parametersM: Int, precision: String, sizeBytes: Int64, label: String
    ) {
        self.model = model
        self.variant = variant
        self.repo = repo
        self.assets = assets
        self.type = type
        self.languages = languages
        self.languageID = languageID
        self.segmentTimestamps = segmentTimestamps
        self.chunkSeconds = chunkSeconds
        self.maxSeconds = maxSeconds
        self.parametersM = parametersM
        self.precision = precision
        self.sizeBytes = sizeBytes
        self.label = label
    }
}

public enum MLXCatalog {
    /// Whether a directory holds everything this row's install fetched.
    ///
    /// Every asset, not a config and any `.safetensors`: a Parakeet row needs
    /// its `tokenizer.model`, `tokenizer.vocab` and `vocab.txt`, and a Whisper
    /// row needs eight tokenizer files from a second repository, none of which
    /// a generic check would notice were missing. The `ggml` rows get their
    /// equivalent guarantee by reading the GGUF's magic bytes; the equivalent
    /// here is asking the row what it asked for.
    ///
    /// What it deliberately does NOT require is anything the library writes
    /// after the fact. The Qwen3-ASR loader puts a `tokenizer.json` of its own
    /// into the directory the first time it reads one, and that file is in no
    /// row's asset list - so a rule built on the asset list cannot be changed
    /// out from under the store by the library.
    public static func isComplete(_ directory: URL, row: MLXRow) -> Bool {
        let manager = FileManager.default
        return row.assets.allSatisfy {
            manager.fileExists(atPath: directory.appendingPathComponent($0.file).path)
        }
    }

    public static let rows: [MLXRow] = [
        // Parakeet's own alignment is what makes it worth measuring here: of
        // the eight types the helper implements, only the two NeMo families
        // return real spans rather than one per decoding window.
        MLXRow(
            model: "parakeet-tdt-0.6b-v3",
            repo: "mlx-community/parakeet-tdt-0.6b-v3",
            assets: parakeetAssets(repo: "mlx-community/parakeet-tdt-0.6b-v3"),
            type: "parakeet",
            // The same 25 the `ggml` row of this model names, so the two rows
            // are comparable cell by cell. The checkpoint is the same one.
            languages: [
                "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
            ],
            languageID: true,
            segmentTimestamps: true,
            parametersM: 600,
            precision: "bf16",
            sizeBytes: 2_509_041_541,
            label: "Parakeet TDT 0.6B v3 (MLX, bf16)"),

        // English only, and here because it is small enough to run this engine
        // end to end without a two-and-a-half-gigabyte download - which is what
        // it was used for while the protocol was being built.
        MLXRow(
            model: "parakeet-tdt_ctc-110m",
            repo: "mlx-community/parakeet-tdt_ctc-110m",
            assets: parakeetAssets(repo: "mlx-community/parakeet-tdt_ctc-110m"),
            type: "parakeet",
            languages: ["en"],
            languageID: false,
            segmentTimestamps: true,
            parametersM: 110,
            precision: "bf16",
            sizeBytes: 458_958_626,
            label: "Parakeet TDT-CTC 110M (MLX, bf16)"),

        // Whisper reports one span per 30-second decoding window rather than
        // per utterance, so `segmentTimestamps` is true and means something
        // much coarser here than it does for Parakeet. `done.synthesized` is
        // what tells the two apart at run time.
        MLXRow(
            model: "whisper-large-v3-turbo",
            repo: "mlx-community/whisper-large-v3-turbo",
            assets: [
                MLXAsset(repo: "mlx-community/whisper-large-v3-turbo", file: "config.json"),
                MLXAsset(repo: "mlx-community/whisper-large-v3-turbo", file: "weights.safetensors"),
            ] + whisperTokenizerAssets,
            type: "whisper",
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
            segmentTimestamps: true,
            parametersM: 809,
            precision: "fp16",
            sizeBytes: 1_618_594_759,
            label: "Whisper large-v3-turbo (MLX, fp16)"),

        // Two variants rather than the five mlx-community publishes, and the
        // two chosen are the ones that line up with the q8_0 and q4_k_m pair
        // every other family here is measured at. bf16 exists and is 4.1 GB;
        // adding it is a row, not a change.
        qwen3Row(
            variant: "8bit", precision: "int8",
            sizeBytes: 2_467_856_503, label: "Qwen3-ASR 1.7B (MLX, 8-bit)"),
        qwen3Row(
            variant: "4bit", precision: "int4",
            sizeBytes: 1_607_630_579, label: "Qwen3-ASR 1.7B (MLX, 4-bit)"),
    ]

    /// Everything the Whisper tokenizer needs, from the model's own upstream
    /// repository, because the MLX conversion ships none of it.
    ///
    /// EIGHT FILES, AND THE FIRST ATTEMPT SHIPPED ONE. `tokenizer.json` alone
    /// looked sufficient - it is what the loader tests for before deciding to
    /// go to the network - and the load then failed with `missingConfig` out of
    /// swift-transformers, which wants `tokenizer_config.json` as well. This is
    /// the list mlx-audio-swift's own `downloadTokenizerAssets` fetches, which
    /// is the only authority on it, and every one of these exists in the turbo
    /// repository.
    ///
    /// From `openai/whisper-large-v3-turbo` rather than the `openai/whisper-large-v3`
    /// the library would have picked: the library chooses by vocabulary size,
    /// which is 51,866 for both, and this row is the turbo model.
    private static let whisperTokenizerAssets: [MLXAsset] = [
        "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
        "added_tokens.json", "vocab.json", "merges.txt", "normalizer.json",
        "generation_config.json",
    ].map { MLXAsset(repo: "openai/whisper-large-v3-turbo", file: $0) }

    /// The five files an mlx-community NeMo conversion actually needs. The
    /// repository also holds a README and a .gitattributes, which the loader
    /// never opens.
    private static func parakeetAssets(repo: String) -> [MLXAsset] {
        ["config.json", "model.safetensors", "tokenizer.model", "tokenizer.vocab", "vocab.txt"]
            .map { MLXAsset(repo: repo, file: $0) }
    }

    private static func qwen3Row(
        variant: String, precision: String, sizeBytes: Int64, label: String
    ) -> MLXRow {
        let repo = "mlx-community/Qwen3-ASR-1.7B-\(variant)"
        return MLXRow(
            model: "qwen3-asr-1.7b",
            variant: variant,
            repo: repo,
            // No tokenizer.json: this family tokenizes from vocab.json plus
            // merges.txt, and the helper's loader writes a tokenizer.json of
            // its own beside them the first time it reads the directory.
            assets: [
                "chat_template.json", "config.json", "generation_config.json", "merges.txt",
                "model.safetensors", "model.safetensors.index.json", "preprocessor_config.json",
                "tokenizer_config.json", "vocab.json",
            ].map { MLXAsset(repo: repo, file: $0) },
            type: "qwen3_asr",
            languages: [
                "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th",
                "vi", "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa",
                "el", "ro", "hu", "mk",
            ],
            languageID: true,
            // One span per decoding chunk, which is not an utterance boundary.
            segmentTimestamps: true,
            // The library's own default here is 1200 seconds. See MLXRow.
            chunkSeconds: 30,
            parametersM: 1_700,
            precision: precision,
            sizeBytes: sizeBytes,
            label: label)
    }

    public static func row(model: String, variant: String?) -> MLXRow? {
        rows.first { $0.model == model && $0.variant == variant }
    }

    /// Every model name, deduplicated, in catalog order.
    public static var models: [String] {
        var seen: Set<String> = []
        return rows.compactMap { seen.insert($0.model).inserted ? $0.model : nil }
    }

    /// The variants published for a model, for an error message that can say
    /// what was expected instead of only what was wrong.
    public static func variants(of model: String) -> [String] {
        rows.filter { $0.model == model }.compactMap(\.variant)
    }
}
