// NemotronEngine.swift - `fluid.nemotron-multilingual@<chunkMs>`, the row that
// covers the languages nobody else does.
//
// Parakeet v3 is 28 European languages and Apple ships a fixed set of locale
// assets. Nemotron 3.5 multilingual is the only row in this build whose
// vocabulary spans 100+ languages, so it is the fallback for anything the other
// two decline - and, for the languages they share, a second opinion the eval
// can rank them against.
//
// Two things make it different from ParakeetEngine and both shape this file.
// It is a *streaming* manager used in batch: audio is pushed through in fixed
// chunks and the transcript is drained at the end, so state has to be reset per
// file rather than per call. And its language hint is a prompt id looked up in
// a dictionary that ships inside the downloaded model, so the set of languages
// it accepts is not knowable until the weights are on disk - see `resolve`.

import AVFoundation
import Foundation
import FluidAudio
import SpeechCore

/// The chunk tiers the catalog exposes, as the `@` variant.
///
/// The tier is part of the row identity because it is part of the download:
/// FluidAudio ships a separately converted model per chunk size and they land
/// in different directories. It is also the accuracy/latency dial, which is why
/// it is a catalog row rather than a runtime flag - a measurement that does not
/// record the tier is not reproducible.
enum NemotronFlavor: Sendable {
    case multilingual(chunkMs: Int)

    var chunkMs: Int {
        switch self {
        case .multilingual(let ms): return ms
        }
    }

    /// The tiers this build offers. FluidAudio also converts a 4480 ms tier;
    /// it is left out because it doubles the trailing-audio padding for no
    /// accuracy gain that the plan's corpora would show, and an unused catalog
    /// row still costs a user a decision.
    static let chunkTiers = [560, 1120, 2240]

    /// FluidAudio's own recommendation, and the tier a bare id means.
    ///
    /// Not the smallest: below 1120 ms the model emits increasingly sparse
    /// punctuation on long sessions (FluidAudio issue #687, words unaffected),
    /// and this program's batch path feeds whole files, which is precisely the
    /// long-session case. 560 stays available for anyone measuring latency.
    static let defaultChunkMs = 2240

    static func parse(model: String, variant: String?) throws -> NemotronFlavor {
        guard model == "nemotron-multilingual" else {
            throw SpeechError.usage("unknown FluidAudio model '\(model)'")
        }
        guard let variant else { return .multilingual(chunkMs: defaultChunkMs) }
        guard let ms = Int(variant), chunkTiers.contains(ms) else {
            throw SpeechError.usage(
                "unknown variant '@\(variant)' for nemotron-multilingual"
                + " (want @\(chunkTiers.map(String.init).joined(separator: ", @")))")
        }
        return .multilingual(chunkMs: ms)
    }
}

actor NemotronEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities
    private nonisolated let check: ModelCompletenessCheck
    nonisolated var completenessCheck: ModelCompletenessCheck? { check }

    private let spec: EngineSpec
    private let chunkMs: Int
    private let store: ModelStore

    private var manager: StreamingNemotronMultilingualAsrManager?
    /// The prompt dictionary out of the downloaded `metadata.json`, kept so
    /// this engine can tell "the model knows this language" from "the model
    /// silently fell back to auto" - a distinction FluidAudio's own
    /// `promptId(forLanguage:)` collapses by returning the default id for both.
    private var promptDictionary: [String: Int] = [:]
    /// The prompt key currently applied - nil meaning "the model's own default
    /// prompt" - so `prepare` called twice with the same language does not
    /// re-run the setter, and called with a different one does. `nil` is a
    /// meaningful value here, hence the separate `languageApplied` flag rather
    /// than overloading it as "nothing set yet".
    private var appliedKey: String?
    private var languageApplied = false
    /// The language change in flight, so concurrent changes queue rather than
    /// interleave. See `applyLanguage`.
    private var languageChange: Task<String?, Error>?
    /// Same in-flight guard as ParakeetEngine, and the same two accepted
    /// limits: joining a load in progress does not deliver progress to the
    /// second caller, and cancelling a caller does not cancel the load.
    private var loading: Task<Void, Error>?

    init(spec: EngineSpec, flavor: NemotronFlavor) {
        self.spec = spec
        self.chunkMs = flavor.chunkMs
        self.id = spec.catalogID
        self.store = ModelStore(root: spec.modelsDirectory)
        self.check = FluidModelFiles.nemotronMultilingual(chunkMs: flavor.chunkMs)
        FluidNetwork.denyByDefault()
        self.capabilities = EngineCapabilities(
            batch: true,
            // Stage 4. The manager is already a streaming one - `appendAudio`
            // plus a partial callback - so live is a wiring job here rather
            // than a new model, but claiming it before it is wired would let
            // the applet enable a Record button that throws.
            live: false,
            wordTimestamps: true,
            segmentTimestamps: true,
            vocabulary: false,
            diarization: false,
            // False on the evidence, not on the API.
            //
            // The model plainly has the machinery: metadata.json carries 39
            // `lang_tag_token_ids`, the tokenizer strips those tokens out of
            // the text, and `detectedLanguage()` exists to report the first
            // one. But the 2240 ms ship does not emit them - measured on an
            // English and a Polish FLEURS file with no hint, both transcribed
            // correctly and both reported nil. A capability that never fires
            // would have the applet show an empty "detected language" field and
            // the catalog rank this row above engines that actually answer.
            //
            // `transcribe` still reads `detectedLanguage()` and prefers it when
            // it is there, so a pin bump that starts emitting tags needs only
            // this flag flipped back.
            languageID: false,
            languageHint: true,
            // Deliberately empty, which this protocol reads as "any language".
            //
            // The honest list is the `prompt_dictionary` inside the downloaded
            // metadata.json, and capabilities have to be answerable by `speech
            // engines` on a machine that has never downloaded anything. Naming
            // a guessed subset here would make `transcribe` warn about
            // languages the model handles fine, and pinning the real list would
            // make a pin bump silently wrong. An unmatched hint is not an error
            // for this model - it decodes anyway and reports what it heard - so
            // "any" is the true answer, and `prepare` returns "auto" to say
            // when a hint was not used.
            languages: [],
            minimumMacOS: "14.0")
    }

    // MARK: - Lifecycle

    /// Loads already-downloaded weights and applies the language hint. Never
    /// downloads - see `install`, and the same reasoning as ParakeetEngine.
    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        if manager == nil {
            if let loading {
                try await loading.value
            } else {
                let task = Task { try await load(progress: progress) }
                loading = task
                defer { loading = nil }
                try await task.value
            }
        }
        // Outside the guard on purpose: a second `prepare` with a different
        // language must re-point the model even though the weights are loaded.
        return try await applyLanguage(language)
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

        let variant = FluidPaths.nemotronVariant(in: directory, chunkMs: chunkMs)

        // Read the prompt dictionary before loading, from the same file the
        // manager reads. Cheap, and it means a corrupt metadata.json is
        // reported as such rather than as an unexplained "auto" later.
        //
        // Held in a local until the manager exists, and published with it in
        // one uninterrupted step. Assigning the property here instead would
        // leave a window across the `loadModels` await in which `unload()` can
        // clear the dictionary while this call is suspended - after which
        // `load` resumes, installs the manager, and every language hint for
        // the rest of the process silently resolves to nothing.
        let dictionary: [String: Int]
        do {
            dictionary = try NemotronMultilingualStreamingConfig(
                from: variant.appendingPathComponent("metadata.json")).promptDictionary
        } catch {
            throw SpeechError.runtime(
                "cannot read the language table of '\(id)' at \(variant.path):"
                + " \(error.localizedDescription)")
        }

        // No fraction to report: `loadModels` compiles four CoreML bundles
        // without a progress callback of its own, and this is the multi-second
        // first-run ANE compile that silence reads as a hang.
        progress(LoadProgress(phase: .compiling))
        let manager = StreamingNemotronMultilingualAsrManager()
        do {
            try await manager.loadModels(from: variant)
        } catch {
            throw SpeechError.runtime(
                "cannot load '\(id)' from \(variant.path): \(error.localizedDescription)")
        }
        self.manager = manager
        self.promptDictionary = dictionary
        // A fresh manager starts on its metadata default prompt, whatever the
        // last session asked for.
        appliedKey = nil
        languageApplied = false
    }

    /// Points the model at a language and reports what it actually resolved to.
    ///
    /// Returns the `prompt_dictionary` key in use, or "auto" when the requested
    /// tag is not in the table. That return value is the only signal a caller
    /// gets: FluidAudio's resolver answers with a prompt *id* and quietly hands
    /// back the default for an unknown language, so "de-DE resolved to German"
    /// and "de-DE was ignored" are the same value there. It surfaces in the
    /// `engine.ready` event as `locale`.
    private func applyLanguage(_ language: String?) async throws -> String? {
        guard manager != nil else { return nil }
        // Chained behind whatever change is already in flight, so that the
        // order the manager is told about equals the order it was asked. Two
        // concurrent callers that both suspend inside `setLanguage` can
        // otherwise land the manager on one language while this actor records
        // the other - and that error is permanent, because the `appliedKey`
        // guard then skips the very call that would correct it. The CLI is
        // sequential, but Speech.app drives one engine from several places.
        let previous = languageChange
        let task = Task { [self] () throws -> String? in
            // A failed change must not stop the next one from being applied.
            _ = try? await previous?.value
            return try await setLanguage(language)
        }
        languageChange = task
        return try await task.value
    }

    private func setLanguage(_ language: String?) async throws -> String? {
        guard let manager else { return nil }
        let key = Self.promptKey(for: language, in: promptDictionary)
        // The report and the identity are different values. "auto" is a real
        // key in this model's table as well as the word for "no hint applied",
        // so a single field would make `prepare("auto")` after a rejected tag
        // take the early return and never apply the genuine auto prompt.
        let resolved = key ?? "auto"
        guard !languageApplied || appliedKey != key else { return resolved }
        await manager.setLanguage(key)
        appliedKey = key
        languageApplied = true
        return resolved
    }

    /// The `prompt_dictionary` key FluidAudio's own resolver would land on, or
    /// nil when it would fall through to the default id.
    ///
    /// This mirrors `NemotronMultilingualStreamingConfig.promptId(forLanguage:)`
    /// candidate for candidate and in the same order, because the point is to
    /// learn *which* key matched, which their function does not report. The
    /// mirror is pinned by a test that drives their resolver over the same
    /// tags, so a pin bump that changes the normalization rules fails a test
    /// instead of silently transcribing Polish with an English prompt.
    static func promptKey(for tag: String?, in dictionary: [String: Int]) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        var candidates = [tag]
        let dashed = tag.replacingOccurrences(of: "_", with: "-")
        candidates.append(dashed)
        let parts = dashed.split(separator: "-", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            candidates.append(parts[0].lowercased() + "-" + parts[1].uppercased())
        }
        if let bare = parts.first {
            candidates.append(bare.lowercased())
        }
        return candidates.first { dictionary[$0] != nil }
    }

    /// Fetches the weights. Only `speech models download` calls this.
    ///
    /// The `metadata.json` removal is not housekeeping, it is the whole reason
    /// a retry works. `downloadVariant` decides whether to fetch anything by
    /// testing for that one file and returns the cached directory when it is
    /// there:
    ///
    ///     if FileManager.default.fileExists(atPath: metadataPath.path) { ... }
    ///     else { try await ModelHub.download(...) }
    ///
    /// metadata.json is three kilobytes and lands in the first moments of a
    /// 665 MB pull, so an install interrupted at any point after that leaves a
    /// row that is incomplete *and* looks cached. Every retry would then
    /// download nothing, `finishInstall` would fail the completeness check, and
    /// the error would tell the user to retry - which can never work. The one
    /// repair path FluidAudio does have is unreachable from here: it only fixes
    /// a corrupt tokenizer in the `latin` ship, and `nemotronLanguageCode` is
    /// always "auto".
    ///
    /// Removing the marker file when the row is incomplete puts the downloader
    /// back on its fetch branch. That is cheap rather than a fresh 665 MB:
    /// `FileDownloader.ensure` skips every file already present, so a retry
    /// pays only for what is missing.
    func install(progress: @escaping LoadProgressHandler) async throws {
        let directory = try store.beginInstall(spec)
        if !check(directory) {
            try? FileManager.default.removeItem(
                at: FluidPaths.nemotronVariant(in: directory, chunkMs: chunkMs)
                    .appendingPathComponent("metadata.json"))
        }
        FluidNetwork.allowDownloads()
        defer { FluidNetwork.denyByDefault() }
        do {
            _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: FluidPaths.nemotronLanguageCode,
                chunkMs: chunkMs,
                to: directory,
                progressHandler: FluidProgress.handler(.installing, progress))
        } catch {
            throw SpeechError.runtime("downloading '\(id)' failed: \(error.localizedDescription)")
        }
        try store.finishInstall(spec, isComplete: check)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        appliedKey = nil
        languageApplied = false
        languageChange = nil
        promptDictionary = [:]
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        guard let manager else {
            throw SpeechError.runtime("'\(id)': prepare() was not called")
        }
        guard !samples.isEmpty else { return [] }

        // The per-call hint is authoritative, not the one `prepare` happened to
        // see last. For every other engine the language rides along in the
        // transcribe call; here it is a prompt id set on the manager, so
        // without this line the language is whatever the final `prepare` chose.
        //
        // That is not hypothetical. `Evaluator` prepares each distinct language
        // in the manifest up front - deliberately, so a language the engine
        // cannot do fails immediately rather than forty minutes in - and then
        // transcribes every row. A mixed en/pl corpus therefore decoded every
        // English row with the Polish prompt, while still labelling each row
        // with its own language. The only symptom was an inflated WER.
        //
        // `applyLanguage` is a no-op when nothing changed, so the common case
        // of a single-language run costs one comparison per row.
        _ = try await applyLanguage(options.language)

        // This manager is a streaming one: its encoder cache, decoder LSTM
        // state and accumulated tokens all persist across calls by design.
        // Without a reset the second file in an eval run starts with the first
        // file's context, which shows up as the opening words being conditioned
        // on the end of an unrelated recording. `reset` preserves the prompt id,
        // so the language hint survives it.
        await manager.reset()

        let text: String
        let timings: [TokenTiming]
        do {
            // `process` drains whole chunks and buffers the remainder; `finish`
            // pads and flushes it. Both are needed - dropping `finish` loses up
            // to one chunk of trailing audio, which for the 2240 ms tier is the
            // last two seconds of every file.
            _ = try await manager.process(samples: samples)
            (text, timings) = try await manager.finishWithTokenTimings()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime("'\(id)' failed to transcribe: \(error.localizedDescription)")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let duration = Double(samples.count) / 16000.0
        let words = Self.words(from: timings, wanted: options.wantWordTimestamps)
        // What the model heard beats what the caller guessed, and this row is
        // the one that can tell the difference.
        let detected = await manager.detectedLanguage() ?? options.language
        return [
            Segment(
                id: 0,
                start: words?.first?.start ?? 0,
                end: words?.last?.end ?? duration,
                text: trimmed,
                words: words,
                // The multilingual decoder returns no per-utterance confidence,
                // and nil says that, where 1.0 would claim certainty.
                confidence: nil,
                language: detected.map(SpeechCore.Language.primarySubtag))
        ]
    }

    /// Token timings to words, through FluidAudio's own SentencePiece joiner -
    /// the same one Parakeet uses, and correct here for the same reason: both
    /// vocabularies mark a word start with the boundary prefix.
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
