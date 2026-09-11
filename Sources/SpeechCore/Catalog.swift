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
// recordings. The order callers see is computed by `ordered`, further down.
//
// The rows themselves are data: the JSON documents in the repository's
// `catalog/`, installed beside the binary as `speech-catalog/`, plus whatever a
// user adds. See CatalogData.swift for the format and the merge.
//
// Capability facts in those documents are advisory. The authority is the
// engine's own answer, read out of a GGUF or a CoreML bundle when the model
// loads and reported through `EngineCapabilities`: stage 2 found four
// capability facts that the published model cards had wrong.

import Foundation

/// Which model a row is a build of. Two rows in the same family are the same
/// model at a different precision, on a different runtime, or at a different
/// streaming chunk size. Reported so that a caller can group them; the grouping
/// implies no order.
///
/// An open set, not an enum: a model a user adds brings its own family - for a
/// GGUF, the architecture the file names - and a closed list would have to be
/// edited before such a model could exist. The names below are the ones the
/// built-in catalog uses, kept as constants for the code that refers to them.
public struct CatalogFamily: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let apple = CatalogFamily(rawValue: "apple")
    public static let canary = CatalogFamily(rawValue: "canary")
    public static let nemotron = CatalogFamily(rawValue: "nemotron")
    public static let parakeet = CatalogFamily(rawValue: "parakeet")
    public static let parakeetUnified = CatalogFamily(rawValue: "parakeet-unified")
    public static let qwen3ASR = CatalogFamily(rawValue: "qwen3-asr")
    public static let silero = CatalogFamily(rawValue: "silero")
    public static let whisper = CatalogFamily(rawValue: "whisper")
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
    // MARK: - The loaded catalog

    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed: LoadedCatalog?

    /// The catalog every lookup reads. Loaded from the built-in directory on
    /// first use; the `speech` executable replaces it at startup with the
    /// built-in catalog merged with the user's own. A library default that
    /// read the user's files would make every test depend on what is in the
    /// developer's Application Support. Tests never call `install`: Swift
    /// Testing runs them in parallel, and one that swapped this value would
    /// change what every other test reads. They load into a `LoadedCatalog`
    /// value instead.
    ///
    /// When the built-in catalog cannot be found this is an empty catalog whose
    /// one problem says why, rather than a crash: the executable checks it at
    /// startup and refuses to run, and a library caller can read the problem.
    public static var current: LoadedCatalog {
        lock.withLock {
            if let installed { return installed }
            let loaded: LoadedCatalog
            do {
                loaded = try LoadedCatalog.load(builtin: try builtinDirectory())
            } catch let error as SpeechError {
                loaded = LoadedCatalog(models: [], problems: [error.message])
            } catch {
                loaded = LoadedCatalog(models: [], problems: ["\(error)"])
            }
            installed = loaded
            return loaded
        }
    }

    /// Replaces the catalog every lookup reads.
    public static func install(_ catalog: LoadedCatalog) {
        lock.withLock { installed = catalog }
    }

    /// Where the built-in catalog is: `$SPEECH_BUILTIN_CATALOG_DIR`, else
    /// `speech-catalog/` beside the running binary, else - in a debug build
    /// only - the repository's own `catalog/`, which is what `swift test` and
    /// `swift run` find.
    ///
    /// The source-tree fallback is debug-only on purpose: a release build that
    /// was packaged without its catalog must fail on the developer's machine
    /// too, rather than quietly reading the checkout it was built from.
    public static func builtinDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableDirectory: URL? = Bundle.main.executableURL?
            .resolvingSymlinksInPath().deletingLastPathComponent()
    ) throws -> URL {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if let override = environment["SPEECH_BUILTIN_CATALOG_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw SpeechError.runtime(
                    "SPEECH_BUILTIN_CATALOG_DIR is set to \(override), which is not a directory")
            }
            return url
        }
        if let executableDirectory {
            let beside = executableDirectory.appendingPathComponent(builtinDirectoryName)
            if manager.fileExists(atPath: beside.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return beside
            }
        }
        #if DEBUG
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // SpeechCore
            .deletingLastPathComponent()    // Sources
            .deletingLastPathComponent()    // the repository
            .appendingPathComponent("catalog")
        if manager.fileExists(atPath: sourceTree.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return sourceTree
        }
        #endif
        throw SpeechError.runtime(
            "no \(builtinDirectoryName) beside "
            + (executableDirectory?.path ?? "the running binary")
            + ". Build with ./build.sh, which installs it, or set SPEECH_BUILTIN_CATALOG_DIR")
    }

    /// The directory name the build installs beside the binary.
    public static let builtinDirectoryName = "speech-catalog"

    /// Where a user's own catalog documents live: `$SPEECH_CATALOG_DIR`, else
    /// `Catalog` beside the default model store in Application Support.
    public static func userDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["SPEECH_CATALOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Speech/Catalog", isDirectory: true)
    }

    // MARK: - Lookups

    /// Every model entry of one engine, hidden ones included, in catalog order.
    /// Engines read these: a hidden variant is unlisted, not unbuildable.
    public static func models(engine: String) -> [CatalogModel] {
        current.models.filter { $0.engine == engine }
    }

    /// The model entry an engine and model name refer to.
    public static func model(engine: String, model: String) -> CatalogModel? {
        current.models.first { $0.engine == engine && $0.model == model }
    }

    /// Every listed row this build can run, grouped by family so that a caller
    /// can show the builds of one model together.
    ///
    /// The order is computed rather than chosen, and that is the point. An
    /// order somebody picked would be read as a ranking no matter what the
    /// comment above it said, and this program is in no position to rank these:
    /// two rows here can differ by five WER points in one language and be the
    /// other way round in another, on a machine and an OS this build knows
    /// nothing about. So families sort alphabetically, and within a family rows
    /// sort by engine and then by descending download size. `orderIsMechanical`
    /// in the tests keeps it that way.
    public static var rows: [CatalogRow] {
        ordered(current.models.flatMap { model in
            model.declaredVariants.filter { !model.isHidden($0) }.map { model.row($0) }
        })
    }

    /// Whether an id names a variant the catalog carries but does not list.
    public static func isHidden(id: String) -> Bool {
        for model in current.models {
            for variant in model.declaredVariants where model.id(variant: variant.variant) == id {
                return model.isHidden(variant)
            }
        }
        return false
    }

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

    /// The listed row for a catalog id, or nil when the id names something the
    /// catalog does not list. Lookup is case-sensitive because catalog ids are,
    /// and a lenient match here would let `models download` install to one
    /// directory and `catalog` describe another.
    public static func row(id: String) -> CatalogRow? {
        rows.first { $0.id == id }
    }

    /// The rows of one family, in catalog order.
    public static func rows(family: CatalogFamily) -> [CatalogRow] {
        rows.filter { $0.family == family }
    }

    /// The families that have at least one row, in catalog order.
    public static var families: [CatalogFamily] {
        var seen: Set<CatalogFamily> = []
        return rows.compactMap { seen.insert($0.family).inserted ? $0.family : nil }
    }
}
