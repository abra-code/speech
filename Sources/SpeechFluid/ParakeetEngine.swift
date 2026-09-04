// ParakeetEngine.swift - `fluid.parakeet-v3`, the row the whole catalog
// argument rests on.
//
// This is the first engine that owns files. Apple's assets are installed by the
// OS and measured in "is the locale there"; a Parakeet row is a directory of
// CoreML packages this program downloaded, can size, and will delete when asked.
// So the engine is written against the model store rather than against a cache
// path of its own, and the one thing it must never do is fetch weights as a
// side effect - see `prepare` below.

import AVFoundation
import Foundation
import FluidAudio
import SpeechCore

/// The Parakeet flavors the catalog exposes. The encoder precision is the
/// variant after the `@`, and it changes both the file layout on disk and the
/// accuracy, so it is part of the row identity rather than a runtime flag.
enum ParakeetFlavor: Sendable {
    case v3(ParakeetEncoderPrecision)

    var version: AsrModelVersion {
        switch self {
        case .v3: return .v3
        }
    }

    var precision: ParakeetEncoderPrecision {
        switch self {
        case .v3(let precision): return precision
        }
    }

    /// Parse `<model>[@<variant>]` as the catalog splits it. An unknown variant
    /// is a usage error naming what is available, because the alternative is a
    /// download of the wrong precision that only reveals itself as a worse WER.
    static func parse(model: String, variant: String?) throws -> ParakeetFlavor {
        guard model == "parakeet-v3" else {
            throw SpeechError.usage("unknown FluidAudio model '\(model)'")
        }
        switch variant {
        // int8 is the default precision in FluidAudio and the row the plan
        // measures first, so a bare `fluid.parakeet-v3` means int8 rather than
        // being rejected.
        case nil, "int8": return .v3(.int8)
        case "int4": return .v3(.int4)
        default:
            throw SpeechError.usage(
                "unknown variant '@\(variant ?? "")' for parakeet-v3 (want @int8 or @int4)")
        }
    }
}

actor ParakeetEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities
    /// Non-optional here; optional only in the protocol, for engines whose
    /// weights the OS owns. Storing it this way removes two force-unwraps.
    private nonisolated let check: ModelCompletenessCheck
    nonisolated var completenessCheck: ModelCompletenessCheck? { check }

    private let spec: EngineSpec
    private let flavor: ParakeetFlavor
    private let store: ModelStore
    /// nil until `prepare` loads the weights. Holding the manager rather than
    /// the models keeps the ANE-compiled state warm across an eval run's 758
    /// calls, which is the difference between measuring the model and measuring
    /// CoreML's loader.
    private var manager: AsrManager?
    /// The in-flight `prepare`, so two concurrent callers load once. The
    /// protocol requires idempotence and the CLI happens to be sequential, but
    /// a UI is not: without this both callers pass the `manager != nil` check,
    /// both load, and one manager is orphaned holding its CoreML allocations.
    ///
    /// Two consequences of using an unstructured Task, both accepted for now
    /// and both worth fixing before live mode in stage 4. Cancelling the caller
    /// no longer cancels the load - `await task.value` is not a cancellation
    /// point - so Ctrl-C during the first ANE compile waits it out, which was
    /// measured at 11.7 s on the real model. And a second caller that joins an
    /// in-flight load never sees its own `progress:` closure fire, because only
    /// the first caller's handler is wired to FluidAudio.
    private var loading: Task<Void, Error>?

    init(spec: EngineSpec, flavor: ParakeetFlavor) {
        self.spec = spec
        self.flavor = flavor
        self.id = spec.catalogID
        self.store = ModelStore(root: spec.modelsDirectory)
        self.check = FluidModelFiles.parakeet(
            version: flavor.version, precision: flavor.precision)
        // Before anything can call load(): FluidAudio downloads from paths that
        // look like pure loads, and one of them deletes the row first.
        FluidNetwork.denyByDefault()
        self.capabilities = EngineCapabilities(
            batch: true,
            // Live arrives in stage 4 through SlidingWindowAsrManager. Claiming
            // it here would let the applet enable a Record button that throws.
            live: false,
            wordTimestamps: true,
            segmentTimestamps: true,
            // Vocabulary boosting needs the CTC spotter row (fluid.parakeet-ctc-110m)
            // as a second download. Until that lands, the honest answer is
            // false, so `transcribe --vocabulary` warns and continues instead
            // of silently ignoring the terms.
            vocabulary: false,
            diarization: false,
            languageID: false,
            languageHint: true,
            languages: FluidLanguage.parakeetLanguages,
            // FluidAudio itself would run this family on macOS 14 - there is
            // not one OS gate in its Parakeet or Nemotron sources - but the
            // binary's floor is 15, so 14 is not a system this row can be
            // reached on and claiming it would be a floor nobody can act on.
            minimumMacOS: "15.0")
    }

    // MARK: - Lifecycle

    /// Loads already-downloaded weights. Deliberately does not fetch anything.
    ///
    /// A Parakeet row is between one and three gigabytes. If `prepare` fell
    /// back to downloading, then `speech transcribe` on a fresh machine would
    /// block for minutes with no one having agreed to it, and an eval run
    /// pointed at the wrong id would do it silently. So a missing row is
    /// `modelMissing` - exit 3, carrying the catalog id - and `speech models
    /// download` is the one place that fetches.
    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        if manager != nil { return nil }
        if let loading {
            try await loading.value
            return nil
        }
        let task = Task { try await load(progress: progress) }
        loading = task
        defer { loading = nil }
        try await task.value
        return nil
    }

    private func load(progress: @escaping LoadProgressHandler) async throws {
        let directory = try store.directory(for: spec)
        switch try store.state(of: spec, isComplete: check) {
        case .installed:
            break
        case .partial:
            throw SpeechError.modelMissing(
                "'\(id)' is only partially downloaded; run 'speech models download \(id)' to finish it")
        case .missing, .systemManaged, .unknown:
            // .unknown cannot arise here - this engine always supplies a
            // completeness check, so the store never has to say "I cannot
            // judge these files" - but it is a store-level state and treating
            // it as anything other than "not usable" would be a guess.
            throw SpeechError.modelMissing(
                "'\(id)' is not installed; run 'speech models download \(id)'")
        }

        let models: AsrModels
        do {
            models = try await AsrModels.load(
                from: FluidPaths.parakeetRepo(in: directory, version: flavor.version),
                version: flavor.version,
                encoderPrecision: flavor.precision,
                progressHandler: FluidProgress.handler(.loading, progress))
        } catch {
            throw SpeechError.runtime(
                "cannot load '\(id)' from \(directory.path): \(error.localizedDescription)")
        }

        let manager = AsrManager(config: .default)
        do {
            try await manager.loadModels(models)
        } catch {
            throw SpeechError.runtime("cannot initialize '\(id)': \(error.localizedDescription)")
        }
        self.manager = manager
    }

    /// Fetches the weights. Only `speech models download` calls this.
    func install(progress: @escaping LoadProgressHandler) async throws {
        let directory = try store.beginInstall(spec)
        FluidNetwork.allowDownloads()
        defer { FluidNetwork.denyByDefault() }
        do {
            _ = try await AsrModels.download(
                to: FluidPaths.parakeetRepo(in: directory, version: flavor.version),
                version: flavor.version,
                encoderPrecision: flavor.precision,
                progressHandler: FluidProgress.handler(.installing, progress))
        } catch {
            // The partial marker stays: the directory holds whatever arrived,
            // and the next attempt resumes rather than starting from zero.
            throw SpeechError.runtime("downloading '\(id)' failed: \(error.localizedDescription)")
        }
        try store.finishInstall(spec, isComplete: check)
    }

    func unload() async {
        // cleanup() also drops FluidAudio's process-global MLMultiArray cache,
        // which is prewarmed with 15-second buffers and owned by no manager
        // instance, so releasing the manager alone never reclaims it. Moot for
        // a CLI that exits; load-bearing for Speech.app, where unload exists
        // precisely to give the memory back.
        await manager?.cleanup()
        manager = nil
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        guard let manager else {
            throw SpeechError.runtime("'\(id)': prepare() was not called")
        }
        guard !samples.isEmpty else { return [] }

        let language = FluidLanguage.parakeet(options.language)
        // A fresh decoder state per call. Reusing one across unrelated files
        // would carry the previous file's transducer context into the next,
        // which shows up as the first words of an utterance being conditioned
        // on the end of the one before it.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)

        let result: ASRResult
        do {
            result = try await manager.transcribe(samples, decoderState: &state, language: language)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime("'\(id)' failed to transcribe: \(error.localizedDescription)")
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let duration = Double(samples.count) / 16000.0
        let words = Self.words(from: result.tokenTimings, wanted: options.wantWordTimestamps)
        return [
            Segment(
                id: 0,
                start: words?.first?.start ?? 0,
                end: words?.last?.end ?? duration,
                text: text,
                words: words,
                confidence: result.confidence,
                language: options.language.map(SpeechCore.Language.primarySubtag))
        ]
    }

    /// Token timings to words. FluidAudio's `buildWordTimings` does the
    /// subword-to-word joining; this only drops the result when the caller did
    /// not ask for timings, and returns nil rather than [] when there are none,
    /// because an empty array claims "this segment has no words".
    private static func words(from timings: [TokenTiming]?, wanted: Bool) -> [Word]? {
        guard wanted, let timings, !timings.isEmpty else { return nil }
        let built = buildWordTimings(from: timings)
        guard !built.isEmpty else { return nil }
        return built.map { Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        throw SpeechError.unavailable(
            "'\(id)' has no live mode in this build (arrives in stage 4)")
    }
}
