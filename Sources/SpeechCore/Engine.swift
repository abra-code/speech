// Engine.swift - the protocol every backend implements, and the capability
// record that lets the catalog and the applet reason about a backend without
// importing it.
//
// The whole point of this file is that `speech` links Apple's Speech framework,
// FluidAudio's CoreML pipelines and (later) a ggml xcframework, and the command
// layer above must not know which is which. Anything an engine can do that
// another cannot is a flag in EngineCapabilities, never an `if id == "apple"`
// upstream.

import Foundation
import AVFoundation

/// What a backend can do. Serialized into the `engine.ready` event so the
/// applet can enable and disable controls without a second query.
public struct EngineCapabilities: Codable, Sendable, Equatable {
    /// Transcribes a whole file in one call.
    public var batch: Bool
    /// Accepts a live microphone stream and emits partials.
    public var live: Bool
    public var wordTimestamps: Bool
    public var segmentTimestamps: Bool
    /// Accepts hotwords / contextual strings that bias recognition.
    public var vocabulary: Bool
    public var diarization: Bool
    /// Detects the spoken language on its own.
    public var languageID: Bool
    /// Accepts a language hint. Some engines (Canary, Nemotron) require one.
    public var languageHint: Bool
    /// BCP-47 primary subtags. Empty means "any language" (Whisper's `*`).
    public var languages: [String]
    /// Lowest macOS this engine runs on, as a version string ("14.0", "26.0").
    public var minimumMacOS: String

    public init(
        batch: Bool = true,
        live: Bool = false,
        wordTimestamps: Bool = false,
        segmentTimestamps: Bool = false,
        vocabulary: Bool = false,
        diarization: Bool = false,
        languageID: Bool = false,
        languageHint: Bool = false,
        languages: [String] = [],
        minimumMacOS: String = "14.0"
    ) {
        self.batch = batch
        self.live = live
        self.wordTimestamps = wordTimestamps
        self.segmentTimestamps = segmentTimestamps
        self.vocabulary = vocabulary
        self.diarization = diarization
        self.languageID = languageID
        self.languageHint = languageHint
        self.languages = languages
        self.minimumMacOS = minimumMacOS
    }

    private enum CodingKeys: String, CodingKey {
        case batch, live
        case wordTimestamps = "word_timestamps"
        case segmentTimestamps = "segment_timestamps"
        case vocabulary, diarization
        case languageID = "language_id"
        case languageHint = "language_hint"
        case languages
        case minimumMacOS = "minimum_macos"
    }

    /// True when this engine claims the language, by primary subtag. An empty
    /// `languages` list means the engine takes anything.
    public func supports(language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }
        if languages.isEmpty { return true }
        let primary = Language.primarySubtag(language)
        return languages.contains { Language.primarySubtag($0) == primary }
    }
}

/// Per-request knobs. Everything here is a hint: an engine that cannot honor a
/// field ignores it and emits a `warning` event rather than failing, because a
/// transcript without hotword biasing still beats no transcript.
public struct TranscribeOptions: Sendable, Equatable {
    /// BCP-47 tag or bare primary subtag; nil means auto or engine default.
    public var language: String?
    /// Hotwords. Engines with `vocabulary == false` warn and continue.
    public var vocabulary: [String]
    public var wantWordTimestamps: Bool

    public init(language: String? = nil, vocabulary: [String] = [], wantWordTimestamps: Bool = true) {
        self.language = language
        self.vocabulary = vocabulary
        self.wantWordTimestamps = wantWordTimestamps
    }
}

/// Progress while an engine gets itself ready: downloading weights, compiling
/// CoreML, installing an Apple locale asset. The phases are exactly the four in
/// the `model.progress` event, so this struct maps one-to-one onto the wire and
/// no engine invents a fifth.
///
/// `compiling` covers every "the model is being made usable" step - CoreML's
/// first-run ANE compile, loading weights off disk, a warm-up pass. It exists
/// because that step takes seconds with no bytes moving, and silence there
/// reads as a hang.
public struct LoadProgress: Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case listing, downloading, compiling, installing
    }

    public var phase: Phase
    /// 0...1 when known. nil for phases with no measurable total.
    public var fraction: Double?
    public var bytesDone: Int64?
    public var bytesTotal: Int64?
    /// The file or model being worked on, for the status line.
    public var file: String?

    public init(
        phase: Phase,
        fraction: Double? = nil,
        bytesDone: Int64? = nil,
        bytesTotal: Int64? = nil,
        file: String? = nil
    ) {
        self.phase = phase
        self.fraction = fraction
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.file = file
    }
}

public typealias LoadProgressHandler = @Sendable (LoadProgress) -> Void

public enum LiveEvent: Sendable {
    /// Volatile text that will be replaced. Same id as the final that follows.
    case partial(Segment)
    case final(Segment)
}

/// A backend. `id` and `capabilities` are `nonisolated` so an actor-based
/// engine can answer them with stored `nonisolated let`s without a hop - the
/// command layer asks for capabilities before it has anything to await on.
public protocol TranscriptionEngine: Sendable {
    /// The catalog id this instance was built for ("apple.transcriber").
    nonisolated var id: String { get }
    nonisolated var capabilities: EngineCapabilities { get }

    /// Download, install, compile and warm up for `language`. Must be
    /// idempotent: calling it twice loads once. Throws `.unavailable` when the
    /// engine cannot run here.
    ///
    /// The language belongs here and not only in `transcribe` because for
    /// several engines it is a *load-time* fact, not a hint: Apple's locale
    /// assets are per language and can be a multi-minute download, Nemotron
    /// picks a prompt at load, Canary needs its prompt tokens. Without it,
    /// prepare would install one language and the first transcribe would
    /// quietly install another with nobody watching the progress.
    ///
    /// Returns the language the engine actually resolved to, when that is a
    /// more specific thing than what was asked for. A bare "de" lands on
    /// Apple's Austrian model and "es" on the US Spanish one, and a measurement
    /// that does not record which asset produced it is not reproducible.
    /// nil means the engine has nothing more specific to report.
    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String?

    /// 16 kHz mono Float32 in [-1, 1] - the format AudioDecoder produces, so
    /// every engine is measured on byte-identical audio.
    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment]

    /// Throws `.unavailable` when `capabilities.live` is false.
    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession

    /// Release weights and compute resources. Safe to call when not loaded.
    func unload() async
}

public protocol LiveSession: Sendable {
    /// Any format; the session resamples. `sending` because AVAudioPCMBuffer is
    /// a non-Sendable class and the buffer is handed over, not shared - the
    /// caller must not touch it again.
    func feed(_ buffer: sending AVAudioPCMBuffer) async throws
    nonisolated var events: AsyncStream<LiveEvent> { get }
    /// Flush, close the stream, and return the final segment list.
    func finish() async throws -> [Segment]
    func cancel() async
}

/// What the registry needs to build an engine: the catalog id split into its
/// parts, plus where model files live. In stage 3 the catalog row supplies
/// these; until then the executable parses them straight off the command line.
/// Keeping the seam here means the catalog can land without touching engines.
public struct EngineSpec: Sendable, Equatable {
    /// The full catalog id, `<engine>.<model>[@<variant>]`.
    public let catalogID: String
    /// The part before the first dot: "apple", "fluid", "ggml".
    public let engine: String
    /// Between the first dot and the `@`: "transcriber", "parakeet-v3".
    public let model: String
    /// After the `@`, nil when the id carries no variant.
    public let variant: String?
    public let modelsDirectory: URL

    public init(catalogID: String, engine: String, model: String, variant: String?, modelsDirectory: URL) {
        self.catalogID = catalogID
        self.engine = engine
        self.model = model
        self.variant = variant
        self.modelsDirectory = modelsDirectory
    }

    /// Parses `<engine>.<model>[@<variant>]`. The engine part is everything
    /// before the *first* dot and the model is the rest, so a model name may
    /// contain dots ("ggml.nemotron-3.5-asr@q8_0") without ambiguity.
    public static func parse(catalogID: String, modelsDirectory: URL) throws -> EngineSpec {
        let atSplit = catalogID.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = atSplit.first, !head.isEmpty else {
            throw SpeechError.usage("empty catalog id")
        }
        let variant: String?
        if atSplit.count == 2 {
            guard !atSplit[1].isEmpty else {
                throw SpeechError.usage("catalog id '\(catalogID)' ends with '@' but names no variant")
            }
            variant = String(atSplit[1])
        } else {
            variant = nil
        }
        guard let dot = head.firstIndex(of: ".") else {
            throw SpeechError.usage("catalog id '\(catalogID)' is not <engine>.<model>[@<variant>]")
        }
        let engine = String(head[head.startIndex..<dot])
        let model = String(head[head.index(after: dot)...])
        guard !engine.isEmpty, !model.isEmpty else {
            throw SpeechError.usage("catalog id '\(catalogID)' is not <engine>.<model>[@<variant>]")
        }
        return EngineSpec(
            catalogID: catalogID, engine: engine, model: model,
            variant: variant, modelsDirectory: modelsDirectory)
    }

    /// Where this row's files live: `<models-dir>/<engine>/<model>[@<variant>]`.
    /// Model files are under the app's own Application Support tree, never in a
    /// library's private cache, so `models list/delete/reveal` can see them.
    public var directory: URL {
        let leaf = variant.map { "\(model)@\($0)" } ?? model
        return modelsDirectory.appendingPathComponent(engine, isDirectory: true)
            .appendingPathComponent(leaf, isDirectory: true)
    }
}

/// Maps an engine prefix to a factory. The executable registers the engines it
/// was linked with; a build without SpeechFluid simply has no "fluid" entry and
/// reports `unavailable` for those ids, rather than failing to link.
public final class EngineRegistry: @unchecked Sendable {
    public typealias Factory = @Sendable (EngineSpec) throws -> any TranscriptionEngine

    private let lock = NSLock()
    private var factories: [String: Factory] = [:]

    public init() {}

    public func register(prefix: String, factory: @escaping Factory) {
        lock.lock()
        defer { lock.unlock() }
        factories[prefix] = factory
    }

    public var registeredPrefixes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return factories.keys.sorted()
    }

    public func make(_ spec: EngineSpec) throws -> any TranscriptionEngine {
        lock.lock()
        let factory = factories[spec.engine]
        lock.unlock()
        guard let factory else {
            throw SpeechError.unavailable(
                "no engine '\(spec.engine)' in this build (have: \(registeredPrefixes.joined(separator: ", ")))")
        }
        return try factory(spec)
    }

    public func make(catalogID: String, modelsDirectory: URL) throws -> any TranscriptionEngine {
        try make(EngineSpec.parse(catalogID: catalogID, modelsDirectory: modelsDirectory))
    }
}
