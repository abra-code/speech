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
    /// Lowest macOS this engine runs on, as a version string ("15.0", "26.0").
    ///
    /// Never below the binary's own deployment target, which is macOS 15: a row
    /// that named an older system would be describing something this build
    /// cannot run anyway, and the applet would render a floor the user could
    /// never satisfy by upgrading a model.
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
        minimumMacOS: String = "15.0"
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

    /// Whether the running OS is new enough for this engine, by comparing
    /// `minimumMacOS` against the system version.
    ///
    /// Lives here so that every row gets the answer for free rather than each
    /// verb re-deriving it. Without it `speech engines` reported
    /// `fluid.canary-1b-v2@int4` as available on macOS 14 - `minimum_macos`
    /// was in the JSON and nowhere else - and `models download` would then
    /// fetch 569 MB of int4 weights that machine could never load. The floor is
    /// macOS 15 now, so that particular row can no longer be the one that
    /// trips this, but the Apple rows need macOS 26 and always will.
    ///
    /// Parses leniently: an unreadable version string reads as "supported",
    /// because refusing to run over a typo in a catalog field is worse than
    /// running.
    public var runsOnThisOS: Bool {
        let parts = minimumMacOS.split(separator: ".").map { Int($0) ?? 0 }
        guard !parts.isEmpty else { return true }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(
                majorVersion: parts[0],
                minorVersion: parts.count > 1 ? parts[1] : 0,
                patchVersion: parts.count > 2 ? parts[2] : 0))
    }

    /// The mode tokens for this row: which of `batch` and `live` it can do.
    /// Split out from the feature flags because the catalog file gives "what it
    /// can do" and "how you can drive it" separate columns.
    public var modeFlags: [String] {
        var flags: [String] = []
        if batch { flags.append("batch") }
        if live { flags.append("live") }
        return flags
    }

    /// The feature tokens for this row, in the fixed order the docs list them.
    /// These names are published - they appear in `speech engines --json`, in
    /// the catalog file and in the applet's chooser - so adding one is an
    /// additive change and renaming one is a breaking change.
    public var featureFlags: [String] {
        var flags: [String] = []
        if wordTimestamps { flags.append("word_ts") }
        if segmentTimestamps { flags.append("seg_ts") }
        if vocabulary { flags.append("vocab") }
        if diarization { flags.append("diarize") }
        if languageID { flags.append("lang_id") }
        if languageHint { flags.append("lang_hint") }
        return flags
    }

    /// Modes and features together, which is what `speech engines` prints.
    public var allFlags: [String] { modeFlags + featureFlags }

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
    /// Where a live session's utterance boundaries come from.
    ///
    /// Live only. A batch `transcribe` ignores it, and that is not an oversight
    /// worth designing around: the question is "when has this speaker finished
    /// a thought", which only exists while audio is still arriving. It rides
    /// here rather than on `makeLiveSession` because every engine already
    /// receives these options and none of them has to grow a parameter for a
    /// choice most of them pass straight through.
    public var segmentation: LiveSegmentation

    public init(
        language: String? = nil,
        vocabulary: [String] = [],
        wantWordTimestamps: Bool = true,
        segmentation: LiveSegmentation = .engine
    ) {
        self.language = language
        self.vocabulary = vocabulary
        self.wantWordTimestamps = wantWordTimestamps
        self.segmentation = segmentation
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

/// Where a live session's utterance boundaries come from.
///
/// A run-level choice rather than a property of a row, because it is the same
/// question for every engine: cut where the model thinks a sentence ended, or
/// cut where the room went quiet. Batch transcription ignores it - a file is
/// segmented by the engine's own decoder, and nothing here is on that path.
public enum LiveSegmentation: String, Sendable, Equatable, CaseIterable {
    /// Whatever the engine or the mapping over it decides. The default,
    /// because it needs no second model on disk.
    case engine
    /// Boundaries marked by a voice activity detector, on the audio's clock.
    case vad
}

public enum LiveEvent: Sendable {
    /// Volatile text that will be replaced. Same id as the final that follows.
    case partial(Segment)
    case final(Segment)
}

/// A live session that failed while it still had a usable transcript.
///
/// It exists because the obvious alternative loses work. `finish()` is where a
/// session both finalizes and reports, and a plain `throw` there discards
/// everything the run produced: a twenty-minute dictation whose analyzer failed
/// on the very last flush would come back as zero segments, and `done` would
/// say `segments: 0` for a transcript the user had already watched appear.
///
/// So the failure travels *with* the work. A caller that only wants the error
/// gets one; a caller that wants the transcript keeps it and reports the
/// failure as a warning, which is what `speech stream` does.
public struct LiveSessionFailure: Error, Sendable {
    public var segments: [Segment]
    public var message: String

    public init(segments: [Segment], message: String) {
        self.segments = segments
        self.message = message
    }
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

    /// How the model store should judge whether this engine's weights are
    /// present in a row directory. nil means the OS owns them and there is
    /// nothing on disk here to inspect, count or delete - Apple's locale
    /// assets, which `models list` reports as `system_managed`.
    ///
    /// This is the engine's half of the store's contract: the store owns
    /// placement and interruption, the engine owns "are these the right
    /// files", and neither keeps a table of the other's facts.
    nonisolated var completenessCheck: ModelCompletenessCheck? { get }

    /// Check what can be checked about a request before any audio is decoded.
    ///
    /// Exists because the expensive work comes first otherwise. Custom
    /// vocabulary needs a second model in the store, and whether that row is
    /// present is a filesystem question with no dependence on the audio, the
    /// decode or the loaded weights - but the engine only sees the terms when
    /// `transcribe` is called, by which point an hour of audio has been decoded
    /// and a gigabyte of weights loaded. Discovering there that the answer was
    /// "install another model first" throws all of it away.
    ///
    /// Cheap by contract: no downloads, no model loads, no audio. Throws the
    /// same errors `transcribe` would, so a caller that skips it gets the same
    /// outcome later rather than a different one.
    func validate(_ options: TranscribeOptions) async throws

    /// Fetch this row's weights into its directory.
    ///
    /// Separate from `prepare` on purpose. A FluidAudio row is one to three
    /// gigabytes; if preparing could download, then `speech transcribe` on a
    /// fresh machine would block for minutes on a fetch nobody agreed to, and
    /// an eval pointed at a mistyped id would quietly pull the wrong model.
    /// `prepare` therefore throws `modelMissing` and this is the only path
    /// that touches the network, reached only from `speech models download`.
    func install(progress: @escaping LoadProgressHandler) async throws

    /// Peak memory of a process this engine runs the model in, when that is not
    /// this one. nil for every engine whose model is in this address space,
    /// which is all of them but `mlx`.
    ///
    /// Reported ADDED to this process's own peak, because both processes are
    /// resident at the same time and the question the figure answers is what
    /// the run needed. Without it an out-of-process engine reports the parent's
    /// footprint, which is a real measurement of the wrong thing: measured at
    /// 18 MB for a run holding a 459 MB model in the helper.
    ///
    /// Sampled while the helper is alive rather than at the end: the kernel
    /// keeps no ledger for a process that has exited.
    func peakOutOfProcessMemoryBytes() async -> Int64?
}

extension TranscriptionEngine {
    /// Engines that ship no weights of their own need not implement these.
    public nonisolated var completenessCheck: ModelCompletenessCheck? { nil }

    /// Nothing to check ahead of time is the common case.
    public func validate(_ options: TranscribeOptions) async throws {}

    public func peakOutOfProcessMemoryBytes() async -> Int64? { nil }

    public func install(progress: @escaping LoadProgressHandler) async throws {
        throw SpeechError.usage("'\(id)' has no downloadable weights of its own")
    }
}

public protocol LiveSession: Sendable {
    /// Hand one capture buffer to the engine.
    ///
    /// The buffer arrives wrapped in `CapturedAudio` rather than as a `sending`
    /// parameter, and the difference is not cosmetic. `sending` describes a
    /// transfer the compiler can verify at one call site; this buffer is
    /// transferred twice - out of the audio thread, then out of the pump actor
    /// that converted it - and region isolation cannot follow it through an
    /// actor's storage. The wrapper states the contract once instead: whoever
    /// hands a `CapturedAudio` over holds no other reference to what is inside
    /// and will not touch it again.
    func feed(_ audio: CapturedAudio) async throws
    nonisolated var events: AsyncStream<LiveEvent> { get }
    /// Flush, close the stream, and return the final segment list.
    func finish() async throws -> [Segment]
    func cancel() async

    /// Tell the session where the audio said speech started or stopped.
    ///
    /// Called from the pump, on the same task that feeds it, so a boundary can
    /// never overtake the audio it was found in. It is a *report*, not a
    /// command: the session decides what to do with it, and every session is
    /// free to ignore it - which is what the default below does, and what the
    /// two rows whose segmentation belongs to the model itself actually do.
    ///
    /// A session that acts on boundaries says so in `honorsSpeechBoundaries`,
    /// so a run that asked for them and would get nothing is told rather than
    /// left to wonder why nothing changed.
    func mark(_ boundary: SpeechBoundary) async

    /// Whether marked boundaries reach this session's segmentation.
    nonisolated var honorsSpeechBoundaries: Bool { get }

    /// Buffers this session could not keep up with, read after `finish`.
    ///
    /// A session that queues audio for an engine has to bound that queue, and a
    /// bounded queue drops. Reporting it is the difference between a transcript
    /// with a hole in it and a transcript with a hole in it that nobody
    /// mentioned.
    func droppedInputCount() async -> Int

    /// The format this session wants `feed` to be handed, or nil for "whatever
    /// the microphone produces".
    ///
    /// It exists because the three engine families disagree and none of them
    /// can be talked out of it: Apple's analyzer insists on the format
    /// `SpeechAnalyzer.bestAvailableAudioFormat` names for its modules, ggml
    /// wants the project's canonical 16 kHz mono Float32, and FluidAudio's
    /// streaming managers resample internally and are better off with the
    /// hardware's own buffers than with audio resampled twice.
    ///
    /// Answering nil is not the same as answering `LiveAudioFormat.canonical`,
    /// and the difference is a real resampling pass over every buffer.
    nonisolated var preferredFormat: AVAudioFormat? { get }
}

extension LiveSession {
    /// Most sessions have no opinion. The ones that do say so explicitly.
    public nonisolated var preferredFormat: AVAudioFormat? { nil }

    /// A session that cannot drop audio reports none.
    public func droppedInputCount() async -> Int { 0 }

    /// Most sessions have their boundaries decided for them - by an analyzer
    /// that finalizes on its own schedule, or by a manager that emits one
    /// finished window at a time - and for those a boundary is information
    /// with nowhere to go.
    public func mark(_ boundary: SpeechBoundary) async {}
    public nonisolated var honorsSpeechBoundaries: Bool { false }
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
        // Every part becomes a path component in `directory`, and in stage 3
        // ids arrive from a catalog TSV rather than only from argv. Validate
        // here so a crafted or corrupt id cannot make `models delete` point at
        // a directory outside the store: "fluid.../../../Documents" parses into
        // a model of "../../../Documents" without this.
        for (label, part) in [("engine", engine), ("model", model)] + (variant.map { [("variant", $0)] } ?? []) {
            try validatePathComponent(part, label: label, catalogID: catalogID)
        }
        return EngineSpec(
            catalogID: catalogID, engine: engine, model: model,
            variant: variant, modelsDirectory: modelsDirectory)
    }

    /// Rejects anything that would not survive being used as a single path
    /// component. Dots inside a name are fine ("nemotron-3.5-asr"); a name that
    /// *is* a dot sequence, or that carries a separator, is not.
    private static func validatePathComponent(
        _ part: String, label: String, catalogID: String
    ) throws {
        let bad: String
        if part.contains("/") {
            bad = "contains '/'"
        } else if part.contains("\0") {
            bad = "contains a null byte"
        } else if part.allSatisfy({ $0 == "." }) {
            bad = "is a path traversal component"
        } else if part.hasPrefix(".") {
            bad = "starts with '.'"
        } else {
            return
        }
        throw SpeechError.usage("catalog id '\(catalogID)': the \(label) part '\(part)' \(bad)")
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
