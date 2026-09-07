// MLXEngine.swift - `mlx.*`, a model running in another process.
//
// The fourth backend, and the only one whose model is not in this address
// space. What that buys is stated in the plan: mlx-audio-swift's API churns,
// its OS floor moves, and one of its loaders deletes the directory it was asked
// to read. All of that is now behind a five-call protocol in a binary that can
// be absent, and this engine is the part that knows what a catalog row is.
//
// So the division of labor is deliberate and one-directional. The helper loads
// a directory and turns samples into spans. Everything else - which row, where
// its files come from, how they are downloaded, what "installed" means, how a
// long recording is cut, where a chunk's timestamps belong in the recording,
// what language the model was asked for, and when to give up - stays here,
// because `speech` already owns all of it for three other engines.
//
// THE ROWS ARE NOT OFFERED UNTIL THEY ARE MEASURED. This engine exists so that
// stage 4B.5 can produce numbers; whether any `mlx` row is worth showing a user
// is what those numbers decide, and 4B.6 says explicitly that failing that gate
// removes the rows and keeps the instrument.

import Foundation
import SpeechCore
import SpeechMLXProtocol

actor MLXEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities
    private nonisolated let check: ModelCompletenessCheck
    nonisolated var completenessCheck: ModelCompletenessCheck? { check }

    private let spec: EngineSpec
    private let row: MLXRow
    private let store: ModelStore
    private let segmenter: any AudioSegmenter
    private let timeouts: MLXHelperConnection.Timeouts
    private let locate: @Sendable () -> Result<URL, MLXHelperError>

    private var runner: MLXHelperRunner?
    private var loaded: MLXResponse.Loaded?
    /// The language that was sent with `load`, which for some model types is
    /// what the decoder was configured with. See `prepare`.
    private var loadedLanguage: String?
    /// The in-flight start, so two `prepare` calls load once. The protocol
    /// documents `prepare` as idempotent and `GGMLEngine` implements it this
    /// way; without it a second call that arrives before the first has finished
    /// its handshake spawns a second helper and loads the weights twice, and
    /// whichever finishes last wins - leaving the other process reachable only
    /// through a deinit.
    private var starting: Task<Void, Error>?
    /// Transcriptions that have not returned. `unload` waits for them: an actor
    /// is reentrant, so without this an `unload` arriving between two chunks of
    /// one call would shut the helper down underneath the rest of it.
    private var activeTranscriptions = 0
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []
    /// Why the session ended, when it ended badly. Kept so the next call says
    /// what happened rather than "prepare() was not called".
    private var sessionFailure: String?
    /// Request ids are unique for the life of the session and never reused, so
    /// a reply that arrives late is a reply that matches nothing rather than a
    /// reply that matches the wrong buffer.
    private var nextRequestID = 1
    /// Highest helper footprint seen so far. Kept here rather than read on
    /// demand because the kernel's ledger goes with the process, and the caller
    /// asks for this after a run rather than during one.
    private var peakHelperBytes: Int64?

    init(
        spec: EngineSpec,
        row: MLXRow,
        segmenter: any AudioSegmenter,
        timeouts: MLXHelperConnection.Timeouts = MLXHelperConnection.Timeouts(),
        locate: @escaping @Sendable () -> Result<URL, MLXHelperError> = {
            MLXHelperProcess.locate()
        }
    ) {
        self.spec = spec
        self.row = row
        self.id = spec.catalogID
        self.store = ModelStore(root: spec.modelsDirectory)
        self.segmenter = segmenter
        self.timeouts = timeouts
        self.locate = locate
        // Row-aware, so the check knows which files this row actually fetched.
        self.check = { MLXCatalog.isComplete($0, row: row) }
        self.capabilities = EngineCapabilities(
            batch: true,
            // The protocol has no streaming primitive, and adding one would be
            // a protocol change rather than an engine change. `speech stream`
            // therefore refuses these rows by name, in makeLiveSession.
            live: false,
            // mlx-audio-swift returns no word-level alignment for any of the
            // eight types the helper implements.
            wordTimestamps: false,
            segmentTimestamps: row.segmentTimestamps,
            vocabulary: false,
            diarization: false,
            languageID: row.languageID,
            languageHint: true,
            languages: row.languages,
            minimumMacOS: "15.0")
    }

    // MARK: - Preparing

    /// Starts a helper and loads the weights. Never fetches - see `install`.
    ///
    /// The language is part of the load, and `transcribe` is where a change to
    /// it is noticed - not here. `Evaluator` calls this once per DISTINCT
    /// language in a manifest, before any row runs, as a validation pass: what
    /// it is checking is that the engine can serve each of them at all. It is
    /// not asking for the engine to end up in any particular state, and it
    /// could not, since the last call would win. So this loads once and
    /// validates; the row's own language is applied where the row is.
    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        if runner == nil {
            if let starting {
                try await starting.value
            } else {
                let task = Task { try await start(language: language, progress: progress) }
                starting = task
                defer { starting = nil }
                try await task.value
            }
        }
        return try resolveLanguage(language)
    }

    /// Whether a new language means the weights have to be read again.
    private func needsReloadFor(_ requested: String?) -> Bool {
        guard let loaded, loaded.languageHint else { return false }
        let wanted = requested.flatMap { $0.isEmpty ? nil : Language.canonical($0) }
        let have = loadedLanguage.flatMap { $0.isEmpty ? nil : Language.canonical($0) }
        return wanted?.caseInsensitiveCompare(have ?? "") != .orderedSame
            && !(wanted == nil && have == nil)
    }

    private func start(language: String?, progress: @escaping LoadProgressHandler) async throws {
        // The helper is checked before the weights, and the order is the
        // answer to "which of these should a user hear about first". A missing
        // helper is a property of the build and applies to every mlx row; a
        // missing model is one row's download. Reporting the download first
        // would send someone to fetch 2.5 GB for a row that still could not
        // run afterwards.
        let executable: URL
        switch locate() {
        case .success(let url):
            executable = url
        case .failure(let error):
            throw SpeechError.unavailable("'\(id)' needs the MLX helper: \(error)")
        }

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

        progress(LoadProgress(phase: .compiling, file: MLXHelperProcess.executableName))
        let runner: MLXHelperRunner
        do {
            runner = try MLXHelperRunner(executable: executable, timeouts: timeouts)
        } catch let error as MLXHelperError {
            throw SpeechError.unavailable("'\(id)' could not start the MLX helper: \(error)")
        }

        do {
            // The handshake is the availability check, and it is the only one
            // worth making: the helper emits it after a real MLX operation, so
            // a build that cannot reach the GPU or has lost its Metal library
            // fails here rather than in the middle of a measurement.
            let hello = try await runner.handshake()
            guard hello.types.contains(row.type) else {
                await runner.shutdown()
                throw SpeechError.unavailable(
                    "the MLX helper does not implement '\(row.type)'"
                    + " (it has: \(hello.types.sorted().joined(separator: ", ")))")
            }
            progress(LoadProgress(phase: .compiling, file: spec.directory.lastPathComponent))
            // The type is sent rather than left to the helper to work out. The
            // NeMo configs the Parakeet rows ship name no architecture at all,
            // and the helper's fallback is the directory name - which is a
            // naming convention, and this row is a fact.
            self.loaded = try await runner.load(
                directory: spec.directory, type: row.type, language: language)
            self.loadedLanguage = language
            self.runner = runner
            self.helperGeneration += 1
            self.sessionFailure = nil
        } catch let error as MLXHelperError {
            let said = await runner.standardErrorTail()
            await runner.shutdown()
            throw Self.speechError(from: error, id: id, said: said)
        } catch {
            await runner.shutdown()
            throw error
        }
    }

    /// What was sent with the last `load`. For the tests: whether a language
    /// reached the helper is not observable from outside otherwise, and it is
    /// the thing that silently goes wrong.
    var loadedHelperLanguage: String? { loadedLanguage }

    /// Counts helpers started. A reload is the only thing that moves it, so a
    /// test can assert that one did or did not happen.
    private(set) var helperGeneration = 0

    // MARK: - Transcribing

    /// One buffer in, its spans out - reloading first if this row's language is
    /// not the one the helper was loaded with.
    ///
    /// THE RELOAD IS WHY THIS IS NOT JUST A SEND. The protocol has no
    /// per-request language: the hint goes with `load`, and
    /// `loaded.language_hint` says whether the model's decoder reads it -
    /// Whisper's does. `Evaluator` prepares each distinct language up front and
    /// then transcribes rows in order, so whatever the last prepare loaded is
    /// what every row would otherwise get. On a mixed-language corpus that
    /// means decoding the Polish rows with a model told to expect English while
    /// labeling the segments "pl", and a measuring tool that does that reports
    /// a WER which looks like a result and is not.
    ///
    /// For a model whose decoder ignores the hint - the Parakeet rows, which
    /// report `language_hint: false` - nothing reloads, because nothing would
    /// change. For one that reads it, a manifest that alternates languages row
    /// by row pays a weight load per change; grouping the rows by language
    /// costs one load per language instead, and nothing here reorders a
    /// manifest, because the row order is what the report prints.
    ///
    /// A reload is a new helper process rather than a second `load` into the
    /// running one, even though the protocol allows that and the helper
    /// implements it by unloading first. A fresh process cannot carry anything
    /// from the previous language, and nothing on this side could check that it
    /// had not.
    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        if runner != nil, needsReloadFor(options.language) {
            await unload()
            try await start(language: options.language, progress: { _ in })
        }
        guard let runner else {
            throw SpeechError.runtime(
                sessionFailure.map { "'\(id)': the helper session ended - \($0)" }
                    ?? "'\(id)': prepare() was not called")
        }
        let language = try resolveLanguage(options.language)

        activeTranscriptions += 1
        defer {
            activeTranscriptions -= 1
            if activeTranscriptions == 0 {
                let waiting = unloadWaiters
                unloadWaiters = []
                for continuation in waiting { continuation.resume() }
            }
        }

        // Every row has a ceiling, and `MLXCatalogTests` asserts that none can
        // lose one: a row without it is a row whose memory is set by the length
        // of the file a user opens, which one hour of speech through Parakeet
        // measured at 21.91 GB. Zero still means no ceiling, because that is
        // what the field's default is and a caller can build a row by hand.
        let cap = row.maxSeconds > 0 ? row.maxSeconds : .infinity
        let ranges = try await segmenter.split(samples: samples, maxSeconds: cap)

        var segments: [Segment] = []
        for range in ranges {
            try Task.checkCancellation()
            guard range.count > 0 else { continue }
            let piece = range.start == 0 && range.end == samples.count
                ? samples
                : Array(samples[range.start..<range.end])

            let requestID = nextRequestID
            nextRequestID += 1
            let result: MLXTranscription
            do {
                result = try await withTaskCancellationHandler {
                    try await runner.transcribe(
                        id: requestID, samples: piece, chunkSeconds: row.chunkSeconds)
                } onCancel: {
                    // There is no cancel request, by design: MLX generation is
                    // a synchronous call that does not come back early, so a
                    // message would arrive only once it no longer mattered.
                    // Killing is the documented answer, and the pid it kills is
                    // checked against the one it started.
                    runner.kill()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MLXHelperError {
                if Task.isCancelled { throw CancellationError() }
                let said = await runner.standardErrorTail()
                // Some of these end the session and some do not, and the
                // difference decides what the next 699 rows of a split do. A
                // refusal is this buffer's problem; a closed connection, a
                // timeout or a desynchronized stream means the conversation is
                // over, and leaving `runner` in place would fail every
                // remaining row against the same dead process rather than
                // letting a caller start a new one.
                switch error {
                case .closed, .timedOut, .protocolViolation, .io, .spawnFailed, .notFound:
                    if let footprint = runner.peakFootprintBytes() {
                        peakHelperBytes = max(peakHelperBytes ?? 0, footprint)
                    }
                    sessionFailure = "\(error)"
                    self.runner = nil
                    self.loaded = nil
                    self.loadedLanguage = nil
                    await runner.shutdown()
                case .refused:
                    break
                }
                throw Self.speechError(from: error, id: id, said: said)
            }

            // Sampled here, with the helper certainly alive. Reading it once at
            // the end would read nothing at all for a row that unloads first.
            if let footprint = runner.peakFootprintBytes() {
                peakHelperBytes = max(peakHelperBytes ?? 0, footprint)
            }

            segments.append(contentsOf: Self.segments(
                from: result,
                offset: range.startSeconds,
                firstID: segments.count,
                language: language))
        }
        return segments
    }

    /// Spans from one buffer, placed where that buffer was in the recording.
    ///
    /// The helper is never told where its buffer came from - it reports seconds
    /// from the start of what it was handed - so this is the only place that
    /// can put a chunk back in the file it came out of.
    static func segments(
        from result: MLXTranscription, offset: Double, firstID: Int, language: String?
    ) -> [Segment] {
        // Filtered first, then numbered. The caller's next chunk starts at the
        // count of what came back, so numbering before the filter leaves a hole
        // - three spans with a blank second one give ids 0 and 2, and the next
        // chunk starts at 2 again. No helper sends a blank span today; the
        // contract admits one, and the tests hand it one.
        result.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.enumerated().map { index, event in
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Segment(
                id: firstID + index,
                start: offset + event.start,
                end: offset + event.end,
                text: text,
                // No word alignment comes back from any of the eight types.
                words: nil,
                confidence: nil,
                speaker: nil,
                language: language)
        }
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        throw SpeechError.unavailable(
            "'\(id)' cannot stream: the MLX helper protocol has no streaming request."
            + " Run 'speech engines' and pick a row with the 'live' flag")
    }

    // MARK: - Languages

    /// The language this run will use.
    ///
    /// The loaded model has the first word and the catalog row the second. That
    /// order is not the usual one for this project - elsewhere the loaded model
    /// is the only authority - and the reason is that these checkpoints often
    /// name no languages at all: the NeMo configs the Parakeet rows ship carry
    /// no language list, so `loaded.languages` is empty, and empty means "the
    /// files do not say" rather than "none". Falling through to the row's list
    /// is what keeps `--language pl` validated for a model that supports 25
    /// languages and admits to none of them.
    private func resolveLanguage(_ requested: String?) throws -> String? {
        let supported = (loaded?.languages).flatMap { $0.isEmpty ? nil : $0 } ?? row.languages
        guard let raw = requested, !raw.isEmpty else {
            // A row that cannot identify the spoken language and has more than
            // one to choose between will pick one, and the failure that follows
            // is a fluent transcript in the wrong language rather than an
            // error. No row here trips this today; the rule is what stops the
            // first one that does from being discovered by a user.
            guard row.languageID || supported.count <= 1 else {
                throw SpeechError.usage(
                    "'\(id)' cannot detect the spoken language, so it needs one:"
                    + " pass --language <tag> (has: \(supported.joined(separator: ", ")))")
            }
            return nil
        }
        guard !supported.isEmpty else { return raw }
        guard let match = Language.match(raw, in: supported) else {
            throw SpeechError.unsupportedLanguage(
                "'\(id)' does not support '\(raw)' (has: \(supported.joined(separator: ", ")))")
        }
        return match
    }

    // MARK: - Installing

    /// Fetches the row's files. Only `speech models download` calls this.
    ///
    /// The helper never downloads anything, which is the rule that keeps
    /// `ModelUtils.resolveOrDownloadModel` - which deletes the directory it was
    /// asked to read when it judges the contents incomplete - away from a store
    /// holding a user's weights.
    func install(progress: @escaping LoadProgressHandler) async throws {
        var listings: [String: [HFRepoFile]] = [:]
        for asset in row.assets where listings[asset.repo] == nil {
            progress(LoadProgress(phase: .listing, file: asset.repo))
            listings[asset.repo] = try await HuggingFace.tree(repo: asset.repo)
        }

        // Everything is checked before the marker goes down, so a row naming a
        // file that has been renamed upstream fails without leaving a partial
        // install behind.
        var wanted: [(asset: MLXAsset, entry: HFRepoFile)] = []
        for asset in row.assets {
            let listing = listings[asset.repo] ?? []
            guard let entry = listing.first(where: { $0.path == asset.file }) else {
                // "did not list" rather than "does not have": the tree API
                // answers one page, so this is what came back and not
                // necessarily everything the repository holds.
                throw SpeechError.runtime(
                    "\(asset.repo) did not list '\(asset.file)';"
                    + " it listed \(listing.map(\.path).sorted().joined(separator: ", "))")
            }
            wanted.append((asset, entry))
        }

        let directory = try store.beginInstall(spec)
        for (asset, entry) in wanted {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(asset.file, isDirectory: false)
            // An interrupted install leaves the finished files in place - the
            // marker is what says the row is not done, and `beginInstall` does
            // not clear the directory - so a retry that re-fetched everything
            // would download 2.5 GB again to replace the 2.5 GB already there.
            // A destination file only exists at all once the transfer finished
            // and its object id checked out; the temporary is what a partial
            // one leaves behind, and the client resumes that itself.
            if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path),
               (existing[.size] as? NSNumber)?.int64Value == entry.size
            {
                progress(LoadProgress(phase: .installing, file: asset.file))
                continue
            }
            try await HuggingFace.download(
                repo: asset.repo, file: asset.file,
                to: destination,
                expectedSize: entry.size, oid: entry.oid, progress: progress)
        }
        progress(LoadProgress(phase: .installing, file: spec.directory.lastPathComponent))
        try store.finishInstall(spec, isComplete: check)
    }

    /// The helper's peak footprint, sampled after each buffer so the number
    /// survives the process it describes.
    func peakOutOfProcessMemoryBytes() async -> Int64? { peakHelperBytes }

    func unload() async {
        // An actor is reentrant, so this can arrive between two chunks of a
        // transcription that is still running. Tearing the helper down under it
        // would throw away every segment that call had already collected.
        if activeTranscriptions > 0 {
            await withCheckedContinuation { unloadWaiters.append($0) }
        }
        guard let runner else { return }
        self.runner = nil
        self.loaded = nil
        self.loadedLanguage = nil
        // `unload` first so the helper drops the weights and clears MLX's
        // cache while it is still alive to do it; `shutdown` then ends the
        // process. A helper that has already died fails both, which is the
        // state we wanted anyway.
        try? await runner.unload()
        await runner.shutdown()
    }

    // MARK: - Errors

    static func speechError(from error: MLXHelperError, id: String, said: String) -> SpeechError {
        let detail = said.isEmpty ? "" : " The helper said: \(said)"
        switch error {
        case .notFound, .spawnFailed:
            return .unavailable("'\(id)': \(error)\(detail)")
        case .refused, .timedOut, .closed, .protocolViolation, .io:
            return .runtime("'\(id)': \(error)\(detail)")
        }
    }
}
