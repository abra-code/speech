// CanaryEngine.swift - `fluid.canary-1b-v2@int4`, the accuracy row.
//
// An attention encoder-decoder rather than a transducer, which changes what it
// can and cannot do. It is the strongest of the three FluidAudio rows on
// accuracy and the only one that gives no timestamps at all: the decoder emits
// text, not aligned tokens, so this engine reports one segment spanning the
// audio and declares both timestamp capabilities false. That is the honest
// answer, and `speech transcribe --format srt` will make one long cue from it
// until VAD chunking lands.
//
// Two things here exist nowhere else in this module. The download has no
// directory parameter, so the files are adopted into the row after the fact
// (see `install`). And the language is not a hint but a pair of tokens inside
// the decoder prompt, so pointing this model at Polish means rebuilding the
// prompt from the model's own vocabulary (see `prompt`).

import AVFoundation
import Foundation
import FluidAudio
import SpeechCore

/// The Canary precisions the catalog exposes, which is one.
///
/// `CanaryPrecision` has three cases and the plan expected two rows, but
/// `FluidInference/canary-1b-v2-coreml` publishes only the int4 weights: the
/// repo holds `EncoderInt4.mlmodelc` and `DecoderInt4.mlmodelc` and no plain
/// or Int8 pair at all. Asking for `@fp16` therefore does not fall back, it
/// fails a third of the way through a download with "Model file not found:
/// Decoder.mlmodelc" and leaves a partial row - which is exactly what happened
/// here before this was checked against the repo listing.
///
/// The consequence outlived this file: int4 weight payloads need CoreML's
/// macOS 15 runtime, fp16 was the fallback that would have covered macOS 14,
/// and it does not exist - so there is no macOS 14 path for Canary at any
/// price. That is why the whole tool's deployment target is macOS 15 rather
/// than the 14 FluidAudio itself declares. Nothing else in the package needs
/// it: a sweep of every OS gate in FluidAudio 0.15.6 found none at all in
/// Parakeet TDT batch, Canary, Parakeet Unified, VAD, SlidingWindowAsrManager
/// or the offline diarizer.
///
/// The practical effect is that there is no runtime OS check in this engine.
/// The floor is enforced once, by `LSMinimumSystemVersion` and the deployment
/// target, rather than by a guard on a branch that can no longer be taken.
///
/// The enum keeps its shape for the day FluidAudio publishes the other
/// precisions; both are rejected by name and with the reason rather than
/// falling through to "unknown variant", so the answer survives being asked
/// again in six months.
enum CanaryFlavor: Sendable {
    case int4

    var precision: CanaryPrecision {
        switch self {
        case .int4: return .int4
        }
    }

    /// int4 weight payloads require macOS 15 / iOS 18, which is also the
    /// binary's floor and the reason it is.
    var minimumMacOS: String { "15.0" }

    static func parse(model: String, variant: String?) throws -> CanaryFlavor {
        guard model == "canary-1b-v2" else {
            throw SpeechError.usage("unknown FluidAudio model '\(model)'")
        }
        switch variant {
        case nil, "int4": return .int4
        case "fp16":
            throw SpeechError.usage(
                "'@fp16' is not available for canary-1b-v2: FluidAudio declares the precision"
                + " but the model repo publishes only int4 weights (want @int4)")
        case "int8":
            throw SpeechError.usage(
                "'@int8' is not available for canary-1b-v2: the repo publishes only int4"
                + " weights, and int8 decodes correctly on the CPU alone (want @int4)")
        default:
            throw SpeechError.usage(
                "unknown variant '@\(variant ?? "")' for canary-1b-v2 (want @int4)")
        }
    }
}

actor CanaryEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities
    private nonisolated let check: ModelCompletenessCheck
    nonisolated var completenessCheck: ModelCompletenessCheck? { check }

    private let spec: EngineSpec
    private let flavor: CanaryFlavor
    private let store: ModelStore

    /// The loaded weights, kept separately from the manager because a language
    /// change rebuilds the manager (its prompt is fixed at init) and reloading
    /// a gigabyte of CoreML to change two token ids would be absurd.
    private var models: CanaryModels?
    private var manager: CanaryManager?
    /// The primary subtag the current manager's prompt was built for.
    private var appliedLanguage: String?
    private var loading: Task<Void, Error>?

    init(spec: EngineSpec, flavor: CanaryFlavor) {
        self.spec = spec
        self.flavor = flavor
        self.id = spec.catalogID
        self.store = ModelStore(root: spec.modelsDirectory)
        self.check = FluidModelFiles.canary(precision: flavor.precision)
        FluidNetwork.denyByDefault()
        self.capabilities = EngineCapabilities(
            batch: true,
            live: false,
            // Both false, and this is the defining limitation of the row.
            //
            // Canary is an attention encoder-decoder: the decoder emits text
            // autoregressively with no alignment back to the audio, and
            // `transcribe` returns a bare `String`. There is nothing to round
            // off or approximate here - claiming segment timestamps would mean
            // inventing them. The plan's answer is to run Silero VAD first and
            // transcribe each speech region separately, which yields real
            // timestamps at VAD granularity; that needs its own model in the
            // store and is deliberately left for a follow-up rather than
            // bolted on here.
            wordTimestamps: false,
            segmentTimestamps: false,
            // `CanaryKeywordBooster` exists and is the follow-up alongside VAD.
            vocabulary: false,
            diarization: false,
            // The prompt names the language; the model does not report one.
            languageID: false,
            languageHint: true,
            // A real list, unlike the Nemotron row, because for this model it
            // is a fact about the weights the row id pins rather than something
            // that ships inside the download - see `trainedLanguages`.
            languages: Self.trainedLanguages,
            minimumMacOS: flavor.minimumMacOS)
    }

    // MARK: - Lifecycle

    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        if models == nil {
            if let loading {
                try await loading.value
            } else {
                let task = Task { try await load(progress: progress) }
                loading = task
                defer { loading = nil }
                try await task.value
            }
        }
        // A nil here means `unload()` landed between the load and this line,
        // so nothing is loaded. Returning nil would report a successful
        // prepare and leave the next `transcribe` to say "prepare() was not
        // called", which sends the reader to the wrong place.
        guard let resolved = try applyLanguage(language) else {
            throw SpeechError.runtime("'\(id)' was unloaded while preparing")
        }
        return resolved
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
            throw SpeechError.modelMissing(
                "'\(id)' is not installed; run 'speech models download \(id)'")
        }

        // Four CoreML bundles compiled with no callback of their own, seconds
        // of silence on a cold ANE cache.
        progress(LoadProgress(phase: .compiling))
        do {
            models = try CanaryModels.load(from: directory, precision: flavor.precision)
        } catch {
            throw SpeechError.runtime(
                "cannot load '\(id)' from \(directory.path): \(error.localizedDescription)")
        }
        // A reload invalidates any manager built on the previous weights.
        manager = nil
        appliedLanguage = nil
    }

    /// Builds the manager for a language, or reuses the one already built.
    ///
    /// Rebuilding is cheap: `CanaryManager` holds the loaded models and a
    /// prompt array, so this is an object allocation, not a model load.
    private func applyLanguage(_ language: String?) throws -> String? {
        guard let models else { return nil }
        let target = language.map(SpeechCore.Language.primarySubtag)
        let resolved = target ?? "en"
        if manager != nil, appliedLanguage == resolved { return resolved }
        manager = CanaryManager(
            models: models, prompt: try Self.prompt(for: target, in: models.tokenizer))
        appliedLanguage = resolved
        return resolved
    }

    /// The decoder prompt for a language, derived from the model's vocabulary.
    ///
    /// The English prompt FluidAudio ships is
    ///
    ///     _ <|startofcontext|> <|startoftranscript|> <|emo:undefined|>
    ///     <|en|> <|en|> <|pnc|> <|noitn|> <|notimestamp|> <|nodiarize|>
    ///
    /// as ten hardcoded token ids. The two `<|en|>` are the source and the
    /// target language; making both `<|pl|>` transcribes Polish as Polish, and
    /// making them differ would ask for translation, which is not what this
    /// program does.
    ///
    /// Every id is looked up in the loaded tokenizer rather than assumed. In
    /// particular the English id is *found* by decoding FluidAudio's own array,
    /// not taken as the literal 64 in their source, so a vocabulary change on a
    /// pin bump produces a clear error here instead of a prompt with two wrong
    /// language tokens in it - which the model would not reject, it would just
    /// transcribe as some other language.
    static func prompt(for primarySubtag: String?, in tokenizer: Tokenizer) throws -> [Int32] {
        let english = CanaryConfig.promptEnTranscribePnc
        guard primarySubtag != nil, primarySubtag != "en" else { return english }

        guard let target = primarySubtag, trainedLanguages.contains(target) else {
            throw SpeechError.unavailable(
                "'canary-1b-v2' was not trained on '\(primarySubtag ?? "")'"
                + " (has: \(trainedLanguages.joined(separator: " ")))")
        }

        let vocabulary = tokenizer.vocabulary
        guard let englishID = english.first(where: { vocabulary[Int($0)] == "<|en|>" }) else {
            throw SpeechError.runtime(
                "'canary-1b-v2': the built-in prompt no longer contains a recognizable"
                + " language token, so it cannot be retargeted; use --language en")
        }
        guard let targetID = vocabulary.first(where: { $0.value == "<|\(target)|>" })?.key else {
            // Belt and braces: `trainedLanguages` said yes and the weights say
            // no, which means the row id no longer names the model it used to.
            throw SpeechError.runtime(
                "'canary-1b-v2': the loaded model has no '<|\(target)|>' token,"
                + " so its vocabulary is not the one this build expects")
        }
        // Replaces both language slots and nothing else: every other id in the
        // prompt differs from the English language id.
        return english.map { $0 == englishID ? Int32(targetID) : $0 }
    }

    /// The 25 languages canary-1b-v2 was trained on, as primary subtags.
    ///
    /// This list is written down rather than read off the model, and that is
    /// deliberate, because the model will lie. Its vocabulary carries 183
    /// two-letter `<|xx|>` tokens - the whole ISO 639-1 set, Zulu and Navajo
    /// included - and a prompt built from any of them is accepted by the
    /// decoder without complaint. Deriving the list from the vocabulary, which
    /// is the obvious move, would advertise 183 languages of which 158 produce
    /// confident nonsense.
    ///
    /// So the source is NVIDIA's model card for canary-1b-v2, cross-checked
    /// against FluidAudio's own one-line description ("25 European languages",
    /// ModelNames.swift:62). That is sound because the row id names a specific
    /// pinned model: a different Canary is a different row. `prompt` still
    /// checks the vocabulary afterwards, so if the weights behind this id ever
    /// change out from under the list, the mismatch is an error rather than a
    /// wrong transcript.
    ///
    /// Note what is *not* here: the EU's 24 official languages minus Irish,
    /// plus Russian and Ukrainian. Parakeet v3's 28 is a superset - it adds
    /// Bosnian, Belarusian and Serbian - so the two rows are not
    /// interchangeable in either direction.
    static let trainedLanguages = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    /// Fetches the weights, then takes them out of FluidAudio's cache.
    ///
    /// `CanaryModels.download` accepts no destination, so the files land in a
    /// shared cache under `~/Library/Application Support/FluidAudio/Models`.
    /// Left there they would be invisible to `models list` and unreachable by
    /// `models delete`, so they are adopted into the row.
    ///
    /// Two things have to happen before the download, and the order is the
    /// whole point.
    ///
    /// First, any incomplete leftovers are evicted from the cache. FluidAudio
    /// decides whether to download by testing for five paths, four of which are
    /// bundle directories it creates before filling them, so an interrupted
    /// attempt leaves a cache that reports itself complete and every retry
    /// fetches nothing.
    ///
    /// Second, the cache is listed. That snapshot is what separates "we
    /// downloaded this" from "it was already here", per entry rather than per
    /// directory, because the cache is keyed by repository and not by
    /// precision: another application's fp16 Canary lives in the very directory
    /// our int4 download writes into. Snapshotting also survives a crash
    /// between the download and the adoption, which asking "does the cache look
    /// complete" cannot.
    func install(progress: @escaping LoadProgressHandler) async throws {
        let cache = FluidPaths.canaryCache
        FluidModelFiles.evictIncompleteCanary(at: cache, precision: flavor.precision)
        let preexisting = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [])

        _ = try store.beginInstall(spec)
        FluidNetwork.allowDownloads()
        defer { FluidNetwork.denyByDefault() }

        let downloaded: URL
        do {
            downloaded = try await CanaryModels.download(
                precision: flavor.precision,
                progressHandler: FluidProgress.handler(.installingRepo, progress))
        } catch {
            throw SpeechError.runtime("downloading '\(id)' failed: \(error.localizedDescription)")
        }

        // The snapshot is only meaningful for the directory it was taken of.
        // `canaryCache` reimplements a path FluidAudio keeps private, so if the
        // two ever diverge, treat everything as somebody else's and copy: the
        // cost is duplicated disk, where the alternative is moving files out of
        // a directory this program did not predict and cannot reason about.
        let keep: Set<String>
        if downloaded.standardizedFileURL == cache.standardizedFileURL {
            keep = preexisting
        } else {
            keep = Set((try? FileManager.default.contentsOfDirectory(atPath: downloaded.path)) ?? [])
        }

        // Adoption can be most of a gigabyte of copying with nothing else to
        // report, and `CanaryModels.download` sends no progress at all when it
        // finds the files already cached, so without this the CLI simply stops
        // for half a minute.
        progress(LoadProgress(phase: .installing, file: "moving into place"))
        try store.adopt(
            spec, from: downloaded,
            wanted: FluidModelFiles.canaryEntries(precision: flavor.precision),
            leaving: keep)
        try store.finishInstall(spec, isComplete: check)
    }

    func unload() async {
        // Cancelled as well as dropped. An unstructured `load` task that is
        // suspended when this runs would otherwise resume afterwards and
        // reinstall `models`, leaving the engine loaded after an `unload()`
        // that reported success - two gigabytes not reclaimed. The other two
        // FluidAudio engines share the shape and should be swept with the
        // stage-4 concurrency work.
        loading?.cancel()
        loading = nil
        manager = nil
        models = nil
        appliedLanguage = nil
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        guard models != nil else {
            throw SpeechError.runtime("'\(id)': prepare() was not called")
        }
        guard !samples.isEmpty else { return [] }

        // The per-call hint is authoritative, not the one `prepare` happened to
        // see last. The language here is two token ids baked into the decoder
        // prompt, so without this line a mixed-language run decodes every row
        // with whichever language was prepared last - `Evaluator` prepares each
        // distinct language up front and then transcribes every row, so an
        // en/pl manifest would prompt all of it in one language and show only
        // an inflated WER for the other. Rebuilding is an allocation, not a
        // model load, and is skipped when nothing changed.
        _ = try applyLanguage(options.language)
        guard let manager else {
            throw SpeechError.runtime("'\(id)' was unloaded while transcribing")
        }

        let text: String
        do {
            // The 15 s window is a hard model contract, but the manager already
            // splits longer audio into overlapping windows and stitches the
            // seams by longest common substring over tokens, so whole files can
            // be handed over as they are.
            //
            // KNOWN LIMIT: this cannot be interrupted. `CanaryManager` is an
            // actor but `transcribe(audio:)` is synchronous and its greedy
            // decode contains no cancellation check and no suspension point, so
            // the await hops to its executor and blocks one cooperative-pool
            // thread until the whole file is done - about 80 s for ten minutes
            // of audio at the measured speed. Neither Ctrl-C nor a cancelled
            // task takes effect until it returns, which is why there is no
            // `catch is CancellationError` here: it would never run.
            text = try await manager.transcribe(audio: samples)
        } catch {
            throw SpeechError.runtime("'\(id)' failed to transcribe: \(error.localizedDescription)")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // One segment spanning the audio. There is no alignment to divide it
        // on, and inventing boundaries would put fabricated timestamps into
        // subtitles that look exactly like measured ones.
        return [
            Segment(
                id: 0,
                start: 0,
                end: Double(samples.count) / AudioDecoder.sampleRate,
                text: trimmed,
                words: nil,
                confidence: nil,
                language: appliedLanguage)
        ]
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        throw SpeechError.unavailable(
            "'\(id)' has no live mode: its decoder needs a complete 15 s window")
    }
}
