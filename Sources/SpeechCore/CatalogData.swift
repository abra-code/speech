// CatalogData.swift - the catalog as data: the JSON format, the loader, and the
// merge of the built-in files with a user's own.
//
// The inventory used to be Swift arrays, split across Catalog.swift and one
// table per engine, with tests whose only job was to prove the copies agreed.
// It is now one set of JSON documents. The built-in ones ship beside the binary
// in `speech-catalog/` (the repository's `catalog/`), the same way
// `CTranscribe.framework` and `speech-mlx` travel with it, and a user's own
// documents in `~/Library/Application Support/Speech/Catalog` add models or
// replace built-in ones. Nothing here is a SwiftPM resource: `Bundle.module`
// traps rather than returning nil when its bundle is missing.
//
// A document is `{"schema": 1, "note": "...", "models": [...]}`. Each model
// entry is one model of one engine, with its variants beneath it; a variant
// inherits every field it does not set. The engine-specific fields are all
// here, as optionals, rather than behind a plug-in mechanism: there are four
// engines, their fields do not collide, and each engine's catalog reads only
// the ones it needs and reports the ones it needs and did not get.
//
// Decoding is strict, because these files are hand-edited. An unknown key is an
// error for the entry that carries it - `"langauges"` silently ignored would be
// a model that claims every language - and one bad entry is dropped with a
// message naming its file, never the whole catalog. A missing or unreadable
// built-in catalog is the one fatal case, and the executable reports it.

import Foundation

/// One variant of a catalog model: the part of an id after the `@`, and every
/// field that differs between builds of the same model.
public struct CatalogVariant: Sendable, Equatable, Codable {
    /// nil for a model that has no variants, whose id carries no `@`.
    public var variant: String?
    public var source: String?
    public var file: String?
    public var parametersM: Int?
    public var precision: String?
    public var sizeBytes: Int64?
    public var label: String?
    public var hidden: Bool?
    public var note: String?

    public init(
        variant: String?, source: String? = nil, file: String? = nil, parametersM: Int? = nil,
        precision: String? = nil, sizeBytes: Int64? = nil, label: String? = nil,
        hidden: Bool? = nil, note: String? = nil
    ) {
        self.variant = variant
        self.source = source
        self.file = file
        self.parametersM = parametersM
        self.precision = precision
        self.sizeBytes = sizeBytes
        self.label = label
        self.hidden = hidden
        self.note = note
    }

    enum Key: String, CodingKey, CaseIterable {
        case variant, source, file, precision, label, hidden, note
        case parametersM = "params_m"
        case sizeBytes = "size_bytes"
    }

    public init(from decoder: Decoder) throws {
        try CatalogDecoding.rejectUnknownKeys(decoder, known: Key.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: Key.self)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        parametersM = try c.decodeIfPresent(Int.self, forKey: .parametersM)
        precision = try c.decodeIfPresent(String.self, forKey: .precision)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// Absent fields are left out rather than written as null, so a file this
    /// program writes reads like one a person wrote.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encodeIfPresent(variant, forKey: .variant)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encodeIfPresent(parametersM, forKey: .parametersM)
        try c.encodeIfPresent(precision, forKey: .precision)
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(hidden, forKey: .hidden)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

/// How a `ggml` model's streaming decoder is driven: which transcribe.cpp
/// stream extension to pass, and its settings.
///
/// Data rather than code because the right values are measurements of one
/// model, not properties of a family - `nemotron-3.5-asr-streaming-0.6b` works
/// only with `att_context_right` 0, and the library's own default returns an
/// empty transcript while reporting success. An entry without this keeps the
/// engine's built-in choice (see `GGMLEngine.streamExtension`).
public struct CatalogStream: Sendable, Equatable, Codable {
    /// `none`, `parakeet_buffered`, `parakeet_stream` or `voxtral_realtime`.
    public var kind: String
    /// `parakeet_stream`.
    public var attContextRight: Int32?
    /// `parakeet_buffered`, in milliseconds.
    public var leftMs: Int32?
    public var chunkMs: Int32?
    public var rightMs: Int32?
    /// `voxtral_realtime`.
    public var numDelayTokens: Int32?
    public var minDecodeIntervalMs: Int32?

    public init(
        kind: String, attContextRight: Int32? = nil, leftMs: Int32? = nil, chunkMs: Int32? = nil,
        rightMs: Int32? = nil, numDelayTokens: Int32? = nil, minDecodeIntervalMs: Int32? = nil
    ) {
        self.kind = kind
        self.attContextRight = attContextRight
        self.leftMs = leftMs
        self.chunkMs = chunkMs
        self.rightMs = rightMs
        self.numDelayTokens = numDelayTokens
        self.minDecodeIntervalMs = minDecodeIntervalMs
    }

    enum Key: String, CodingKey, CaseIterable {
        case kind
        case attContextRight = "att_context_right"
        case leftMs = "left_ms"
        case chunkMs = "chunk_ms"
        case rightMs = "right_ms"
        case numDelayTokens = "num_delay_tokens"
        case minDecodeIntervalMs = "min_decode_interval_ms"
    }

    /// The settings each kind takes. A setting given to the wrong kind would
    /// otherwise be silently ignored, which is the failure this whole format is
    /// strict about.
    public static let settings: [String: Set<String>] = [
        "none": [],
        "parakeet_buffered": ["left_ms", "chunk_ms", "right_ms"],
        "parakeet_stream": ["att_context_right"],
        "voxtral_realtime": ["num_delay_tokens", "min_decode_interval_ms"],
    ]

    public init(from decoder: Decoder) throws {
        try CatalogDecoding.rejectUnknownKeys(decoder, known: Key.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: Key.self)
        kind = try c.decode(String.self, forKey: .kind)
        attContextRight = try c.decodeIfPresent(Int32.self, forKey: .attContextRight)
        leftMs = try c.decodeIfPresent(Int32.self, forKey: .leftMs)
        chunkMs = try c.decodeIfPresent(Int32.self, forKey: .chunkMs)
        rightMs = try c.decodeIfPresent(Int32.self, forKey: .rightMs)
        numDelayTokens = try c.decodeIfPresent(Int32.self, forKey: .numDelayTokens)
        minDecodeIntervalMs = try c.decodeIfPresent(Int32.self, forKey: .minDecodeIntervalMs)
        guard let allowed = Self.settings[kind] else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown stream kind '\(kind)'"
                    + " (want \(Self.settings.keys.sorted().joined(separator: ", ")))")
        }
        let given = c.allKeys.map(\.stringValue).filter { $0 != "kind" }
        if let stray = given.sorted().first(where: { !allowed.contains($0) }) {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "'\(stray)' is not a setting of stream kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(attContextRight, forKey: .attContextRight)
        try c.encodeIfPresent(leftMs, forKey: .leftMs)
        try c.encodeIfPresent(chunkMs, forKey: .chunkMs)
        try c.encodeIfPresent(rightMs, forKey: .rightMs)
        try c.encodeIfPresent(numDelayTokens, forKey: .numDelayTokens)
        try c.encodeIfPresent(minDecodeIntervalMs, forKey: .minDecodeIntervalMs)
    }
}

/// One model entry: an engine, a model name, what family it is a build of, and
/// its variants. Fields set here apply to every variant that does not set its
/// own.
public struct CatalogModel: Sendable, Equatable, Codable {
    public var engine: String
    public var model: String
    public var family: CatalogFamily
    public var role: CatalogRole
    /// Unlisted: absent from `speech catalog` and `speech engines`, but an id
    /// typed in full still builds, downloads and runs.
    public var hidden: Bool
    /// Free text for the reader of the file. The program never interprets it;
    /// it is where the reasons behind a number live now that the numbers are
    /// not in Swift comments.
    public var note: String?

    // Inherited by variants.
    public var source: String?
    public var file: String?
    public var parametersM: Int?
    public var precision: String?
    public var sizeBytes: Int64?
    public var label: String?

    // What the model can do, as far as the catalog can say before a download.
    // Advisory for every engine: the loaded model's own answers gate.
    public var languages: [String]?
    public var languageID: Bool?
    public var streaming: Bool?
    public var wordTimestamps: Bool?
    public var segmentTimestamps: Bool?

    // mlx: the helper's architecture name, the files to fetch from `source`,
    // files from other repositories, and the two audio limits.
    public var type: String?
    public var files: [String]?
    public var filesFrom: [String: [String]]?
    public var chunkSeconds: Double?
    public var maxSeconds: Double?

    // ggml: how the streaming decoder is driven, when the engine's own choice
    // is not the right one for this model.
    public var stream: CatalogStream?

    /// nil means one implicit variant with no name.
    public var variants: [CatalogVariant]?

    public init(
        engine: String, model: String, family: CatalogFamily, role: CatalogRole = .transcriber,
        hidden: Bool = false, note: String? = nil, source: String? = nil, file: String? = nil,
        parametersM: Int? = nil, precision: String? = nil, sizeBytes: Int64? = nil,
        label: String? = nil, languages: [String]? = nil, languageID: Bool? = nil,
        streaming: Bool? = nil, wordTimestamps: Bool? = nil, segmentTimestamps: Bool? = nil,
        type: String? = nil, files: [String]? = nil, filesFrom: [String: [String]]? = nil,
        chunkSeconds: Double? = nil, maxSeconds: Double? = nil, stream: CatalogStream? = nil,
        variants: [CatalogVariant]? = nil
    ) {
        self.engine = engine
        self.model = model
        self.family = family
        self.role = role
        self.hidden = hidden
        self.note = note
        self.source = source
        self.file = file
        self.parametersM = parametersM
        self.precision = precision
        self.sizeBytes = sizeBytes
        self.label = label
        self.languages = languages
        self.languageID = languageID
        self.streaming = streaming
        self.wordTimestamps = wordTimestamps
        self.segmentTimestamps = segmentTimestamps
        self.type = type
        self.files = files
        self.filesFrom = filesFrom
        self.chunkSeconds = chunkSeconds
        self.maxSeconds = maxSeconds
        self.stream = stream
        self.variants = variants
    }

    enum Key: String, CodingKey, CaseIterable {
        case engine, model, family, role, hidden, note, source, file, precision, label
        case languages, streaming, type, files, stream, variants
        case parametersM = "params_m"
        case sizeBytes = "size_bytes"
        case languageID = "language_id"
        case wordTimestamps = "word_timestamps"
        case segmentTimestamps = "segment_timestamps"
        case filesFrom = "files_from"
        case chunkSeconds = "chunk_seconds"
        case maxSeconds = "max_seconds"
    }

    public init(from decoder: Decoder) throws {
        try CatalogDecoding.rejectUnknownKeys(decoder, known: Key.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: Key.self)
        engine = try c.decode(String.self, forKey: .engine)
        model = try c.decode(String.self, forKey: .model)
        family = try c.decode(CatalogFamily.self, forKey: .family)
        role = try c.decodeIfPresent(CatalogRole.self, forKey: .role) ?? .transcriber
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        parametersM = try c.decodeIfPresent(Int.self, forKey: .parametersM)
        precision = try c.decodeIfPresent(String.self, forKey: .precision)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        languages = try c.decodeIfPresent([String].self, forKey: .languages)
        languageID = try c.decodeIfPresent(Bool.self, forKey: .languageID)
        streaming = try c.decodeIfPresent(Bool.self, forKey: .streaming)
        wordTimestamps = try c.decodeIfPresent(Bool.self, forKey: .wordTimestamps)
        segmentTimestamps = try c.decodeIfPresent(Bool.self, forKey: .segmentTimestamps)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        files = try c.decodeIfPresent([String].self, forKey: .files)
        filesFrom = try c.decodeIfPresent([String: [String]].self, forKey: .filesFrom)
        chunkSeconds = try c.decodeIfPresent(Double.self, forKey: .chunkSeconds)
        maxSeconds = try c.decodeIfPresent(Double.self, forKey: .maxSeconds)
        stream = try c.decodeIfPresent(CatalogStream.self, forKey: .stream)
        variants = try c.decodeIfPresent([CatalogVariant].self, forKey: .variants)
    }

    /// Absent fields are left out, and `role` and `hidden` only when they are
    /// not the default, so a file this program writes reads like one a person
    /// wrote.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(engine, forKey: .engine)
        try c.encode(model, forKey: .model)
        try c.encode(family, forKey: .family)
        if role != .transcriber { try c.encode(role, forKey: .role) }
        if hidden { try c.encode(hidden, forKey: .hidden) }
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encodeIfPresent(parametersM, forKey: .parametersM)
        try c.encodeIfPresent(precision, forKey: .precision)
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(languages, forKey: .languages)
        try c.encodeIfPresent(languageID, forKey: .languageID)
        try c.encodeIfPresent(streaming, forKey: .streaming)
        try c.encodeIfPresent(wordTimestamps, forKey: .wordTimestamps)
        try c.encodeIfPresent(segmentTimestamps, forKey: .segmentTimestamps)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(files, forKey: .files)
        try c.encodeIfPresent(filesFrom, forKey: .filesFrom)
        try c.encodeIfPresent(chunkSeconds, forKey: .chunkSeconds)
        try c.encodeIfPresent(maxSeconds, forKey: .maxSeconds)
        try c.encodeIfPresent(stream, forKey: .stream)
        try c.encodeIfPresent(variants, forKey: .variants)
    }

    /// The engine and model, which is what a user entry replaces a built-in one
    /// by.
    public var key: String { "\(engine).\(model)" }

    /// The variants as declared, or the one implicit variant.
    public var declaredVariants: [CatalogVariant] {
        variants ?? [CatalogVariant(variant: nil)]
    }

    /// The catalog id of one variant of this model.
    public func id(variant: String?) -> String {
        variant.map { "\(key)@\($0)" } ?? key
    }

    /// The variant an id names, or nil when this model has no such variant.
    public func variant(named name: String?) -> CatalogVariant? {
        declaredVariants.first { $0.variant == name }
    }

    /// Whether one variant is unlisted, by itself or because its model is.
    public func isHidden(_ variant: CatalogVariant) -> Bool {
        hidden || variant.hidden == true
    }

    /// One variant as an inventory row, with the model's fields filled in
    /// wherever the variant does not set its own.
    public func row(_ variant: CatalogVariant) -> CatalogRow {
        CatalogRow(
            id: id(variant: variant.variant),
            family: family,
            role: role,
            source: variant.source ?? source,
            file: variant.file ?? file,
            parametersM: variant.parametersM ?? parametersM,
            precision: variant.precision ?? precision ?? "",
            sizeBytes: variant.sizeBytes ?? sizeBytes,
            label: variant.label ?? label ?? "")
    }

    /// What is wrong with this entry, or nil when nothing is. The checks every
    /// engine shares; each engine's own catalog adds the fields it needs.
    func problem() -> String? {
        guard Self.isName(engine) else { return "engine '\(engine)' is not a plain lowercase name" }
        guard Self.isName(model) else {
            return "model '\(model)' must be lowercase letters, digits, '.', '_' and '-'"
        }
        guard Self.isName(family.rawValue) else {
            return "family '\(family.rawValue)' must be lowercase letters, digits, '.', '_' and '-'"
        }
        if let variants, variants.isEmpty { return "'variants' is empty; leave it out instead" }
        // Strings that end up in the TSV export, in an HF request or as a file
        // name. The TSV writer refuses a tab or newline anyway, but as an error
        // about one row at export time rather than a warning about one entry at
        // load time.
        let strings = (languages ?? []) + [type ?? ""] + (files ?? [])
            + (filesFrom ?? [:]).flatMap { [$0.key] + $0.value }
        if strings.contains(where: Self.hasControlCharacter) {
            return "a language, type or file name contains a control character"
        }
        var seen: Set<String?> = []
        for variant in declaredVariants {
            if let name = variant.variant, !Self.isName(name) {
                return "variant '\(name)' must be lowercase letters, digits, '.', '_' and '-'"
            }
            if variants != nil, variant.variant == nil {
                return "a variant in 'variants' has no 'variant' name"
            }
            guard seen.insert(variant.variant).inserted else {
                return "variant '\(variant.variant ?? "")' is listed twice"
            }
            let row = row(variant)
            do {
                _ = try EngineSpec.parse(catalogID: row.id, modelsDirectory: URL(fileURLWithPath: "/"))
            } catch let error as SpeechError {
                return error.message
            } catch {
                return "\(error)"
            }
            if row.precision.isEmpty { return "\(row.id) has no 'precision'" }
            if row.label.isEmpty { return "\(row.id) has no 'label'" }
            for (name, text) in [("label", row.label), ("precision", row.precision),
                                 ("source", row.source ?? ""), ("file", row.file ?? "")]
            where Self.hasControlCharacter(text) {
                return "\(row.id): '\(name)' contains a control character"
            }
            if let size = row.sizeBytes, size < 0 { return "\(row.id): 'size_bytes' is negative" }
            if let parameters = row.parametersM, parameters <= 0 {
                return "\(row.id): 'params_m' must be positive"
            }
        }
        return nil
    }

    static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// Lowercase letters, digits, `.`, `_` and `-`, starting with a letter or
    /// digit. Ids are path components in the model store and keys in every
    /// report, so the shape is fixed here rather than trusted.
    public static func isName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first,
              ("a"..."z").contains(first) || ("0"..."9").contains(first)
        else { return false }
        return text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }
}

/// A catalog document, one file.
struct CatalogDocument: Decodable {
    var schema: Int
    var note: String?
    /// Each entry decoded on its own, so one bad entry costs only itself.
    var models: [Result<CatalogModel, Error>]

    enum Key: String, CodingKey, CaseIterable { case schema, note, models }

    private struct Slot: Decodable {
        let result: Result<CatalogModel, Error>
        init(from decoder: Decoder) throws {
            result = Result { try CatalogModel(from: decoder) }
        }
    }

    init(from decoder: Decoder) throws {
        try CatalogDecoding.rejectUnknownKeys(decoder, known: Key.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: Key.self)
        schema = try c.decode(Int.self, forKey: .schema)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        models = try c.decode([Slot].self, forKey: .models).map(\.result)
    }
}

enum CatalogDecoding {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func rejectUnknownKeys(_ decoder: Decoder, known: [String]) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "unknown field\(unknown.count == 1 ? "" : "s")"
                    + " \(unknown.map { "'\($0)'" }.joined(separator: ", "))"))
        }
    }

    /// A decoding failure in words a person editing the file can act on:
    /// where it is and what is wrong, without Swift's type names.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "\(error)" }
        /// `models[1].variants[0]: `, the way the file reads.
        func path(_ codingPath: [CodingKey]) -> String {
            var out = ""
            for key in codingPath {
                if let index = key.intValue {
                    out += "[\(index)]"
                } else {
                    out += (out.isEmpty ? "" : ".") + key.stringValue
                }
            }
            return out.isEmpty ? "" : out + ": "
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context.codingPath))missing '\(key.stringValue)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(path(context.codingPath))wrong type (\(context.debugDescription))"
        case .dataCorrupted(let context):
            return "\(path(context.codingPath))\(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}

/// The merged catalog: every model entry that loaded, and what went wrong with
/// the ones that did not.
public struct LoadedCatalog: Sendable {
    /// Built-in files in name order, each file in its own order; a user entry
    /// that replaces a built-in one takes its place, and a new one is appended.
    public var models: [CatalogModel]
    /// Human-readable, each naming the file it came from.
    public var problems: [String]
    public var builtinDirectory: URL?
    public var userDirectory: URL?
    /// The file each model entry came from, by `<engine>.<model>`. What lets
    /// `speech models add` tell its own file apart from one a person wrote.
    public var origins: [String: URL]

    public init(
        models: [CatalogModel], problems: [String] = [],
        builtinDirectory: URL? = nil, userDirectory: URL? = nil, origins: [String: URL] = [:]
    ) {
        self.models = models
        self.problems = problems
        self.builtinDirectory = builtinDirectory
        self.userDirectory = userDirectory
        self.origins = origins
    }

    /// This catalog with one entry added, or replacing the entry of the same
    /// engine and model in place.
    public func replacing(_ model: CatalogModel, from origin: URL? = nil) -> LoadedCatalog {
        var copy = self
        if let index = copy.models.firstIndex(where: { $0.key == model.key }) {
            copy.models[index] = model
        } else {
            copy.models.append(model)
        }
        copy.origins[model.key] = origin
        return copy
    }

    /// A catalog document holding the given entries, as it would be written:
    /// pretty-printed with sorted keys, so the same entries always produce the
    /// same bytes, and ending with a newline.
    public static func documentData(models: [CatalogModel], note: String? = nil) throws -> Data {
        struct Document: Encodable {
            let schema = 1
            let note: String?
            let models: [CatalogModel]
            enum CodingKeys: String, CodingKey { case schema, note, models }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(schema, forKey: .schema)
                try c.encodeIfPresent(note, forKey: .note)
                try c.encode(models, forKey: .models)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Document(note: note, models: models))
        data.append(0x0A)
        return data
    }

    /// Reads the built-in directory, then a user directory over it.
    ///
    /// Throws only when the built-in catalog cannot be read at all, which is a
    /// packaging error. Everything else - a bad user file, a bad entry, a
    /// duplicate - is a problem on the list and the rest loads.
    public static func load(builtin: URL, user: URL? = nil) throws -> LoadedCatalog {
        let builtinFiles = try jsonFiles(in: builtin)
        guard !builtinFiles.isEmpty else {
            throw SpeechError.runtime("the built-in catalog at \(builtin.path) has no .json files")
        }
        var catalog = LoadedCatalog(models: [], builtinDirectory: builtin, userDirectory: user)
        var builtinKeys: Set<String> = []
        for file in builtinFiles {
            for model in catalog.read(file) {
                guard builtinKeys.insert(model.key).inserted else {
                    catalog.problems.append(
                        "\(file.lastPathComponent): '\(model.key)' is defined twice in the built-in catalog;"
                        + " the first one is kept")
                    continue
                }
                catalog.models.append(model)
                catalog.origins[model.key] = file
            }
        }
        guard !catalog.models.isEmpty else {
            throw SpeechError.runtime(
                "the built-in catalog at \(builtin.path) loaded no models: "
                + catalog.problems.joined(separator: "; "))
        }

        guard let user, FileManager.default.fileExists(atPath: user.path) else { return catalog }
        let userFiles: [URL]
        do {
            userFiles = try jsonFiles(in: user)
        } catch {
            catalog.problems.append("cannot read the user catalog at \(user.path): \(error)")
            return catalog
        }
        var userKeys: [String: String] = [:]
        for file in userFiles {
            for model in catalog.read(file) {
                if let earlier = userKeys[model.key] {
                    catalog.problems.append(
                        "\(file.lastPathComponent): '\(model.key)' is also defined in \(earlier);"
                        + " this one, later by name, is used")
                }
                userKeys[model.key] = file.lastPathComponent
                catalog = catalog.replacing(model, from: file)
            }
        }
        return catalog
    }

    /// The valid entries of one file; everything else becomes a problem.
    private mutating func read(_ file: URL) -> [CatalogModel] {
        let name = file.lastPathComponent
        let document: CatalogDocument
        do {
            let data = try Data(contentsOf: file)
            document = try JSONDecoder().decode(CatalogDocument.self, from: data)
        } catch {
            problems.append("\(name): \(CatalogDecoding.describe(error)); the whole file is skipped")
            return []
        }
        guard document.schema == 1 else {
            problems.append("\(name): schema \(document.schema) is not one this build reads (1);"
                + " the whole file is skipped")
            return []
        }
        var out: [CatalogModel] = []
        for (index, slot) in document.models.enumerated() {
            switch slot {
            case .failure(let error):
                // The decoding error carries its own path, `models[n]...`,
                // except when it is about the entry as a whole.
                let description = CatalogDecoding.describe(error)
                problems.append(description.hasPrefix("models[")
                    ? "\(name): \(description)"
                    : "\(name): models[\(index)]: \(description)")
            case .success(let model):
                if let problem = model.problem() {
                    problems.append("\(name): \(model.key): \(problem)")
                } else {
                    out.append(model)
                }
            }
        }
        return out
    }

    /// `*.json` directly inside a directory, sorted by name so the merge order
    /// is the same on every run. Hidden files are skipped: an editor's
    /// `.foo.json.swp` sibling is not a catalog.
    private static func jsonFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                 options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
