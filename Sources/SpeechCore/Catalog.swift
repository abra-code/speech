// Catalog.swift - the inventory of every way this build can run speech
// recognition, and where each one's weights come from.
//
// This is a list, not a recommendation. `speech engines` answers "what can this
// binary construct" and `speech models list` answers "what is on disk"; neither
// can tell you that a row is 740 MB, that it comes from a particular repository
// under a particular file name, or that it is one of two precisions of the same
// model. The tool has to know all of that anyway - the engines insist on owning
// their own downloads and model directories - so reporting it is the one place
// this program is authoritative.
//
// What is deliberately not here: any judgment about which row to use. No
// ranking, no scores, no blurbs, no "recommended". Choosing between these rows
// depends on the language, the machine, the recording and the user's own ears,
// and the numbers that would inform it are machine-specific and age with every
// OS and dependency bump. That decision belongs to Speech.app, which can
// re-measure on the machine it is running on and against the user's own
// recordings. The declaration order of the arrays below is grouped for reading;
// the order callers see is computed by `ordered`, further down.
//
// Also not here: languages, capability flags and the macOS floor. Those are the
// engine's own answers, read out of a GGUF or a CoreML bundle when the model
// loads and reported through `EngineCapabilities`. Stage 2 found four
// capability facts that the published model cards had wrong, so a second copy
// in a static table is a copy that will eventually lie. The join happens in the
// one place both are visible, the `speech` executable.

import Foundation

/// Which model a row is a build of. Two rows in the same family are the same
/// model at a different precision, on a different runtime, or at a different
/// streaming chunk size. Reported so that a caller can group them; the grouping
/// implies no order.
public enum CatalogFamily: String, Sendable, Codable, CaseIterable {
    case apple
    case canary
    case nemotron
    case parakeet
    case parakeetUnified = "parakeet-unified"
    case qwen3ASR = "qwen3-asr"
    case silero
    case whisper
}

/// Not every installable row transcribes. The CTC spotter is downloaded and
/// managed like a model but only spots vocabulary terms for the Parakeet rows,
/// and the Silero detector only says where speech starts and stops, so the
/// distinction has to be data rather than something each caller rediscovers.
public enum CatalogRole: String, Sendable, Codable {
    case transcriber
    case helper
}

/// One catalog row. `id` is the same `<engine>.<model>[@<variant>]` string the
/// rest of the tool uses, so a row joins to an engine, to a store entry and to
/// a measurement by id alone.
public struct CatalogRow: Sendable, Equatable {
    public var id: String
    public var family: CatalogFamily
    public var role: CatalogRole
    /// Hugging Face repository the weights come from; nil for the Apple rows,
    /// whose assets the OS installs.
    public var source: String?
    /// The single GGUF file inside `source`, for `ggml` rows only. A `fluid`
    /// row downloads a directory, and an `apple` row downloads nothing.
    public var file: String?
    /// Parameters in millions, for ordering and display. Nil where the number
    /// is not published (the Apple rows).
    public var parametersM: Int?
    /// int8, int4, fp16, mixed, q8_0, q4_k_m, or "system" for a row the OS
    /// ships. Taken from what the build actually is rather than from a
    /// convention: the Silero export stores some tensors at Float16 and some at
    /// Float32 and calls itself mixed, so this says mixed.
    public var precision: String
    /// Nominal download size: the bytes this tool actually fetches, which for a
    /// `fluid` row is a subset of its repository rather than the whole of it.
    /// Nil where no download has been made and the subset cannot be derived.
    public var sizeBytes: Int64?
    /// A plain display name. Descriptive, never evaluative: it says which
    /// build this is, not whether it is any good.
    public var label: String

    public init(
        id: String, family: CatalogFamily, role: CatalogRole = .transcriber,
        source: String? = nil, file: String? = nil, parametersM: Int? = nil,
        precision: String, sizeBytes: Int64? = nil, label: String
    ) {
        self.id = id
        self.family = family
        self.role = role
        self.source = source
        self.file = file
        self.parametersM = parametersM
        self.precision = precision
        self.sizeBytes = sizeBytes
        self.label = label
    }

    /// The engine prefix, which is everything before the first dot. Derived
    /// rather than stored: `EngineSpec.parse` already owns this split, and two
    /// places deciding what "the engine part of an id" means is one place too
    /// many.
    public var engine: String {
        String(id.prefix(while: { $0 != "." }))
    }
}

public enum Catalog {
    /// Every row this build can run, grouped by family so that a caller can
    /// show the builds of one model together.
    ///
    /// The order is computed rather than chosen, and that is the point. An
    /// order somebody picked would be read as a ranking no matter what the
    /// comment above it said, and this program is in no position to rank these:
    /// two rows here can differ by five WER points in one language and be the
    /// other way round in another, on a machine and an OS this build knows
    /// nothing about. So families sort alphabetically, and within a family rows
    /// sort by engine and then by descending download size. `orderIsMechanical`
    /// in the tests keeps it that way.
    public static let rows: [CatalogRow] = ordered(
        appleRows + canaryRows + nemotronRows + parakeetRows + parakeetUnifiedRows
            + qwen3Rows + sileroRows + whisperRows)

    /// Families alphabetically; within a family, engine then largest build
    /// first, with an unknown size last and the id breaking any remaining tie.
    /// Total and stable, so the listing is byte-identical between runs.
    static func ordered(_ rows: [CatalogRow]) -> [CatalogRow] {
        rows.sorted { first, second in
            if first.family != second.family {
                return first.family.rawValue < second.family.rawValue
            }
            if first.engine != second.engine { return first.engine < second.engine }
            let left = first.sizeBytes ?? -1
            let right = second.sizeBytes ?? -1
            if left != right { return left > right }
            return first.id < second.id
        }
    }

    // MARK: - Apple

    static let appleRows: [CatalogRow] = [
        CatalogRow(
            id: "apple.transcriber",
            family: .apple,
            precision: "system",
            label: "Apple long-form (built in)"),
        CatalogRow(
            id: "apple.dictation",
            family: .apple,
            precision: "system",
            label: "Apple dictation (built in)"),
    ]

    // MARK: - Canary

    // `fluid.canary-1b-v2@int4` is deliberately absent, and this is the one
    // exclusion in the file that is not "no engine can build it". The engine
    // still exists and still builds, so an id typed in full downloads and runs;
    // it is only unlisted, which is why the note lives here rather than in
    // `CanaryEngine`.
    //
    // The reason is not a preference between rows, which this file does not
    // express. It is that FluidInference's int4 CoreML conversion of these
    // weights is beaten by the GGUF build of the same weights on every axis
    // measured, and is broken on M1-generation hardware. Against
    // `ggml.canary-1b-v2@q4_k_m` over FLEURS, all 647 to 908 rows per language:
    //
    //     language   int4 WER   q4_k_m WER   int4 RTFx   q4_k_m RTFx
    //     de_de          6.96         4.59         7.7          59.5
    //     en_us          6.36         5.04         7.6          63.1
    //     es_419         6.03         3.10         5.4          49.8
    //     pl_pl         11.77         7.19         6.0          49.3
    //
    // Those are M5 figures, where the conversion works as intended. On M1 and
    // M1 Pro the ANE compiler fails on part of the graph - "ANECCompile()
    // FAILED", after 85 minutes of trying, byte-identical on both chips - and
    // leaves 149 MB of a 570 MB model on the Neural Engine with the rest on
    // single-threaded BNNS: RTFx 3.7 and 3.4 GB of memory against the GGUF's
    // 36.3 and 0.89 GB. FluidAudio labels the conversion beta.
    //
    // If a later conversion fixes this, the row goes back and this note goes
    // with it. Re-measure before believing that, and re-measure on an M1.
    static let canaryRows: [CatalogRow] = [
        CatalogRow(
            id: "ggml.canary-1b-v2@q8_0",
            family: .canary,
            source: "handy-computer/canary-1b-v2-gguf",
            file: "canary-1b-v2-Q8_0.gguf",
            parametersM: 1000,
            precision: "q8_0",
            sizeBytes: 1_144_290_016,
            label: "Canary 1B v2 (Q8_0)"),
        CatalogRow(
            id: "ggml.canary-1b-v2@q4_k_m",
            family: .canary,
            source: "handy-computer/canary-1b-v2-gguf",
            file: "canary-1b-v2-Q4_K_M.gguf",
            parametersM: 1000,
            precision: "q4_k_m",
            sizeBytes: 735_476_448,
            label: "Canary 1B v2 (Q4_K_M)"),
    ]

    // MARK: - Whisper

    static let whisperRows: [CatalogRow] = [
        CatalogRow(
            id: "mlx.whisper-large-v3-turbo",
            family: .whisper,
            source: "mlx-community/whisper-large-v3-turbo",
            parametersM: 809,
            precision: "fp16",
            // Two files from that repository plus the eight tokenizer files
            // from openai/whisper-large-v3-turbo, which the MLX conversion does
            // not ship and the loader will not run without. `source` names
            // where the weights come from; MLXCatalog owns the full list.
            sizeBytes: 1_618_594_759,
            label: "Whisper large-v3-turbo (MLX, fp16)"),
        CatalogRow(
            id: "ggml.whisper-large-v3-turbo@q8_0",
            family: .whisper,
            source: "handy-computer/whisper-large-v3-turbo-gguf",
            file: "whisper-large-v3-turbo-Q8_0.gguf",
            parametersM: 809,
            precision: "q8_0",
            sizeBytes: 886_381_760,
            label: "Whisper large-v3-turbo (Q8_0)"),
        CatalogRow(
            id: "ggml.whisper-large-v3-turbo@q4_k_m",
            family: .whisper,
            source: "handy-computer/whisper-large-v3-turbo-gguf",
            file: "whisper-large-v3-turbo-Q4_K_M.gguf",
            parametersM: 809,
            precision: "q4_k_m",
            sizeBytes: 536_069_728,
            label: "Whisper large-v3-turbo (Q4_K_M)"),
    ]

    // MARK: - Parakeet

    static let parakeetRows: [CatalogRow] = [
        CatalogRow(
            id: "mlx.parakeet-tdt-0.6b-v3",
            family: .parakeet,
            source: "mlx-community/parakeet-tdt-0.6b-v3",
            parametersM: 600,
            precision: "bf16",
            sizeBytes: 2_509_041_541,
            label: "Parakeet TDT 0.6B v3 (MLX, bf16)"),
        CatalogRow(
            id: "mlx.parakeet-tdt_ctc-110m",
            family: .parakeet,
            source: "mlx-community/parakeet-tdt_ctc-110m",
            parametersM: 110,
            precision: "bf16",
            sizeBytes: 458_958_626,
            label: "Parakeet TDT-CTC 110M (MLX, bf16)"),
        CatalogRow(
            id: "ggml.parakeet-tdt-0.6b-v3@q8_0",
            family: .parakeet,
            source: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
            file: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
            parametersM: 600,
            precision: "q8_0",
            sizeBytes: 739_508_576,
            label: "Parakeet v3 (Q8_0)"),
        CatalogRow(
            id: "fluid.parakeet-v3@int8",
            family: .parakeet,
            source: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            parametersM: 600,
            precision: "int8",
            sizeBytes: 483_257_242,
            label: "Parakeet v3 (int8)"),
        CatalogRow(
            id: "ggml.parakeet-tdt-0.6b-v3@q4_k_m",
            family: .parakeet,
            source: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
            file: "parakeet-tdt-0.6b-v3-Q4_K_M.gguf",
            parametersM: 600,
            precision: "q4_k_m",
            sizeBytes: 485_425_504,
            label: "Parakeet v3 (Q4_K_M)"),
        CatalogRow(
            id: "fluid.parakeet-v3@int4",
            family: .parakeet,
            source: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            parametersM: 600,
            precision: "int4",
            sizeBytes: 335_897_098,
            label: "Parakeet v3 (int4)"),
        CatalogRow(
            id: "fluid.parakeet-ctc-110m",
            family: .parakeet,
            role: .helper,
            source: "FluidInference/parakeet-ctc-110m-coreml",
            parametersM: 110,
            precision: "int8",
            sizeBytes: 102_803_869,
            label: "Parakeet CTC 110M (spotter)"),
    ]

    // MARK: - Parakeet Unified (English only)

    static let parakeetUnifiedRows: [CatalogRow] = [
        CatalogRow(
            id: "fluid.parakeet-unified@int8",
            family: .parakeetUnified,
            source: "FluidInference/parakeet-unified-en-0.6b-coreml",
            parametersM: 600,
            precision: "int8",
            sizeBytes: 614_082_275,
            label: "Parakeet Unified EN (int8)"),
        CatalogRow(
            id: "ggml.parakeet-unified-en-0.6b@q8_0",
            family: .parakeetUnified,
            source: "handy-computer/parakeet-unified-en-0.6b-gguf",
            file: "parakeet-unified-en-0.6b-Q8_0.gguf",
            parametersM: 600,
            precision: "q8_0",
            sizeBytes: 731_357_568,
            label: "Parakeet Unified EN (Q8_0)"),
        CatalogRow(
            id: "fluid.parakeet-unified@fp16",
            family: .parakeetUnified,
            source: "FluidInference/parakeet-unified-en-0.6b-coreml",
            parametersM: 600,
            precision: "fp16",
            sizeBytes: 1_205_620_423,
            label: "Parakeet Unified EN (fp16)"),
        // The streaming export of the same checkpoint, one row per published
        // [left, chunk, right] attention context. The mask is baked into the
        // encoder at conversion time, so the tier is a different 591 MB bundle
        // rather than a setting - which is why these are rows and not a mode of
        // the two above, and why installing one does not install another. The
        // number in the id is the theoretical latency in milliseconds: chunk
        // plus look-ahead, the delay before the encoder can see a whole word.
        CatalogRow(
            id: "fluid.parakeet-unified@stream-2080",
            family: .parakeetUnified,
            source: "FluidInference/parakeet-unified-en-0.6b-coreml",
            parametersM: 600,
            precision: "int8",
            sizeBytes: 609_440_571,
            label: "Parakeet Unified EN streaming 2.08 s (int8)"),
        CatalogRow(
            id: "fluid.parakeet-unified@stream-1120",
            family: .parakeetUnified,
            source: "FluidInference/parakeet-unified-en-0.6b-coreml",
            parametersM: 600,
            precision: "int8",
            sizeBytes: 608_834_659,
            label: "Parakeet Unified EN streaming 1.12 s (int8)"),
        CatalogRow(
            id: "fluid.parakeet-unified@stream-640",
            family: .parakeetUnified,
            source: "FluidInference/parakeet-unified-en-0.6b-coreml",
            parametersM: 600,
            precision: "int8",
            sizeBytes: 608_531_778,
            label: "Parakeet Unified EN streaming 0.64 s (int8)"),
        CatalogRow(
            id: "fluid.parakeet-unified@stream-320",
            family: .parakeetUnified,
            source: "FluidInference/parakeet-unified-en-0.6b-coreml",
            parametersM: 600,
            precision: "int8",
            sizeBytes: 608_330_968,
            label: "Parakeet Unified EN streaming 0.32 s (int8)"),
    ]

    // MARK: - Qwen3-ASR

    static let qwen3Rows: [CatalogRow] = [
        CatalogRow(
            id: "mlx.qwen3-asr-1.7b@8bit",
            family: .qwen3ASR,
            source: "mlx-community/Qwen3-ASR-1.7B-8bit",
            parametersM: 1_700,
            precision: "int8",
            sizeBytes: 2_467_856_503,
            label: "Qwen3-ASR 1.7B (MLX, 8-bit)"),
        CatalogRow(
            id: "mlx.qwen3-asr-1.7b@4bit",
            family: .qwen3ASR,
            source: "mlx-community/Qwen3-ASR-1.7B-4bit",
            parametersM: 1_700,
            precision: "int4",
            sizeBytes: 1_607_630_579,
            label: "Qwen3-ASR 1.7B (MLX, 4-bit)"),
        CatalogRow(
            id: "ggml.qwen3-asr-1.7b@q8_0",
            family: .qwen3ASR,
            source: "handy-computer/Qwen3-ASR-1.7B-gguf",
            file: "Qwen3-ASR-1.7B-Q8_0.gguf",
            parametersM: 1700,
            precision: "q8_0",
            sizeBytes: 2_185_030_624,
            label: "Qwen3-ASR 1.7B (Q8_0)"),
        CatalogRow(
            id: "ggml.qwen3-asr-1.7b@q4_k_m",
            family: .qwen3ASR,
            source: "handy-computer/Qwen3-ASR-1.7B-gguf",
            file: "Qwen3-ASR-1.7B-Q4_K_M.gguf",
            parametersM: 1700,
            precision: "q4_k_m",
            sizeBytes: 1_319_830_496,
            label: "Qwen3-ASR 1.7B (Q4_K_M)"),
        CatalogRow(
            id: "ggml.qwen3-asr-0.6b@q8_0",
            family: .qwen3ASR,
            source: "handy-computer/Qwen3-ASR-0.6B-gguf",
            file: "Qwen3-ASR-0.6B-Q8_0.gguf",
            parametersM: 600,
            precision: "q8_0",
            sizeBytes: 850_423_456,
            label: "Qwen3-ASR 0.6B (Q8_0)"),
        CatalogRow(
            id: "ggml.qwen3-asr-0.6b@q4_k_m",
            family: .qwen3ASR,
            source: "handy-computer/Qwen3-ASR-0.6B-gguf",
            file: "Qwen3-ASR-0.6B-Q4_K_M.gguf",
            parametersM: 600,
            precision: "q4_k_m",
            sizeBytes: 589_560_480,
            label: "Qwen3-ASR 0.6B (Q4_K_M)"),
    ]

    // MARK: - Silero

    static let sileroRows: [CatalogRow] = [
        // The only row here that produces no text at all. It is a catalog row
        // because it is downloaded, measured, listed and deleted exactly like a
        // model, and `--segment vad` cannot run until it is installed - which
        // is a download instruction a user has to be able to find.
        //
        // No parameter count: Silero publishes none for this export, and the
        // field is in millions, so the only number that could go here is a zero
        // that would read as "unknown" anyway.
        CatalogRow(
            id: "fluid.silero-vad",
            family: .silero,
            role: .helper,
            source: "FluidInference/silero-vad-coreml",
            precision: "mixed",
            sizeBytes: 1_063_427,
            label: "Silero VAD 256 ms (v6.2.1)"),
    ]

    // MARK: - Nemotron

    static let nemotronRows: [CatalogRow] = [
        CatalogRow(
            id: "ggml.nemotron-3.5-asr-streaming-0.6b@q8_0",
            family: .nemotron,
            source: "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf",
            file: "nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf",
            parametersM: 600,
            precision: "q8_0",
            sizeBytes: 751_094_240,
            label: "Nemotron 3.5 streaming (Q8_0)"),
        CatalogRow(
            id: "ggml.nemotron-3.5-asr-streaming-0.6b@q4_k_m",
            family: .nemotron,
            source: "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf",
            file: "nemotron-3.5-asr-streaming-0.6b-Q4_K_M.gguf",
            parametersM: 600,
            precision: "q4_k_m",
            sizeBytes: 495_831_520,
            label: "Nemotron 3.5 streaming (Q4_K_M)"),
        CatalogRow(
            id: "fluid.nemotron-multilingual@2240",
            family: .nemotron,
            source: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
            parametersM: 600,
            precision: "int8",
            sizeBytes: 664_846_846,
            label: "Nemotron 3.5 streaming (2.24 s chunks)"),
        CatalogRow(
            id: "fluid.nemotron-multilingual@1120",
            family: .nemotron,
            source: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
            parametersM: 600,
            precision: "int8",
            sizeBytes: 664_144_423,
            label: "Nemotron 3.5 streaming (1.12 s chunks)"),
        CatalogRow(
            id: "fluid.nemotron-multilingual@560",
            family: .nemotron,
            source: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
            parametersM: 600,
            precision: "int8",
            label: "Nemotron 3.5 streaming (0.56 s chunks)"),
    ]

    /// The row for a catalog id, or nil when the id names something the catalog
    /// does not carry. Lookup is case-sensitive because catalog ids are, and a
    /// lenient match here would let `models download` install to one directory
    /// and `catalog` describe another.
    public static func row(id: String) -> CatalogRow? {
        rows.first { $0.id == id }
    }

    /// The rows of one family, in the array's order.
    public static func rows(family: CatalogFamily) -> [CatalogRow] {
        rows.filter { $0.family == family }
    }

    /// The families that have at least one row, in catalog order.
    public static var families: [CatalogFamily] {
        var seen: Set<CatalogFamily> = []
        return rows.compactMap { seen.insert($0.family).inserted ? $0.family : nil }
    }
}
