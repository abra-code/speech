// MLXCatalog.swift - which MLX checkpoints the catalog carries for the helper,
// and where each one's files come from.
//
// The models are data - the `"engine": "mlx"` entries of the catalog - and this
// file turns them into rows the engine can install and load. It used to hold
// the rows as Swift, beside a second copy in the shared catalog and two tests
// whose job was proving the copies agreed; there is one copy now.
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

    /// Every usable `mlx` row in the catalog, one per variant, in catalog order.
    public static var rows: [MLXRow] {
        Catalog.models(engine: "mlx").flatMap { (try? make($0).get()) ?? [] }
    }

    /// The `mlx` entries that could not be used, and why.
    public static var problems: [Problem] {
        Catalog.models(engine: "mlx").compactMap {
            guard case .failure(let problem) = make($0) else { return nil }
            return problem
        }
    }

    public struct Problem: Error, Sendable, Equatable {
        /// The entry's `<engine>.<model>`.
        public let key: String
        public let message: String
    }

    /// A catalog entry as its rows, one per variant, or why it cannot be used.
    ///
    /// `files` come from the variant's repository, the model's when the
    /// variant names none; `files_from` adds files from other repositories,
    /// taken in repository-name order so the asset list is the same on every
    /// run. Every row needs `type`, a repository and at least one file.
    public static func make(_ entry: CatalogModel) -> Result<[MLXRow], Problem> {
        func problem(_ message: String) -> Result<[MLXRow], Problem> {
            .failure(Problem(key: entry.key, message: "\(entry.key): \(message)"))
        }
        guard let type = entry.type, !type.isEmpty else {
            return problem("an mlx model needs 'type', the helper's name for its architecture")
        }
        guard let files = entry.files, !files.isEmpty else {
            return problem("an mlx model needs 'files', the files to fetch from its repository")
        }
        let extra = entry.filesFrom ?? [:]
        for file in files + extra.values.flatMap({ $0 }) where !isPlainFileName(file) {
            return problem("'\(file)' is not a plain file name")
        }
        var out: [MLXRow] = []
        for variant in entry.declaredVariants {
            let row = entry.row(variant)
            guard let repo = row.source, !repo.isEmpty else {
                return problem("\(row.id) has no 'source' repository")
            }
            let assets = files.map { MLXAsset(repo: repo, file: $0) }
                + extra.keys.sorted().flatMap { other in
                    (extra[other] ?? []).map { MLXAsset(repo: other, file: $0) }
                }
            out.append(MLXRow(
                model: entry.model,
                variant: variant.variant,
                repo: repo,
                assets: assets,
                type: type,
                languages: entry.languages ?? [],
                languageID: entry.languageID ?? false,
                segmentTimestamps: entry.segmentTimestamps ?? false,
                chunkSeconds: entry.chunkSeconds,
                maxSeconds: entry.maxSeconds ?? 0,
                parametersM: row.parametersM ?? 0,
                precision: row.precision,
                sizeBytes: row.sizeBytes ?? 0,
                label: row.label))
        }
        return .success(out)
    }

    /// A file name the store can hold as one directory entry. The loader opens
    /// these by name inside the row directory, so a path with a separator in
    /// it would be fetched to one place and looked for in another.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
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
