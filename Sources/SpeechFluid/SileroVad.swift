// SileroVad.swift - `fluid.silero-vad`, the row that hears speech without
// reading it.
//
// One compiled CoreML bundle of a megabyte, an LSTM over a 256 ms window,
// and no vocabulary of any kind: it answers "is someone speaking" and nothing
// else. That makes it the only component in this program whose answer does not
// depend on the language, the model or the machine's opinion of a sentence,
// which is exactly what utterance boundaries need - see `VoiceActivity` in
// SpeechCore for what they are used for.
//
// It is a catalog row for the same reason the CTC spotter is: it is downloaded,
// measured, listed and deleted like a model, and only its output is different.
//
// Five things about FluidAudio's `VadManager` shape this file, and three of
// them are traps.
//
// **The window is exactly 4096 samples and a short chunk is accepted.** That is
// the trap. `processChunk` pads a short chunk to the window by repeating its
// last sample, and `processStreamingChunk` then advances its clock by the
// length it was *handed* rather than by the window it processed - so ragged
// buffers produce probabilities computed partly from padding and timestamps for
// a stream nobody played. `SampleChunker` is what keeps this file feeding whole
// windows only.
//
// **The event's `time` is rounded to a tenth of a second.** `returnSeconds` is
// off by default and `timeResolution` defaults to 1, meaning one decimal place;
// asking for seconds therefore quantizes every boundary to 100 ms. The
// `sampleIndex` beside it is exact, so this file converts that instead, and the
// resulting clock is the count of samples fed since the last reset.
//
// **The streaming path ignores half of `VadSegmentationConfig`.**
// `minSpeechDuration`, `maxSpeechDuration` and the split thresholds are read
// only by the offline `segmentSpeech`; the state machine here consults
// `minSilenceDuration`, `speechPadding` and the negative threshold and nothing
// else. So a cough produces a start and an end like any other speech, and a
// speaker who never pauses produces one start and no end for as long as they
// keep going. Both are the consumer's problem, and both are already handled
// where segments are cut: an empty segment is never emitted and a backstop
// closes a segment that runs long.
//
// **At most one event per call**, by construction: the result carries a single
// optional event and the two branches that set it are mutually exclusive. So
// boundaries can be treated as strictly alternating. What makes a short pause
// invisible is not this but `minSilenceDuration` - 0.75 s, about three windows
// - which is where an ending is decided; see `segmentation` below.
//
// **The manager holds no per-stream state.** Everything that advances - the
// LSTM state, the trigger, the clock - lives in the `VadStreamState` value the
// caller threads through, so one loaded model can serve several detectors at
// once and the actor serializes only the prediction itself.

import Foundation
import FluidAudio
import SpeechCore

/// The catalog row. Downloads, reports completeness, and opens detectors over
/// the weights it downloaded.
actor SileroVadEngine: TranscriptionEngine, VoiceActivityEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities
    private nonisolated let check: ModelCompletenessCheck
    nonisolated var completenessCheck: ModelCompletenessCheck? { check }

    private let spec: EngineSpec
    private let store: ModelStore

    /// The loaded model, shared by every detector this engine opens.
    ///
    /// A task rather than the manager itself, so two callers arriving at once
    /// wait on one load instead of compiling the bundle twice. Cleared when it
    /// fails, because a cached failure would make every later attempt report a
    /// load that never happened again.
    private var loading: Task<VadManager, Error>?

    init(spec: EngineSpec) {
        self.spec = spec
        self.id = spec.catalogID
        self.store = ModelStore(root: spec.modelsDirectory)
        self.check = FluidModelFiles.vad
        FluidNetwork.denyByDefault()
        self.capabilities = EngineCapabilities(
            // Every flag false, which is the honest description of a row that
            // produces no text. `speech engines` lists it so that a user who
            // finds it in `models list` can see what it is; a picker built from
            // `batch` or `live` will not offer it.
            batch: false,
            live: false,
            wordTimestamps: false,
            segmentTimestamps: false,
            vocabulary: false,
            diarization: false,
            languageID: false,
            languageHint: false,
            // Empty is this record's spelling of "any language", and here it is
            // the literal truth rather than a shrug: the model is trained on
            // speech as an acoustic event, so it carries no language at all.
            languages: [],
            minimumMacOS: "15.0")
    }

    // MARK: - Not a transcriber

    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        throw SpeechError.usage(
            "'\(id)' detects where speech starts and stops; it does not transcribe it")
    }

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        throw SpeechError.usage("'\(id)' is a voice activity detector, not a transcriber")
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        throw SpeechError.usage("'\(id)' is a voice activity detector, not a transcriber")
    }

    // MARK: - Detection

    func makeDetector(progress: @escaping LoadProgressHandler) async throws
        -> any VoiceActivityDetector
    {
        let task = loading ?? Task { try await load(progress: progress) }
        loading = task
        do {
            return SileroVadDetector(manager: try await task.value)
        } catch {
            loading = nil
            throw error
        }
    }

    private func load(progress: @escaping LoadProgressHandler) async throws -> VadManager {
        let directory = try store.directory(for: spec)
        switch try store.state(of: spec, isComplete: check) {
        case .installed:
            break
        case .partial:
            throw SpeechError.modelMissing(
                "'\(id)' is only partially downloaded;"
                + " run 'speech models download \(id)' to finish it")
        case .missing, .systemManaged, .unknown:
            throw SpeechError.modelMissing(
                "'\(id)' is not installed; run 'speech models download \(id)'")
        }

        progress(LoadProgress(phase: .compiling))
        do {
            // The network is denied for the whole process, so this reaches
            // `ModelHub` with `offlineMode` set and cannot turn a load into a
            // download - which for this loader would also mean purging the
            // row and fetching it again. `install` is the only path that opens
            // the network.
            return try await VadManager(
                config: .default,
                modelDirectory: directory,
                progressHandler: FluidProgress.handler(.loading, progress))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime(
                "cannot load '\(id)' from \(directory.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Store

    func install(progress: @escaping LoadProgressHandler) async throws {
        let directory = try store.beginInstall(spec)
        FluidNetwork.allowDownloads()
        defer { FluidNetwork.denyByDefault() }
        do {
            // `ModelHub.download` rather than constructing a `VadManager`, for
            // the reason the spotter row gives: their loader compiles the model
            // and throws it away, and it has no progress handler, while this
            // one reports files as they arrive and re-fetches only what is
            // missing when a download is resumed.
            //
            // `to:` is the models directory rather than the row, because
            // `ModelHub` appends the repo folder itself and `VadManager` will
            // later look for it under that name - see `FluidPaths.vadModels`.
            try await ModelHub.download(
                .vad,
                to: FluidPaths.vadModels(in: directory),
                progressHandler: FluidProgress.handler(.installing, progress))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime("downloading '\(id)' failed: \(error.localizedDescription)")
        }
        try store.finishInstall(spec, isComplete: check)
    }

    func unload() async {
        loading?.cancel()
        loading = nil
    }
}

/// One stream of audio, watched.
///
/// The state is a value FluidAudio hands back on every call, so this actor owns
/// a stream rather than a model: two of these over one manager are independent,
/// and `reset` costs nothing but dropping the value.
actor SileroVadDetector: VoiceActivityDetector {
    private let manager: VadManager
    private var state: VadStreamState
    private var chunker: SampleChunker

    init(manager: VadManager) {
        self.manager = manager
        self.state = .initial()
        self.chunker = SampleChunker(size: VadManager.chunkSize)
    }

    /// - Parameter samples: canonical 16 kHz mono. Nothing here can check that,
    ///   and handing it another rate does not fail - it produces boundaries on
    ///   a clock running at the wrong speed, which is the kind of wrongness
    ///   that reads as a model doing badly. The pump converts before this is
    ///   called, and that is the one place the rate is decided.
    func detect(_ samples: [Float]) async throws -> [SpeechBoundary] {
        var boundaries: [SpeechBoundary] = []
        let chunks = chunker.take(samples)
        for (index, chunk) in chunks.enumerated() {
            let result: VadStreamResult
            do {
                result = try await manager.processStreamingChunk(
                    chunk, state: state, config: Self.segmentation)
            } catch {
                // The clock is the count of samples this stream has been fed,
                // and the chunker has already handed these over. Losing them
                // would put every later boundary early by that much for the
                // rest of the session - and the pump keeps feeding after a
                // failed detection on purpose, so nothing else would notice.
                //
                // Not covered by a test: reaching it needs a CoreML prediction
                // to fail, and this actor cannot be built without the real
                // model. The arithmetic is checked against the library instead
                // - `processStreamingChunk` advances `processedSamples` by the
                // chunk length it is handed, and every chunk here is exactly
                // `chunker.size` long.
                state.processedSamples += (chunks.count - index) * chunker.size
                throw error
            }
            state = result.state
            guard let event = result.event else { continue }
            boundaries.append(SpeechBoundary(
                kind: event.isStart ? .start : .end,
                // From the sample index, never from `event.time`: see the
                // header. The divisor is FluidAudio's own constant, so the
                // clock here is the one their state machine counted on.
                seconds: Double(event.sampleIndex) / Double(VadManager.sampleRate)))
        }
        return boundaries
    }

    func reset() async {
        state = .initial()
        chunker.reset()
    }

    /// The library's defaults, named here because two of the fields decide what
    /// a boundary means and both are worth knowing at the call site.
    ///
    /// `minSilenceDuration` (0.75 s) is how long the room has to stay quiet
    /// before an ending is reported - so an ending always arrives at least that
    /// late, carrying a timestamp that is already in the past. Nothing
    /// downstream may treat a boundary as "now".
    ///
    /// `speechPadding` (0.1 s) is added to each end and subtracted from each
    /// start, so a boundary deliberately overshoots the speech by a tenth of a
    /// second on both sides. That is the right direction for the two things
    /// boundaries are used for here: a segment that keeps its own first
    /// syllable, and a refinement span with a little air around it.
    private static let segmentation = VadSegmentationConfig.default
}
