// UnifiedStreamingEngine.swift - `fluid.parakeet-unified@stream-<latencyMs>`,
// the second encoder export of the Parakeet Unified checkpoint.
//
// The offline row's capability record used to say live mode there would be a
// wiring job on weights already downloaded. That was wrong, and this file is
// what it costs instead. FluidAudio's streaming path loads
// `parakeet_unified_encoder_streaming_<L>_<C>_<R>[_int8].mlmodelc`, which is a
// different bundle from the `parakeet_unified_encoder[_int8].mlmodelc` the
// offline row downloads - `streamingEncoderFile` against `offlineEncoderFile`
// in `ModelNames.ParakeetUnified` - so a second 591 MB has to come down the
// wire before any of it runs. Everything else in the repository is shared and
// small: the decoder, the joint and the vocabulary add 18 MB.
//
// **The tier is part of the row identity, for the same reason the Nemotron
// chunk size is.** The `[left, chunk, right]` attention mask is baked into the
// encoder at CoreML conversion time, so each latency tier is a physically
// distinct file rather than a runtime setting, and a measurement that did not
// record which one it used would not be reproducible. Four are published, and
// the sizes below were read from the repository's own file tree rather than
// estimated:
//
//     70_13_13   2.08 s   591_521_837 bytes int8   1_178_594_957 fp16
//     70_7_7     1.12 s   590_915_925              1_177_400_821
//     70_7_1     0.64 s   590_613_044              1_176_804_564
//     70_2_2     0.32 s   590_412_234              1_176_407_145
//
// **int8 only, and that is a decision rather than an omission.** FluidAudio
// measures the two precisions at 2.14% and 2.15% on LibriSpeech test-clean
// streaming - a difference smaller than the noise floor of any corpus this
// program has - for twice the download. Their figure names no context and the
// library's default is `70_13_13`, so read it as covering the top tier rather
// than all four; quantization plausibly matters more at `70_2_2`, where the
// attention window is 74 frames instead of 96. The fp16 export exists as an escape
// hatch for chips that cannot build an execution plan for the int8 encoder at
// all (their issue #828, seen on A-series), which is a failure this platform
// has not shown; four more 1.18 GB rows against an unobserved failure is a cost
// with nothing on the other side of it. If it does show up, note that the
// offline row's `@fp16` is not the escape hatch - it is a different encoder -
// and the fix is four more rows here.
//
// **Batch on this row means the streaming encoder run over a whole file**, and
// that is deliberate rather than a stand-in for the live mode that follows.
// `speech eval --live` scores a row against that same row's batch WER, so a
// batch number taken from the offline encoder would be comparing two different
// models and the live/batch agreement would mean nothing. The decoded frame
// ranges are the same either way: `UnifiedStreamingWindower` is driven by the
// total sample count, so the first window opens once chunk+right samples exist
// and every chunk's worth after that, whether the samples arrived all at once
// or 64 milliseconds at a time.
//
// "The same frame ranges" and not "the same windows", because those differ at
// one boundary. When the audio ends exactly on `chunk + right + k * chunk`, a
// caller that fed it all at once gets one final window with no holdback, while
// one that fed it in pieces gets that window with the holdback and then a
// second re-encode of it without. The encoder is stateless and the window bytes
// are identical, so `decodeRange` splits one contiguous range of frames into
// two consecutive decoder calls carrying the same state, and the transcript is
// the same. Strictly that also needs the encoder to be deterministic run to
// run, since it really is two predictions rather than one output reused; it is,
// on this path. The distinction is worth keeping because it is the sort of claim
// that gets repeated.

import AVFoundation
import Foundation
import FluidAudio
import SpeechCore

/// One published `[left, chunk, right]` streaming export.
///
/// The frame counts are the identity: the file name carries them, the
/// `UnifiedConfig` that drives the windower is built from them, and the
/// latency a user picks by is derived from them rather than stored beside them.
struct UnifiedStreamTier: Sendable, Equatable {
    /// History visible to each chunk, in 80 ms encoder frames. 70 on every
    /// published export, which is why it is not part of the variant.
    let left: Int
    /// New audio decoded per step.
    let chunk: Int
    /// Look-ahead. The other half of the latency, and the half that is not
    /// obvious: a 0.16 s chunk with 1.04 s of look-ahead is not a fast tier.
    let right: Int

    var config: UnifiedConfig {
        UnifiedConfig(leftFrames: left, chunkFrames: chunk, rightFrames: right)
    }

    /// The suffix FluidAudio builds its encoder file name from.
    var contextSuffix: String { config.contextSuffix }

    /// Chunk plus look-ahead, in milliseconds: the theoretical delay between a
    /// word being spoken and the encoder being able to see all of it.
    var latencyMs: Int { config.latencyMs }

    /// The `@` variant this tier is addressed by.
    var variant: String { "\(UnifiedStreamTier.prefix)\(latencyMs)" }

    static let prefix = "stream-"

    /// Every tier published in `FluidInference/parakeet-unified-en-0.6b-coreml`,
    /// checked against the repository listing rather than against the library's
    /// default, which names only the first.
    ///
    /// All four are shipped, unlike the Nemotron row where a fourth tier was
    /// dropped. The reason they are not comparable: Nemotron's extra tier was
    /// slower than one already listed with no accuracy to show for it, whereas
    /// these four are a monotonic latency dial from 2.08 s down to 0.32 s and
    /// nothing in the published figures says where it stops being worth it.
    /// That is a question for a measurement, and a row has to exist before the
    /// instrument can measure it.
    static let all: [UnifiedStreamTier] = [
        UnifiedStreamTier(left: 70, chunk: 13, right: 13),
        UnifiedStreamTier(left: 70, chunk: 7, right: 7),
        UnifiedStreamTier(left: 70, chunk: 7, right: 1),
        UnifiedStreamTier(left: 70, chunk: 2, right: 2),
    ]

    /// The tier a variant names, or nil for anything else.
    ///
    /// Compared against the spelling this type produces rather than parsed back
    /// out of it, so `@stream-0640` and `@stream-640ms` are refused instead of
    /// quietly becoming a second name for one row. One id, one directory in the
    /// store, one row in a measurement.
    ///
    /// Nil rather than throwing, because "this is not a streaming variant" and
    /// "this is a streaming variant naming a tier that does not exist" are
    /// different answers and only the caller can tell which one matters.
    static func tier(forVariant variant: String) -> UnifiedStreamTier? {
        all.first { $0.variant == variant }
    }

    /// Every streaming variant, for an error message and for the catalog.
    static var variants: [String] { all.map(\.variant) }
}

actor UnifiedStreamingEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities
    private nonisolated let check: ModelCompletenessCheck
    nonisolated var completenessCheck: ModelCompletenessCheck? { check }

    private let spec: EngineSpec
    private let tier: UnifiedStreamTier
    private let store: ModelStore

    private var manager: StreamingUnifiedAsrManager?
    private var loading: Task<Void, Error>?
    /// Bumped by `unload()`, so a load still suspended inside CoreML when the
    /// engine was unloaded can tell that it has been abandoned. Same shape and
    /// same reason as the other three FluidAudio engines.
    private var epoch = 0

    init(spec: EngineSpec, tier: UnifiedStreamTier) {
        self.spec = spec
        self.tier = tier
        self.id = spec.catalogID
        self.store = ModelStore(root: spec.modelsDirectory)
        self.check = FluidModelFiles.unifiedStreaming(tier: tier)
        FluidNetwork.denyByDefault()
        self.capabilities = EngineCapabilities(
            batch: true,
            // The manager below is the streaming one, so live mode here is
            // the same weights and the same ANE compile as the batch path
            // above - see `UnifiedStreamingBackend`. The tier is the latency:
            // a chunk is decoded only once a whole one has arrived, and the
            // look-ahead is held back on top of that, so the row's variant IS
            // its responsiveness.
            live: true,
            wordTimestamps: true,
            segmentTimestamps: true,
            // The streaming manager does implement vocabulary boosting, and it
            // is left off here on purpose. Its `configureVocabularyBoosting`
            // rescores in 15 s segments against a CTC spotter, which is a
            // second model, a second load and a retroactive rewrite of text
            // already published - and none of that has been measured on this
            // row. The offline row carries the feature; this one says no rather
            // than advertising something untested.
            vocabulary: false,
            diarization: false,
            languageID: false,
            // One language baked into the checkpoint, so a hint would change
            // nothing. Same as the offline row.
            languageHint: false,
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
        defer { if started == epoch { loading = nil } }
        try await task.value
        return try readyLanguage()
    }

    /// A completed load does not mean a manager is present: `unload()` can land
    /// between the two, and reporting success there would emit `engine.ready`
    /// for an engine holding nothing.
    private func readyLanguage() throws -> String {
        guard manager != nil else {
            throw SpeechError.runtime("'\(id)' was unloaded while preparing")
        }
        return Self.language
    }

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

        progress(LoadProgress(phase: .compiling))
        let started = epoch
        let manager = StreamingUnifiedAsrManager(config: tier.config, encoderPrecision: .int8)
        do {
            // `loadModels(from:)`, never `loadModels(to:)`: the `to:` overload
            // is the download path, and it purges the directory and re-fetches
            // when a load fails. `prepare` must never reach the network.
            try await manager.loadModels(from: FluidPaths.unifiedRepo(in: directory))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime(
                "cannot load '\(id)' from \(directory.path): \(error.localizedDescription)")
        }
        guard started == epoch else {
            await manager.cleanup()
            return
        }
        self.manager = manager
    }

    /// Fetches the weights. Only `speech models download` calls this.
    ///
    /// The same trade the offline row documents, and it matters more here
    /// because the streaming encoder is the one file `loadWithRecovery` would
    /// purge: any load failure that is not cancellation, offline or a
    /// retryable network error is treated as a corrupt cache, and a CoreML
    /// execution-plan failure is none of those. So a complete download is
    /// verified with a plain local load, which never enters that path, and only
    /// an incomplete one goes through the downloader.
    func install(progress: @escaping LoadProgressHandler) async throws {
        let directory = try store.beginInstall(spec)
        FluidNetwork.allowDownloads()
        defer { FluidNetwork.denyByDefault() }

        let installer = StreamingUnifiedAsrManager(config: tier.config, encoderPrecision: .int8)
        do {
            if check(directory) {
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
            throw Self.installFailure(error, id: id, downloaded: check(directory))
        }
        await installer.cleanup()
        try store.finishInstall(spec, isComplete: check)
    }

    private static func installFailure(_ error: Error, id: String, downloaded: Bool) -> SpeechError {
        guard downloaded else {
            return .runtime("downloading '\(id)' failed: \(error.localizedDescription)")
        }
        // No `@fp16` to point at, unlike the offline row: the streaming
        // encoders are published in both precisions but only int8 is a catalog
        // row here, so the honest advice is the offline row rather than a
        // variant that does not exist.
        return .runtime(
            "'\(id)' downloaded but its models could not be loaded on this Mac:"
            + " \(error.localizedDescription). Some chips cannot build an execution plan"
            + " for an int8 encoder from an intact download - 'fluid.parakeet-unified@fp16'"
            + " is the offline encoder in the other precision and does not stream")
    }

    func unload() async {
        epoch &+= 1
        loading?.cancel()
        loading = nil
        await manager?.cleanup()
        manager = nil
    }

    // No `validate`. The protocol's default is a no-op, and it is the right
    // one here: there is no second model to check for, and the verbs already
    // warn and drop the terms for a row whose capability record says no
    // vocabulary - throwing instead would make this row the only one that
    // refuses the run.

    // MARK: - Transcription

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        guard let manager else {
            throw SpeechError.runtime("'\(id)': prepare() was not called")
        }
        guard !samples.isEmpty else { return [] }

        let text: String
        let timings: [TokenTiming]
        do {
            // Every piece of state this manager holds - the rolling sample
            // buffer, the windower's consumed position, the RNN-T decoder's
            // LSTM, the accumulated token ids - persists across calls by
            // design, and `finish()` latches the windower's final flush. So the
            // second file in an eval run would decode into the first one's
            // context and then produce no windows at all.
            try await manager.reset()
            // In slices, and NOT the whole file in one `appendAudio`, which is
            // what this did first. Two costs, both invisible on a 12 s FLEURS
            // row and both quadratic in the length of a real recording.
            //
            // The manager keeps a rolling buffer and drops the audio behind it
            // with `samples.removeFirst(dropCount)` after every window, so a
            // buffer holding the rest of the file memmoves the rest of the file
            // once per chunk. Measured on this machine at the 320 ms tier: 0.96
            // s of pure memmove for ten minutes of audio and 11.34 s for thirty
            // - three times the audio for twelve times the cost. Slicing bounds
            // that buffer, and the total drops by roughly the ratio of the
            // slice to the file.
            //
            // And at the moment `appendAudio` returns there are four live
            // copies of whatever it was handed: this array, the buffer built
            // for it, the library converter's own extraction, and the manager's
            // rolling buffer. Slicing removes three of the four, not four - the
            // caller's `samples` stays live for the whole call either way - so
            // on a 58-minute file it saves about 660 MB rather than 880. That
            // matches what was measured: 1.94 GB peak against 1.29 GB.
            //
            // The transcript is unaffected, and that is a property of the
            // library rather than a hope: `UnifiedStreamingWindower` decides
            // each window from the total sample count and its own consumed
            // position, so the decoded frame ranges are the same however the
            // samples arrived. It is also what a live session does, which makes
            // this the *more* faithful batch path rather than a compromise.
            var offset = 0
            while offset < samples.count {
                let end = min(offset + Self.sliceSamples, samples.count)
                try await manager.appendAudio(FluidBuffers.canonical(Array(samples[offset..<end])))
                try await manager.processBufferedAudio()
                offset = end
            }
            // `finish()` and not `processBufferedAudio()`: the last window is
            // held back until the stream ends, because the right context is
            // re-encoded with more future audio on every step. Dropping it
            // loses the tail of every file - up to chunk+right seconds.
            text = try await manager.finish()
            // After `finish()`, and once. This drains rather than reads, and
            // nothing has drained it yet, so the whole file's timings come back
            // with each token's end already back-filled to the next token's
            // start. A live session, which drains every chunk, has to do that
            // back-fill across drain boundaries itself.
            timings = await manager.consumeTokenTimings()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime("'\(id)' failed to transcribe: \(error.localizedDescription)")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let duration = Double(samples.count) / AudioDecoder.sampleRate
        let words = Self.words(from: timings, wanted: options.wantWordTimestamps)
        return [
            Segment(
                id: 0,
                start: words?.first?.start ?? 0,
                end: words?.last?.end ?? duration,
                text: trimmed,
                words: words,
                // No per-utterance confidence from this manager.
                confidence: nil,
                language: Self.language)
        ]
    }

    /// How much audio goes into one `appendAudio` on the batch path.
    ///
    /// Thirty seconds, and the number is a compromise between two costs that
    /// pull in opposite directions rather than a round figure. Smaller slices
    /// keep the manager's rolling buffer shorter, and its per-window trim is
    /// linear in that buffer; larger slices pay fewer actor hops and fewer
    /// converter allocations. The trim total is proportional to
    /// `slice / 2 + window`, so on a one-hour file going from the whole file to
    /// a thirty-second slice removes about 99% of it and going from thirty
    /// seconds to five removes another 0.7% - which is why this is not
    /// smaller.
    private static let sliceSamples = Int(30 * AudioDecoder.sampleRate)

    private static func words(from timings: [TokenTiming], wanted: Bool) -> [Word]? {
        guard wanted, !timings.isEmpty else { return nil }
        let built = buildWordTimings(from: timings)
        guard !built.isEmpty else { return nil }
        return built.map { Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        guard let manager else {
            // "not loaded" rather than "prepare() was not called": after an
            // `unload()` the second is simply wrong, and Speech.app reaches
            // this state that way between jobs.
            throw SpeechError.runtime(
                "'\(id)' has no models loaded; call prepare() before starting a live session")
        }
        // ONE LIVE SESSION AT A TIME, and it is a contract rather than a guard -
        // the same one `fluid.nemotron-multilingual` carries, for the same
        // reason. The session shares this manager instead of loading a second
        // one, which is why live mode on this row costs no extra 609 MB and no
        // second ANE compile; two concurrent sessions, or a `transcribe()`
        // during a session, would reset each other's decoder state and each
        // other's window position. Nothing in the CLI can break it - the verbs
        // are sequential and `--refine` refuses the draft engine's own id - so
        // enforcing it would mean a session-lifetime hook for a caller that
        // does not exist yet. Stage 5 is when it does; see plan step 5.10.
        // Wrapped, because `make` resets the manager and that reallocates the
        // RNN-T decoder's state. Its sibling's `make` cannot throw, so without
        // this one failure path in the whole actor would surface a raw CoreML
        // string where every other one names the row.
        let backend: UnifiedStreamingBackend
        do {
            backend = try await UnifiedStreamingBackend.make(manager: manager)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime(
                "'\(id)' could not start a live session: \(error.localizedDescription)")
        }
        return FluidStreamingSession(
            backend: backend,
            catalogID: id,
            language: Self.language,
            wantWords: options.wantWordTimestamps)
    }
}
