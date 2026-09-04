// UnifiedEngine.swift - `fluid.parakeet-unified@int8` and `@fp16`, the
// English-only row, and the last of stage 1's four FluidAudio families.
//
// Parakeet Unified is one set of weights serving both a 15 s full-attention
// offline encoder and a chunked streaming encoder, which is what makes it
// interesting for stage 4: the live path will be the same download, not a
// second model. This file wires the offline half.
//
// It is the best-behaved family in the package. Its downloader validates what
// it fetched instead of testing for paths, purges and re-fetches a cache that
// fails to load, and refuses to do either when offline. Where Canary needed a
// hand-built repair and Nemotron needed a marker file deleted to unstick a
// retry, this one needs neither - so the engine below is mostly the shape the
// other three converged on, with the ceremony removed.

import AVFoundation
import Foundation
import FluidAudio
import SpeechCore

/// The encoder precisions the catalog exposes.
///
/// Both are published, which is worth stating because the last family's second
/// precision was not: `FluidInference/parakeet-unified-en-0.6b-coreml` ships
/// `parakeet_unified_encoder_int8.mlmodelc` and `parakeet_unified_encoder.mlmodelc`
/// side by side, verified against the repository listing rather than inferred
/// from the enum.
///
/// int8 is the default and FluidAudio measures it at the same accuracy for half
/// the size - LibriSpeech test-clean 1.83% against fp16's 1.82% - so `@fp16`
/// exists for the machines where the int8 encoder cannot build an execution
/// plan (their issue #828, seen on A-series) rather than as the quality option.
enum UnifiedFlavor: Sendable {
    case int8
    case fp16

    var precision: UnifiedEncoderPrecision {
        switch self {
        case .int8: return .int8
        case .fp16: return .fp16
        }
    }

    static func parse(model: String, variant: String?) throws -> UnifiedFlavor {
        guard model == "parakeet-unified" else {
            throw SpeechError.usage("unknown FluidAudio model '\(model)'")
        }
        switch variant {
        case nil, "int8": return .int8
        case "fp16": return .fp16
        default:
            throw SpeechError.usage(
                "unknown variant '@\(variant ?? "")' for parakeet-unified (want @int8 or @fp16)")
        }
    }
}

actor UnifiedEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities
    private nonisolated let check: ModelCompletenessCheck
    nonisolated var completenessCheck: ModelCompletenessCheck? { check }

    private let spec: EngineSpec
    private let flavor: UnifiedFlavor
    private let store: ModelStore

    private var manager: UnifiedAsrManager?
    private var loading: Task<Void, Error>?
    /// Bumped by `unload()`. A load that was in flight when the engine was
    /// unloaded compares this against the value it started with, so it can tell
    /// "I am still the current load" from "I was abandoned" - see `load`.
    private var epoch = 0
    /// The vocabulary booster, built on first use and kept while the term list
    /// is unchanged. See `booster(for:)` for why it is guarded rather than
    /// simply assigned.
    private var booster: VocabularyBooster?
    private var boosterTask: Task<VocabularyBooster, Error>?
    /// Bumped by `unload()`, so a booster load that outlives it is not cached.
    private var boosterEpoch = 0

    init(spec: EngineSpec, flavor: UnifiedFlavor) {
        self.spec = spec
        self.flavor = flavor
        self.id = spec.catalogID
        self.store = ModelStore(root: spec.modelsDirectory)
        self.check = FluidModelFiles.unified(precision: flavor.precision)
        FluidNetwork.denyByDefault()
        self.capabilities = EngineCapabilities(
            batch: true,
            // Stage 4, and the reason this row is worth having: the streaming
            // encoder is in the same download, so live mode here is a wiring
            // job rather than a second gigabyte.
            live: false,
            wordTimestamps: true,
            segmentTimestamps: true,
            // Through the CTC spotter row, driven by this engine rather than
            // by the manager's own `configureVocabularyBoosting`: that helper
            // resolves its tokenizer through FluidAudio's private cache
            // directory, which would put the spotter's weights outside the
            // model store. See `VocabularyBooster.load`.
            //
            // Measured on this row: three mangled proper nouns in one clip
            // corrected, with nothing else in the sentence touched.
            vocabulary: true,
            diarization: false,
            languageID: false,
            // False, unlike every other row here, because this model takes no
            // hint: it has one language baked in, `prepare` ignores the tag it
            // is handed, and `transcribe` has nothing to pass one to. Claiming
            // otherwise would have the applet render a language picker that
            // changes nothing.
            languageHint: false,
            // English only, and unlike the Nemotron row this is a real closed
            // list rather than a placeholder: the model has one language and
            // one vocabulary. The *CLI* warns on any other tag - see
            // `capabilities.supports(language:)` and its callers - which is not
            // the same as this engine warning, and is worth not confusing.
            languages: ["en"],
            minimumMacOS: "15.0")
    }

    // MARK: - Lifecycle

    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        if manager != nil { return Self.language }
        if let loading {
            try await loading.value
            return try readyLanguage()
        }
        let started = epoch
        let task = Task { try await load(progress: progress) }
        loading = task
        // Cleared only if this call's registration is still the current one. An
        // `unload()` during the load clears `loading` itself, and a `prepare`
        // after it registers a new task; without the epoch check this call's
        // `defer` would deregister that newer task, and the `prepare` after
        // *that* would start a second concurrent load of the same 1.2 GB
        // encoder.
        defer { if started == epoch { loading = nil } }
        try await task.value
        return try readyLanguage()
    }

    /// The language this row resolved to, or an error when it turns out nothing
    /// is loaded.
    ///
    /// A load that completed does not mean a manager is present: `unload()` can
    /// land between the two. Reporting success there would emit an
    /// `engine.ready` for an engine holding nothing, and the next `transcribe`
    /// would say "prepare() was not called" - which sends the reader to the
    /// wrong place entirely.
    private func readyLanguage() throws -> String {
        guard manager != nil else {
            throw SpeechError.runtime("'\(id)' was unloaded while preparing")
        }
        return Self.language
    }

    /// The model has exactly one language, so this is a fact rather than a
    /// guess even when the caller named nothing.
    private static let language = "en"

    private func load(progress: @escaping LoadProgressHandler) async throws {
        let directory = try store.directory(for: spec)
        switch try store.state(of: spec, isComplete: check) {
        case .installed:
            break
        case .partial:
            throw SpeechError.modelMissing(
                "'\(id)' is only partially downloaded; run 'speech models download \(id)' to finish it")
        case .missing, .systemManaged, .unknown:
            throw SpeechError.modelMissing(
                "'\(id)' is not installed; run 'speech models download \(id)'")
        }

        // Three CoreML bundles with no progress callback of their own.
        progress(LoadProgress(phase: .compiling))
        let started = epoch
        let manager = UnifiedAsrManager(encoderPrecision: flavor.precision)
        do {
            // `loadModels(from:)`, never `loadModels(to:)`. The `to:` overload
            // is the download path - it can fetch, and on a load failure it
            // purges the directory and fetches again - which is precisely what
            // `prepare` must never do. This overload touches no network at all.
            try await manager.loadModels(from: FluidPaths.unifiedRepo(in: directory))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime(
                "cannot load '\(id)' from \(directory.path): \(error.localizedDescription)")
        }
        // `unload()` can only run while this call is suspended inside
        // `loadModels`, and that is exactly where it does run. Assigning
        // unconditionally would hand the engine a fully loaded 1.2 GB manager
        // *after* `unload()` returned having reported the memory freed - which
        // is the one thing `unload` exists to do for Speech.app.
        guard started == epoch else {
            await manager.cleanup()
            return
        }
        self.manager = manager
    }

    /// Fetches the weights. Only `speech models download` calls this.
    ///
    /// This is the one family whose own downloader is trustworthy enough to use
    /// as-is. `loadWithRecovery` validates each `.mlmodelc` it fetched -
    /// directory shape, `coremldata.bin` present, no leftover `.partial`
    /// staging files - rather than testing for paths, so an interrupted fetch
    /// is detected instead of mistaken for a warm cache; and when a load fails
    /// anyway it purges the row's repo directory and re-fetches once. Neither
    /// Canary's hand-built cache eviction nor Nemotron's marker deletion is
    /// needed here.
    ///
    /// It loads as a side effect of downloading, and that is deliberate: the
    /// verification that matters is that CoreML can open these files, which is
    /// also the step that triggers their purge-and-retry when it cannot.
    ///
    /// But it is a tradeoff, not free, and the completeness probe below is what
    /// bounds it. `loadWithRecovery` treats *any* load failure that is not
    /// cancellation, offline or a retryable network error as corruption - and a
    /// CoreML failure is none of those - so on a machine where the encoder
    /// genuinely cannot build an execution plan (their issue #828, seen on
    /// A-series with int8) it would purge a complete 614 MB download and fetch
    /// it again on *every* retry, forever, while reporting a download failure
    /// about a download that worked perfectly.
    ///
    /// So: when the files are already complete, this verifies them with a plain
    /// local load and never enters that path. The failure is then reported as
    /// what it is, and names the escape hatch FluidAudio logs but does not
    /// surface.
    func install(progress: @escaping LoadProgressHandler) async throws {
        let directory = try store.beginInstall(spec)
        FluidNetwork.allowDownloads()
        defer { FluidNetwork.denyByDefault() }

        let installer = UnifiedAsrManager(encoderPrecision: flavor.precision)
        do {
            if check(directory) {
                // Everything is on disk already - a retry after a load failure,
                // or a row someone copied in. Verify without the download path,
                // so a model this machine cannot run costs one load rather than
                // an unbounded re-download loop.
                try await installer.loadModels(from: FluidPaths.unifiedRepo(in: directory))
            } else {
                try await installer.loadModels(
                    to: directory,
                    progressHandler: FluidProgress.handler(.installing, progress))
            }
        } catch is CancellationError {
            await installer.cleanup()
            throw CancellationError()
        } catch {
            await installer.cleanup()
            throw Self.installFailure(error, id: id, downloaded: check(directory), flavor: flavor)
        }
        await installer.cleanup()
        try store.finishInstall(spec, isComplete: check)
    }

    /// Tells a download failure from a load failure, because the fix differs
    /// and only one of them is worth retrying.
    private static func installFailure(
        _ error: Error, id: String, downloaded: Bool, flavor: UnifiedFlavor
    ) -> SpeechError {
        guard downloaded else {
            return .runtime("downloading '\(id)' failed: \(error.localizedDescription)")
        }
        var message = "'\(id)' downloaded but its models could not be loaded on this Mac:"
            + " \(error.localizedDescription)"
        if flavor.precision == .int8 {
            // FluidAudio logs this hint and then throws; nobody reading our
            // error would ever see it.
            message += ". Some chips cannot build an execution plan for the int8"
                + " encoder from an intact download - try 'fluid.parakeet-unified@fp16'"
        }
        return .runtime(message)
    }



    /// Fails now rather than after the audio has been decoded and the weights
    /// loaded: whether the spotter row is installed is a filesystem question
    /// that does not need any of that.
    func validate(_ options: TranscribeOptions) async throws {
        guard !options.vocabulary.isEmpty else { return }
        try VocabularyBooster.requireSpotter(modelsDirectory: spec.modelsDirectory)
    }

    /// The booster for this call's terms, or nil when none were asked for.
    ///
    /// Built lazily because the terms arrive with the transcribe call and not
    /// before it, and cached because loading the spotter is a 103 MB model
    /// load. The cache is not exercised by the CLI today - `transcribe` makes
    /// one call per process and `eval` passes no vocabulary - so it is there
    /// for the embedded callers stage 5 brings, not for a measurement this
    /// change can claim.
    ///
    /// Two hazards, both from `load` being a suspension point in a reentrant
    /// actor. A second caller arriving during the load must join it rather than
    /// start its own 103 MB load, and a load that finishes after `unload()` has
    /// run must not quietly re-populate an engine that reported its memory
    /// freed. The epoch answers the second; joining the in-flight task answers
    /// the first.
    private func booster(for terms: [String]) async throws -> VocabularyBooster? {
        guard !terms.isEmpty else { return nil }
        if let booster, booster.terms == terms { return booster }
        if let boosterTask {
            // A failed load must not stop this caller from trying its own.
            _ = try? await boosterTask.value
            if let booster, booster.terms == terms { return booster }
        }
        let started = boosterEpoch
        let task = Task {
            try await VocabularyBooster.load(terms: terms, modelsDirectory: spec.modelsDirectory)
        }
        boosterTask = task
        defer { if started == boosterEpoch { boosterTask = nil } }
        let built = try await task.value
        // Usable for this call either way; cached only if the engine is still
        // the one that asked for it.
        if started == boosterEpoch { booster = built }
        return built
    }

    func unload() async {
        // The bump is what makes the cancel meaningful: `loadModels` observes
        // no cancellation of its own, so an in-flight load runs to completion
        // regardless and has to be told, when it gets there, that it has been
        // abandoned. The other three engines share this shape and should be
        // swept with the stage-4 concurrency work.
        epoch &+= 1
        loading?.cancel()
        loading = nil
        await manager?.cleanup()
        manager = nil
        boosterEpoch &+= 1
        boosterTask = nil
        booster = nil
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        guard let manager else {
            throw SpeechError.runtime("'\(id)': prepare() was not called")
        }
        guard !samples.isEmpty else { return [] }

        // No reset here, and that is checked rather than assumed. Unlike the
        // Nemotron manager, this one carries nothing across calls that matters:
        // `transcribeWithTimings` builds a fresh chunk grid from the samples it
        // is handed, and `transcribeWindow` resets the RNN-T decoder before
        // every window. `UnifiedAsrManager.reset()` clears `bufferedSamples`
        // and `lastTranscript`, which belong to the streaming API this engine
        // never touches - so calling it would be ceremony, and ceremony that
        // can throw, since it reallocates decoder state.
        let result: UnifiedAsrManager.TranscriptionWithTimings
        do {
            // Whole files go in as they are: the manager lays a fixed 15 s / 2 s
            // overlapping grid over the samples and merges the seams by
            // case-folded token matching.
            result = try await manager.transcribeWithTimings(samples)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime("'\(id)' failed to transcribe: \(error.localizedDescription)")
        }

        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // After decoding, and only rewriting words, so the timings below still
        // describe the audio even when the text changed.
        if let booster = try await booster(for: options.vocabulary),
           let boosted = await booster.rescore(
               text: text, timings: result.tokenTimings, samples: samples) {
            text = boosted
        }

        let duration = Double(samples.count) / AudioDecoder.sampleRate
        let words = Self.words(from: result.tokenTimings, wanted: options.wantWordTimestamps)
        return [
            Segment(
                id: 0,
                start: words?.first?.start ?? 0,
                end: words?.last?.end ?? duration,
                text: text,
                words: words,
                // No per-utterance confidence from this manager.
                confidence: nil,
                language: "en")
        ]
    }

    private static func words(from timings: [TokenTiming], wanted: Bool) -> [Word]? {
        guard wanted, !timings.isEmpty else { return nil }
        let built = buildWordTimings(from: timings)
        guard !built.isEmpty else { return nil }
        return built.map { Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        throw SpeechError.unavailable(
            "'\(id)' has no live mode in this build (arrives in stage 4)")
    }
}
