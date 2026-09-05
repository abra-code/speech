// GGMLEngine.swift - `ggml.*`, transcribe.cpp's ggml runtime on Metal.
//
// The third backend, and the one with the least to hide. FluidAudio needed a
// file of path conventions before a model would load; here a row is one GGUF,
// `Model(path:)` loads it, and the library reports its own capabilities. What
// this engine owns is the three places where that simplicity runs out.
//
// **The audio ceiling.** Several families refuse a run longer than
// `capabilities.maxAudioMs` with `inputTooLong` rather than degrading, so a
// long file has to arrive in pieces with the transcripts stitched back and the
// timestamps offset. The cut points come from an `AudioSegmenter` injected by
// the caller, which is why this target does not depend on SpeechFluid.
//
// **The language gate.** Some families have no language identification at all,
// and the library's answer to a missing hint is a default, not an error - which
// means Polish audio comes back as confident English prose. So a row that
// cannot detect its own language refuses to prepare without one.
//
// **The exit assert.** ggml's Metal device is torn down by a C++ static
// destructor at process exit, and it asserts if any model still holds device
// buffers at that moment - `GGML_ASSERT([rsets->data count] == 0) failed`,
// printed as a native backtrace over whatever the program was really doing. A
// loaded model must therefore be released before the process ends, which is
// what `unload()` is for and why `transcribe` and `eval` call it on their
// failure paths as well as their success paths.
//
// `unload()` is not a guarantee that the memory is back the moment it returns:
// an actor is reentrant, so it can run while a `transcribe` is suspended on a
// decode, and that call holds its own strong reference to the session until it
// finishes. It drops this engine's references; the last one wins.

import Foundation
import SpeechCore
import TranscribeCpp

actor GGMLEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities
    private nonisolated let check: ModelCompletenessCheck
    nonisolated var completenessCheck: ModelCompletenessCheck? { check }

    private let spec: EngineSpec
    private let row: GGMLRow
    private let quant: String
    private let store: ModelStore
    private let segmenter: any AudioSegmenter

    /// nil until `prepare`. The session is bound to the model and both are
    /// dropped together, because the C contract allows one in-flight run per
    /// model and there is no reason to keep a second one around.
    private var model: Model?
    private var session: GGMLSession?
    /// What the loaded model actually said about itself. The catalog's copy is
    /// advisory; this one gates.
    private var loaded: Capabilities?
    private var loading: Task<Void, Error>?

    init(spec: EngineSpec, row: GGMLRow, quant: String, segmenter: any AudioSegmenter) {
        self.spec = spec
        self.row = row
        self.quant = quant
        self.id = spec.catalogID
        self.store = ModelStore(root: spec.modelsDirectory)
        self.segmenter = segmenter
        self.check = GGMLCatalog.isComplete
        self.capabilities = EngineCapabilities(
            batch: true,
            // Streaming families exist (Parakeet Unified, Nemotron, Voxtral
            // Realtime, Moonshine) and `Session.stream` is right there, but live
            // mode is stage 4 for every engine at once. Claiming it here would
            // let the applet enable a Record button that throws.
            live: false,
            wordTimestamps: row.wordTimestamps,
            segmentTimestamps: row.segmentTimestamps,
            // transcribe.cpp has no hotword or biasing surface anywhere in its
            // API - not a gap in this wrapper, an absence in the library.
            vocabulary: false,
            diarization: false,
            languageID: row.languageID,
            languageHint: true,
            languages: row.languages,
            // transcribe.cpp itself declares macOS 13, but the binary's floor is
            // 15, and a row cannot name a system it can never be reached on.
            minimumMacOS: "15.0")
    }

    // MARK: - Lifecycle

    private var weightsURL: URL {
        get throws {
            try store.directory(for: spec)
                .appendingPathComponent(GGMLCatalog.weightsName, isDirectory: false)
        }
    }

    /// Loads already-downloaded weights. Never fetches - see `install`.
    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        if model == nil {
            if let loading {
                try await loading.value
            } else {
                let task = Task { try await load(progress: progress) }
                loading = task
                defer { loading = nil }
                try await task.value
            }
        }
        // Checked after the load, not before, because the authority is the
        // model's own list and that does not exist until it is open.
        return try resolveLanguage(language)
    }

    private func load(progress: @escaping LoadProgressHandler) async throws {
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

        let path = try weightsURL.path
        progress(LoadProgress(phase: .compiling, file: GGMLCatalog.weightsName))
        try GGMLRuntime.start()

        let loadedPair: (model: Model, session: GGMLSession)
        do {
            loadedPair = try await GGMLSession.load(
                path: path, backend: GGMLRuntime.backend, label: id)
        } catch {
            throw SpeechError.runtime(
                "cannot load '\(id)' from \(path): \(Self.describe(error))")
        }
        self.model = loadedPair.model
        self.session = loadedPair.session
        self.loaded = loadedPair.model.capabilities
    }

    /// The language this run will use, spelled the way this model spells it.
    ///
    /// Three failures are worth separating, and the third is the one that cost
    /// a debugging session. A row with no language identification and no hint
    /// is a *usage* problem: Canary given Polish audio and no hint does not
    /// fail, it returns fluent English prose about the same subject, because a
    /// missing source language turns its prompt into a translation request. A
    /// hint the model does not carry is an unsupported language, a different
    /// exit code. And a hint the model carries under a different *spelling* is
    /// neither - it is the caller being right and the string being wrong.
    ///
    /// That last one is not hypothetical or cosmetic. Measured on these
    /// weights: `nemotron-3.5-asr-streaming-0.6b` accepts `pl-PL` and rejects
    /// `pl` with "unsupported language", while `canary-1b-v2`, `qwen3-asr` and
    /// `whisper-large-v3-turbo` accept `pl` and reject `pl-PL`. So normalizing
    /// to a primary subtag breaks one half of the catalog and passing the
    /// caller's tag through unchanged breaks the other. The only thing that
    /// works for both is to hand back the model's own string.
    private func resolveLanguage(_ requested: String?) throws -> String? {
        let supported = loaded?.languages ?? []
        guard let raw = requested, !raw.isEmpty else {
            if loaded?.supportsLanguageDetect == true { return nil }
            throw SpeechError.usage(
                "'\(id)' cannot detect the spoken language, so it needs one:"
                + " pass --language <tag>"
                + (supported.isEmpty ? "" : " (has: \(supported.joined(separator: ", ")))"))
        }
        // A model that declares no languages is language-agnostic as far as
        // this program can tell; pass the caller's tag through and let the
        // library have the final word rather than inventing a gate.
        guard !supported.isEmpty else { return raw }
        guard let match = Self.matchLanguage(raw, in: supported) else {
            throw SpeechError.unsupportedLanguage(
                "'\(id)' does not support '\(raw)' (has: \(supported.joined(separator: ", ")))")
        }
        return match
    }

    /// The model's own spelling of a requested language, or nil if it has none.
    ///
    /// Prefers an exact tag, then a bare primary subtag, then the first
    /// regional variant of the same language - so `pt-BR` finds itself where
    /// the model lists both Brazilian and European Portuguese, and a bare `pt`
    /// lands on whichever the model names first rather than being refused.
    static func matchLanguage(_ requested: String, in supported: [String]) -> String? {
        let canonical = Language.canonical(requested)
        if let exact = supported.first(where: {
            $0.caseInsensitiveCompare(canonical) == .orderedSame
        }) {
            return exact
        }
        let primary = Language.primarySubtag(requested)
        guard !primary.isEmpty else { return nil }
        if let bare = supported.first(where: {
            $0.caseInsensitiveCompare(primary) == .orderedSame
        }) {
            return bare
        }
        return supported.first { Language.primarySubtag($0) == primary }
    }

    /// Fetches the weights. Only `speech models download` calls this.
    func install(progress: @escaping LoadProgressHandler) async throws {
        let file = row.fileName(quant: quant)
        progress(LoadProgress(phase: .listing, file: file))
        let listing = try await HuggingFace.tree(repo: row.repo)
        guard let entry = listing.first(where: { $0.path == file }) else {
            // Deliberately "did not list" rather than "has no": the tree API
            // answers one page, so this listing is what was returned and not
            // necessarily everything the repository holds.
            throw SpeechError.runtime(
                "\(row.repo) did not list '\(file)';"
                + " it listed \(listing.map(\.path).sorted().joined(separator: ", "))")
        }

        // The marker goes down before the first byte, so an interrupted install
        // reads as partial and not as a row that is merely small.
        let directory = try store.beginInstall(spec)
        let destination = directory.appendingPathComponent(
            GGMLCatalog.weightsName, isDirectory: false)
        try await HuggingFace.download(
            repo: row.repo, file: file, to: destination,
            expectedSize: entry.size, oid: entry.oid, progress: progress)
        progress(LoadProgress(phase: .installing, file: file))
        try store.finishInstall(spec, isComplete: check)
    }

    func unload() async {
        // Order matters: the session holds a strong reference to the model, so
        // dropping the model first would free nothing.
        session = nil
        model = nil
        loaded = nil
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [SpeechCore.Segment] {
        guard let session, let loaded else {
            throw SpeechError.runtime("'\(id)': prepare() was not called")
        }
        guard !samples.isEmpty else { return [] }

        let language = try resolveLanguage(options.language)
        let kind = Self.timestampKind(
            wantWords: options.wantWordTimestamps && row.wordTimestamps,
            ceiling: loaded.maxTimestampKind)
        let runOptions = RunOptions(
            timestamps: kind,
            language: language,
            specKDrafts: -1)

        // `maxAudioMs == 0` means no practical limit, which is the common case;
        // the segmenter then returns one range and this is a plain single run.
        let cap = loaded.maxAudioMs > 0 ? Double(loaded.maxAudioMs) / 1000 : .infinity
        let ranges = try await segmenter.split(samples: samples, maxSeconds: cap)

        var segments: [SpeechCore.Segment] = []
        for range in ranges {
            try Task.checkCancellation()
            guard range.count > 0 else { continue }
            let piece = range.start == 0 && range.end == samples.count
                ? samples
                : Array(samples[range.start..<range.end])
            let transcript: Transcript
            do {
                transcript = try await session.run(piece, options: runOptions)
            } catch let error as TranscribeError {
                // A cancelled run is a cancellation, not a transcription
                // failure: the partial the library preserved is discarded on
                // purpose, because a caller that pressed Ctrl-C is not asking
                // for half a transcript to be written over the whole one.
                if case .aborted = error, Task.isCancelled { throw CancellationError() }
                throw SpeechError.runtime("'\(id)' failed to transcribe: \(Self.describe(error))")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SpeechError.runtime("'\(id)' failed to transcribe: \(Self.describe(error))")
            }
            segments.append(contentsOf: Self.segments(
                from: transcript,
                offset: range.startSeconds,
                fallbackEnd: range.endSeconds,
                firstID: segments.count,
                language: language))
        }
        return segments
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        throw SpeechError.unavailable(
            "'\(id)' has no live mode in this build (arrives in stage 4)")
    }

    // MARK: - Mapping

    /// What to ask for, never more than the model can give.
    ///
    /// Requesting a finer granularity than `maxTimestampKind` is a documented
    /// way to earn `UNSUPPORTED_TIMESTAMPS` from some families, and asking
    /// Whisper for word timings would fail a run that had every reason to
    /// succeed. `.auto` as a ceiling means "the richest this model has", so it
    /// imposes no clamp of its own.
    static func timestampKind(wantWords: Bool, ceiling: TimestampKind) -> TimestampKind {
        func rank(_ kind: TimestampKind) -> Int {
            switch kind {
            case .none: return 0
            case .segment: return 1
            case .word: return 2
            case .token, .auto: return 3
            }
        }
        let wanted: TimestampKind = wantWords ? .word : .segment
        return rank(wanted) <= rank(ceiling) ? wanted : ceiling
    }

    /// transcribe.cpp's transcript to ours, shifted by where its audio started.
    ///
    /// Word ranges come from each segment's `firstWord`/`nWords` rather than by
    /// matching text, and they are bounds-checked: the indices are `Int32` from
    /// a C struct, and a family that reports a range past the end of the array
    /// would otherwise crash the process rather than produce a slightly wrong
    /// transcript.
    static func segments(
        from transcript: Transcript, offset: Double, fallbackEnd: Double,
        firstID: Int, language: String?
    ) -> [SpeechCore.Segment] {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allWords = transcript.words.map {
            SpeechCore.Word(
                text: $0.text,
                start: offset + Double($0.t0Ms) / 1000,
                end: offset + Double($0.t1Ms) / 1000)
        }

        guard !transcript.segments.isEmpty else {
            guard !text.isEmpty else { return [] }
            // No segmentation from the model: one segment for the piece, with
            // whatever words there were. Qwen3-ASR and Moonshine land here.
            return [SpeechCore.Segment(
                id: firstID,
                start: allWords.first?.start ?? offset,
                end: allWords.last?.end ?? fallbackEnd,
                text: text,
                words: allWords.isEmpty ? nil : allWords,
                language: language)]
        }

        var out: [SpeechCore.Segment] = []
        for segment in transcript.segments {
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = Int(segment.firstWord)
            let count = Int(segment.nWords)
            let words: [SpeechCore.Word]?
            if start >= 0, count > 0, start + count <= allWords.count {
                words = Array(allWords[start..<(start + count)])
            } else {
                words = nil
            }
            guard !body.isEmpty || words?.isEmpty == false else { continue }
            // Keep the segment inside the audio it came from, and never let it
            // end before it starts.
            //
            // Two real cases, both of which the no-segments branch above
            // already handled and this one could not reach. A family that
            // reports segments while declaring `.none` timestamps gives every
            // one `t0Ms == t1Ms == 0`, which on a chunked file is a run of
            // zero-length cues all sitting at their chunk boundary; falling
            // back to the piece's own extent is the same repair the other
            // branch makes. And Whisper routinely ends its last segment past
            // the real audio, by up to its 30 s window, which on a chunked file
            // makes chunk N overlap chunk N+1 and puts the cues out of order.
            let rawStart = offset + Double(segment.t0Ms) / 1000
            let rawEnd = offset + Double(segment.t1Ms) / 1000
            let clampedStart = min(max(rawStart, offset), fallbackEnd)
            let clampedEnd = segment.t1Ms > segment.t0Ms
                ? min(max(rawEnd, clampedStart), fallbackEnd)
                : max(words?.last?.end ?? fallbackEnd, clampedStart)
            out.append(SpeechCore.Segment(
                // Numbered from what has been emitted, not from the position in
                // the model's list: the guard above can skip a segment, and the
                // caller passes the running emitted count as `firstID`. Using
                // the offered index made chunk two reuse an id chunk one had
                // already used, and `Segment.id` is the applet's transcript-row
                // key - a duplicate overwrites a row instead of appending.
                id: firstID + out.count,
                start: clampedStart,
                end: clampedEnd,
                text: body,
                words: words,
                speaker: segment.speakerId > 0 ? Int(segment.speakerId) : nil,
                language: language))
        }
        return out
    }

    /// `TranscribeError` has no `LocalizedError` conformance, so
    /// `localizedDescription` on it produces "The operation couldn't be
    /// completed" and throws away the native message the library went to the
    /// trouble of building.
    static func describe(_ error: Error) -> String {
        guard let error = error as? TranscribeError else { return error.localizedDescription }
        switch error {
        case .invalidArgument(let m), .notImplemented(let m), .modelFileNotFound(let m),
             .modelLoad(let m), .outOfMemory(let m), .backend(let m), .unsupported(let m),
             .badStructSize(let m), .inputTooLong(let m), .versionMismatch(let m), .busy(let m):
            return m
        case .aborted(let m, _), .outputTruncated(let m, _):
            return m
        case .other(let status, let message):
            return "\(message) (status \(status))"
        }
    }
}

/// Process-wide transcribe.cpp setup.
///
/// `initBackends` is a scan the library expects once, and the log sink it
/// installs is documented as startup-only. Both are done here behind a flag so
/// that constructing several engines - which `speech engines` does - does not
/// re-scan the devices or reinstall the sink.
enum GGMLRuntime {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var started = false
    private nonisolated(unsafe) static var resolved: Backend = .auto

    /// The backend to load models on. Metal on every Mac this binary runs on;
    /// `.auto` is the honest answer if it is ever missing, rather than a hard
    /// failure on a machine that could still decode on the CPU.
    static var backend: Backend {
        lock.withLock { resolved }
    }

    static func start() throws {
        try lock.withLock {
            guard !started else { return }
            // ggml writes its device probe to stderr at info level. That is
            // twenty lines in front of a user who asked for a transcript, and
            // under --json it would interleave with the event stream, so the
            // sink is installed and silent unless SPEECH_GGML_LOG is set.
            if ProcessInfo.processInfo.environment["SPEECH_GGML_LOG"] != nil {
                Transcribe.setLogHandler { level, message in
                    FileHandle.standardError.write(Data("[ggml \(level)] \(message)\n".utf8))
                }
            } else {
                Transcribe.disableLogging()
            }
            try Transcribe.ensureCompatible()
            try Transcribe.initBackends()
            resolved = Transcribe.backendAvailable(.metal) ? .metal : .auto
            // Last, and only on the way out. Setting it first meant that a
            // throwing `ensureCompatible` or `initBackends` still latched the
            // flag, so every later attempt in the same process took the
            // `guard !started` early return and called `Model(path:)` against a
            // ggml build with no registered backends. Harmless for a CLI that
            // exits on the first failure; not harmless for Speech.app, which
            // retries.
            started = true
        }
    }
}
