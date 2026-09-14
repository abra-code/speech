// Events.swift - the JSONL protocol (appendix B of the development plan).
//
// One JSON object per line on stdout under --json. Every line carries `type`
// and `t` (seconds since process start) first, then the payload's own fields,
// flat - not nested under a "data" key. Flat because the applet's poller reads
// these with a shell and `sed`-grade tooling in places, and one level of nesting
// there costs more than it saves.
//
// The flattening works by encoding the header into the same keyed container the
// payload encodes into, which JSONEncoder merges. Decoding reads the header,
// then re-decodes the whole object as the payload type. That symmetry is what
// the round-trip test in SpeechCoreTests pins.
//
// Changing a field name here changes the wire format. docs/protocol.md must be
// updated in the same commit.

import Foundation

public struct SpeechEvent: Sendable, Equatable {
    /// Seconds since the process started, monotonic.
    public var t: Double
    public var payload: Payload

    public init(t: Double, payload: Payload) {
        self.t = t
        self.payload = payload
    }

    public enum Payload: Sendable, Equatable {
        case engineReady(EngineReady)
        case modelProgress(ModelProgress)
        case modelInstalled(ModelInstalled)
        case modelEntry(ModelEntry)
        case progress(BatchProgress)
        case segmentPartial(Segment)
        case segmentFinal(Segment)
        case segmentRefined(RefinedSegment)
        case warning(WarningEvent)
        case error(ErrorEvent)
        case done(DoneEvent)
        case evalRow(EvalRow)
        case evalSummary(EvalSummary)
        case recordingStarted(RecordingStarted)
        case recordingLevel(RecordingLevel)

        public var type: String {
            switch self {
            case .engineReady: return "engine.ready"
            case .modelProgress: return "model.progress"
            case .modelInstalled: return "model.installed"
            case .modelEntry: return "model.entry"
            case .progress: return "progress"
            case .segmentPartial: return "segment.partial"
            case .segmentFinal: return "segment.final"
            case .segmentRefined: return "segment.refined"
            case .warning: return "warning"
            case .error: return "error"
            case .done: return "done"
            case .evalRow: return "eval.row"
            case .evalSummary: return "eval.summary"
            case .recordingStarted: return "recording.started"
            case .recordingLevel: return "recording.level"
            }
        }
    }

    // MARK: - Payloads

    /// `record` has opened the device and is writing. Emitted once, after the
    /// microphone started, so a caller showing "recording" is never ahead of
    /// the hardware.
    public struct RecordingStarted: Codable, Sendable, Equatable {
        /// The file the recording will be at when it ends.
        public var output: String
        /// The input device's name and UID; nil when the system reports no
        /// default device it can name.
        public var device: String?
        public var deviceUID: String?
        /// The file's sample rate: the device's own, capped at 48 kHz for m4a.
        public var sampleRate: Double
        /// The file's channel count. Always 1: the input is mixed down.
        public var channels: Int

        public init(output: String, device: String?, deviceUID: String?, sampleRate: Double, channels: Int) {
            self.output = output
            self.device = device
            self.deviceUID = deviceUID
            self.sampleRate = sampleRate
            self.channels = channels
        }

        private enum CodingKeys: String, CodingKey {
            case output, device, channels
            case deviceUID = "device_uid"
            case sampleRate = "sample_rate"
        }
    }

    /// The input level of the audio just written, for a meter. Emitted a few
    /// times a second while recording.
    public struct RecordingLevel: Codable, Sendable, Equatable {
        /// Seconds of audio written so far.
        public var seconds: Double
        /// Root-mean-square and peak level of the samples since the previous
        /// level event, in dB relative to full scale. Floored at
        /// `RecordingLevel.floorDB` so silence stays a number JSON can carry.
        public var rmsDB: Double
        public var peakDB: Double

        public static let floorDB = -100.0

        public init(seconds: Double, rmsDB: Double, peakDB: Double) {
            self.seconds = seconds
            self.rmsDB = max(rmsDB, Self.floorDB)
            self.peakDB = max(peakDB, Self.floorDB)
        }

        private enum CodingKeys: String, CodingKey {
            case seconds
            case rmsDB = "rms_db"
            case peakDB = "peak_db"
        }
    }

    public struct EngineReady: Codable, Sendable, Equatable {
        public var engine: String
        public var model: String
        public var capabilities: EngineCapabilities
        public var loadSeconds: Double
        /// What the engine resolved the requested language to, when it is more
        /// specific: "it" reaches Apple as it_IT and "es-419" as es_ES. Omitted
        /// when the engine has nothing more specific to say.
        public var locale: String?

        public init(
            engine: String, model: String, capabilities: EngineCapabilities,
            loadSeconds: Double, locale: String? = nil
        ) {
            self.engine = engine
            self.model = model
            self.capabilities = capabilities
            self.loadSeconds = loadSeconds
            self.locale = locale
        }

        private enum CodingKeys: String, CodingKey {
            case engine, model, capabilities, locale
            case loadSeconds = "load_seconds"
        }
    }

    public struct ModelProgress: Codable, Sendable, Equatable {
        public var model: String
        public var phase: LoadProgress.Phase
        public var fraction: Double?
        public var bytesDone: Int64?
        public var bytesTotal: Int64?
        public var file: String?

        public init(model: String, progress: LoadProgress) {
            self.model = model
            self.phase = progress.phase
            self.fraction = progress.fraction
            self.bytesDone = progress.bytesDone
            self.bytesTotal = progress.bytesTotal
            self.file = progress.file
        }

        private enum CodingKeys: String, CodingKey {
            case model, phase, fraction, file
            case bytesDone = "bytes_done"
            case bytesTotal = "bytes_total"
        }
    }

    /// One row of `models list` / `models status`: what is on disk for a
    /// catalog id. Emitted once per row so a consumer reads the same stream it
    /// reads for everything else, rather than parsing a table.
    ///
    /// `modified` is deliberately absent: the rest of this protocol carries
    /// only monotonic `t` and never a wall-clock timestamp, and a download date
    /// is presentation, not a fact the applet acts on.
    public struct ModelEntry: Codable, Sendable, Equatable {
        public var model: String
        public var state: ModelInstallState
        /// The row directory. Omitted for `system_managed` rows, which have no
        /// path this tool owns.
        public var path: String?
        /// On-disk bytes. Omitted rather than zero when nothing is installed,
        /// so "not downloaded" is distinguishable from "an empty download".
        public var bytes: Int64?
        /// True when something under the row could not be read, so `bytes` is a
        /// lower bound. Omitted when false. A consumer that shows a size must
        /// qualify it, or it reports a figure smaller than what deleting the
        /// row would actually reclaim.
        public var bytesAreLowerBound: Bool?

        public init(
            model: String, state: ModelInstallState, path: String? = nil,
            bytes: Int64? = nil, bytesAreLowerBound: Bool = false
        ) {
            self.model = model
            self.state = state
            self.path = path
            self.bytes = bytes
            self.bytesAreLowerBound = bytesAreLowerBound ? true : nil
        }

        private enum CodingKeys: String, CodingKey {
            case model, state, path, bytes
            case bytesAreLowerBound = "bytes_are_lower_bound"
        }
    }

    public struct ModelInstalled: Codable, Sendable, Equatable {
        public var model: String
        /// Where the files landed. Omitted for Apple's locale assets, which are
        /// installed system-wide by the OS and have no path this tool owns.
        public var path: String?
        /// On-disk size. Omitted when it is not known: Apple publishes no size
        /// for a speech asset, and reporting 0 there would be a measurement,
        /// not a missing one.
        public var bytes: Int64?

        public init(model: String, path: String? = nil, bytes: Int64? = nil) {
            self.model = model
            self.path = path
            self.bytes = bytes
        }
    }

    public struct BatchProgress: Codable, Sendable, Equatable {
        public var fraction: Double
        public var audioSecondsDone: Double
        public var audioSecondsTotal: Double

        public init(audioSecondsDone: Double, audioSecondsTotal: Double) {
            self.audioSecondsDone = audioSecondsDone
            self.audioSecondsTotal = audioSecondsTotal
            self.fraction = audioSecondsTotal > 0
                ? min(1.0, max(0.0, audioSecondsDone / audioSecondsTotal))
                : 0
        }

        private enum CodingKeys: String, CodingKey {
            case fraction
            case audioSecondsDone = "audio_seconds_done"
            case audioSecondsTotal = "audio_seconds_total"
        }
    }

    /// A `segment.final` that a second, slower engine has rewritten. Encodes as
    /// the segment's own fields plus `refined_by`, so a reader that only knows
    /// about segments can treat it as one.
    public struct RefinedSegment: Sendable, Equatable {
        public var segment: Segment
        public var refinedBy: String

        public init(segment: Segment, refinedBy: String) {
            self.segment = segment
            self.refinedBy = refinedBy
        }
    }

    public struct WarningEvent: Codable, Sendable, Equatable {
        public var message: String
        public var code: String

        public init(message: String, code: String) {
            self.message = message
            self.code = code
        }
    }

    public struct ErrorEvent: Codable, Sendable, Equatable {
        public var message: String
        public var code: String

        public init(message: String, code: String) {
            self.message = message
            self.code = code
        }

        public init(_ error: SpeechError) {
            self.message = error.message
            self.code = error.code
        }
    }

    public struct DoneEvent: Codable, Sendable, Equatable {
        public var segments: Int
        public var audioSeconds: Double
        public var wallSeconds: Double
        /// Audio seconds per wall second. Reported rather than left to the
        /// reader because the applet shows it and the eval report compares it.
        public var rtfx: Double
        /// Peak resident size. Kept because published figures for other tools
        /// are RSS, and not the number to compare two engines with - see
        /// `peakMemoryBytes`.
        public var peakRSSBytes: Int64
        /// What the run actually cost: this process's peak footprint plus the
        /// model the Neural Engine held for it. Unlike `peakRSSBytes` this is
        /// reproducible run to run.
        ///
        /// Decoded strictly, so a log written before this field existed fails
        /// to decode rather than being read with a substituted `peakRSSBytes`.
        /// That substitution would put an unrepeatable number under the name
        /// of the repeatable one, which is the bug this field was added to
        /// fix. An old log has no measurement here, and should say so.
        public var peakMemoryBytes: Int64
        /// Present only when the run wrote a file.
        public var output: String?

        public init(
            segments: Int, audioSeconds: Double, wallSeconds: Double,
            peakRSSBytes: Int64, peakMemoryBytes: Int64, output: String? = nil
        ) {
            self.segments = segments
            self.audioSeconds = audioSeconds
            self.wallSeconds = wallSeconds
            self.rtfx = wallSeconds > 0 ? audioSeconds / wallSeconds : 0
            self.peakRSSBytes = peakRSSBytes
            self.peakMemoryBytes = peakMemoryBytes
            self.output = output
        }

        private enum CodingKeys: String, CodingKey {
            case segments, rtfx, output
            case audioSeconds = "audio_seconds"
            case wallSeconds = "wall_seconds"
            case peakRSSBytes = "peak_rss_bytes"
            case peakMemoryBytes = "peak_memory_bytes"
        }
    }

    public struct EvalRow: Codable, Sendable, Equatable {
        public var index: Int
        public var path: String
        public var reference: String
        public var hypothesis: String
        public var wer: Double
        public var cer: Double
        public var audioSeconds: Double
        public var wallSeconds: Double
        /// Present only under `eval --live`, and absent rather than zero when
        /// the run was a batch one - a `first_partial_seconds` of 0 on a batch
        /// row would read as an instant partial rather than as no live mode at
        /// all. Synthesized `encode` uses `encodeIfPresent`, so a batch row's
        /// JSON is byte for byte what it was before these existed.
        public var live: LiveRow?

        public init(
            index: Int, path: String, reference: String, hypothesis: String,
            wer: Double, cer: Double, audioSeconds: Double, wallSeconds: Double,
            live: LiveRow? = nil
        ) {
            self.index = index
            self.path = path
            self.reference = reference
            self.hypothesis = hypothesis
            self.wer = wer
            self.cer = cer
            self.audioSeconds = audioSeconds
            self.wallSeconds = wallSeconds
            self.live = live
        }

        private enum CodingKeys: String, CodingKey {
            case index, path, reference, hypothesis, wer, cer, live
            case audioSeconds = "audio_seconds"
            case wallSeconds = "wall_seconds"
        }
    }

    /// What one utterance cost when it was played to a live session in real
    /// time. Every duration is wall seconds measured from the moment the first
    /// buffer was handed over, which under 1x pacing is also the position in
    /// the audio - that equivalence is what makes these numbers latencies
    /// rather than just timings.
    public struct LiveRow: Codable, Sendable, Equatable {
        /// Time to the first `segment.partial`. Nil when the engine emitted
        /// none, which is a real answer about an engine and not a missing
        /// measurement: a live mode with no partials is a recorder with a lag.
        public var firstPartialSeconds: Double?
        /// Time to the first `segment.final`.
        public var firstFinalSeconds: Double?
        /// Wall time inside `finish()` after the audio ran out: how long the
        /// speaker waits, having stopped talking, for the rest of their words.
        public var finishSeconds: Double
        /// The worst distance between when a final arrived and the audio
        /// position it claims to end at. Negative is possible and is left
        /// signed on purpose: it means the engine dated a segment past the
        /// audio it had been given, which is a defect worth seeing rather than
        /// a zero worth hiding.
        public var maxFinalLagSeconds: Double?
        /// Reference words the transcript never reached, counted from the end.
        /// See `Scorer.trailingReferenceLoss`.
        public var trailingWordsLost: Int
        /// Capture buffers the session could not keep up with, so they were
        /// dropped exactly as the microphone path drops them. Any row with a
        /// nonzero count has a WER that is partly a measure of this machine.
        public var droppedBuffers: Int
        public var partials: Int
        public var finals: Int

        public init(
            firstPartialSeconds: Double?, firstFinalSeconds: Double?,
            finishSeconds: Double, maxFinalLagSeconds: Double?,
            trailingWordsLost: Int, droppedBuffers: Int, partials: Int, finals: Int
        ) {
            self.firstPartialSeconds = firstPartialSeconds
            self.firstFinalSeconds = firstFinalSeconds
            self.finishSeconds = finishSeconds
            self.maxFinalLagSeconds = maxFinalLagSeconds
            self.trailingWordsLost = trailingWordsLost
            self.droppedBuffers = droppedBuffers
            self.partials = partials
            self.finals = finals
        }

        private enum CodingKeys: String, CodingKey {
            case partials, finals
            case firstPartialSeconds = "first_partial_seconds"
            case firstFinalSeconds = "first_final_seconds"
            case finishSeconds = "finish_seconds"
            case maxFinalLagSeconds = "max_final_lag_seconds"
            case trailingWordsLost = "trailing_words_lost"
            case droppedBuffers = "dropped_buffers"
        }
    }

    public struct WorstRow: Codable, Sendable, Equatable {
        public var index: Int
        public var wer: Double
        public var reference: String
        public var hypothesis: String

        public init(index: Int, wer: Double, reference: String, hypothesis: String) {
            self.index = index
            self.wer = wer
            self.reference = reference
            self.hypothesis = hypothesis
        }
    }

    public struct EvalSummary: Codable, Sendable, Equatable {
        public var model: String
        public var language: String?
        public var rows: Int
        /// Corpus-level WER: total edits over total reference tokens, not the
        /// mean of the per-row rates. Averaging rates would let a one-word
        /// utterance outweigh a fifty-word one.
        public var wer: Double
        public var cer: Double
        public var audioSeconds: Double
        public var wallSeconds: Double
        public var rtfx: Double
        /// See `DoneEvent.peakRSSBytes`: comparable with published figures,
        /// not reproducible enough to rank two engines by.
        public var peakRSSBytes: Int64
        /// See `DoneEvent.peakMemoryBytes`: the reproducible one.
        public var peakMemoryBytes: Int64
        public var worst: [WorstRow]
        /// Present only under `eval --live`.
        public var live: LiveSummary?

        public init(
            model: String, language: String?, rows: Int, wer: Double, cer: Double,
            audioSeconds: Double, wallSeconds: Double, peakRSSBytes: Int64,
            peakMemoryBytes: Int64, worst: [WorstRow], live: LiveSummary? = nil
        ) {
            self.model = model
            self.language = language
            self.rows = rows
            self.wer = wer
            self.cer = cer
            self.audioSeconds = audioSeconds
            self.wallSeconds = wallSeconds
            self.rtfx = wallSeconds > 0 ? audioSeconds / wallSeconds : 0
            self.peakRSSBytes = peakRSSBytes
            self.peakMemoryBytes = peakMemoryBytes
            self.worst = worst
            self.live = live
        }

        private enum CodingKeys: String, CodingKey {
            case model, language, rows, wer, cer, rtfx, worst, live
            case audioSeconds = "audio_seconds"
            case wallSeconds = "wall_seconds"
            case peakRSSBytes = "peak_rss_bytes"
            case peakMemoryBytes = "peak_memory_bytes"
        }
    }

    /// The live half of a run, aggregated over its rows.
    ///
    /// Medians rather than means throughout. One row that hit a model reload
    /// or a scheduler stall moves a mean by more than it moves the experience,
    /// and the worst case is reported next to the median anyway, so nothing is
    /// hidden by the choice.
    public struct LiveSummary: Codable, Sendable, Equatable {
        /// How fast the audio was played, as a multiple of real time. 1.0 is
        /// the only value whose latencies mean anything; it is recorded so a
        /// report taken at any other speed says so about itself.
        public var pace: Double
        public var medianFirstPartialSeconds: Double?
        public var worstFirstPartialSeconds: Double?
        public var medianFinishSeconds: Double
        public var worstFinishSeconds: Double
        public var medianFinalLagSeconds: Double?
        public var worstFinalLagSeconds: Double?
        /// Total across the corpus. See `Scorer.trailingReferenceLoss`.
        public var trailingWordsLost: Int
        /// Rows that produced text and still stopped short of the reference's
        /// end. Separated from `rowsWithNoText` because they are different
        /// failures wearing the same deletions.
        public var rowsEndingEarly: Int
        public var rowsWithNoText: Int
        /// Rows where the engine never emitted a partial before its final.
        public var rowsWithoutPartials: Int
        public var droppedBuffers: Int
        public var rowsWithDrops: Int

        public init(
            pace: Double,
            medianFirstPartialSeconds: Double?, worstFirstPartialSeconds: Double?,
            medianFinishSeconds: Double, worstFinishSeconds: Double,
            medianFinalLagSeconds: Double?, worstFinalLagSeconds: Double?,
            trailingWordsLost: Int, rowsEndingEarly: Int, rowsWithNoText: Int,
            rowsWithoutPartials: Int, droppedBuffers: Int, rowsWithDrops: Int
        ) {
            self.pace = pace
            self.medianFirstPartialSeconds = medianFirstPartialSeconds
            self.worstFirstPartialSeconds = worstFirstPartialSeconds
            self.medianFinishSeconds = medianFinishSeconds
            self.worstFinishSeconds = worstFinishSeconds
            self.medianFinalLagSeconds = medianFinalLagSeconds
            self.worstFinalLagSeconds = worstFinalLagSeconds
            self.trailingWordsLost = trailingWordsLost
            self.rowsEndingEarly = rowsEndingEarly
            self.rowsWithNoText = rowsWithNoText
            self.rowsWithoutPartials = rowsWithoutPartials
            self.droppedBuffers = droppedBuffers
            self.rowsWithDrops = rowsWithDrops
        }

        private enum CodingKeys: String, CodingKey {
            case pace
            case medianFirstPartialSeconds = "median_first_partial_seconds"
            case worstFirstPartialSeconds = "worst_first_partial_seconds"
            case medianFinishSeconds = "median_finish_seconds"
            case worstFinishSeconds = "worst_finish_seconds"
            case medianFinalLagSeconds = "median_final_lag_seconds"
            case worstFinalLagSeconds = "worst_final_lag_seconds"
            case trailingWordsLost = "trailing_words_lost"
            case rowsEndingEarly = "rows_ending_early"
            case rowsWithNoText = "rows_with_no_text"
            case rowsWithoutPartials = "rows_without_partials"
            case droppedBuffers = "dropped_buffers"
            case rowsWithDrops = "rows_with_drops"
        }
    }
}

// MARK: - Flat wire encoding

extension SpeechEvent.RefinedSegment: Codable {
    private enum CodingKeys: String, CodingKey {
        case refinedBy = "refined_by"
    }

    public init(from decoder: Decoder) throws {
        segment = try Segment(from: decoder)
        refinedBy = try decoder.container(keyedBy: CodingKeys.self)
            .decode(String.self, forKey: .refinedBy)
    }

    public func encode(to encoder: Encoder) throws {
        try segment.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(refinedBy, forKey: .refinedBy)
    }
}

extension SpeechEvent: Codable {
    private enum HeaderKeys: String, CodingKey {
        case type, t
    }

    public func encode(to encoder: Encoder) throws {
        var header = encoder.container(keyedBy: HeaderKeys.self)
        try header.encode(payload.type, forKey: .type)
        try header.encode(t, forKey: .t)
        switch payload {
        case .engineReady(let p): try p.encode(to: encoder)
        case .modelProgress(let p): try p.encode(to: encoder)
        case .modelInstalled(let p): try p.encode(to: encoder)
        case .modelEntry(let p): try p.encode(to: encoder)
        case .progress(let p): try p.encode(to: encoder)
        case .segmentPartial(let p): try p.encode(to: encoder)
        case .segmentFinal(let p): try p.encode(to: encoder)
        case .segmentRefined(let p): try p.encode(to: encoder)
        case .warning(let p): try p.encode(to: encoder)
        case .error(let p): try p.encode(to: encoder)
        case .done(let p): try p.encode(to: encoder)
        case .evalRow(let p): try p.encode(to: encoder)
        case .evalSummary(let p): try p.encode(to: encoder)
        case .recordingStarted(let p): try p.encode(to: encoder)
        case .recordingLevel(let p): try p.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let header = try decoder.container(keyedBy: HeaderKeys.self)
        let type = try header.decode(String.self, forKey: .type)
        t = try header.decode(Double.self, forKey: .t)
        switch type {
        case "engine.ready": payload = .engineReady(try EngineReady(from: decoder))
        case "model.progress": payload = .modelProgress(try ModelProgress(from: decoder))
        case "model.installed": payload = .modelInstalled(try ModelInstalled(from: decoder))
        case "model.entry": payload = .modelEntry(try ModelEntry(from: decoder))
        case "progress": payload = .progress(try BatchProgress(from: decoder))
        case "segment.partial": payload = .segmentPartial(try Segment(from: decoder))
        case "segment.final": payload = .segmentFinal(try Segment(from: decoder))
        case "segment.refined": payload = .segmentRefined(try RefinedSegment(from: decoder))
        case "warning": payload = .warning(try WarningEvent(from: decoder))
        case "error": payload = .error(try ErrorEvent(from: decoder))
        case "done": payload = .done(try DoneEvent(from: decoder))
        case "eval.row": payload = .evalRow(try EvalRow(from: decoder))
        case "eval.summary": payload = .evalSummary(try EvalSummary(from: decoder))
        case "recording.started": payload = .recordingStarted(try RecordingStarted(from: decoder))
        case "recording.level": payload = .recordingLevel(try RecordingLevel(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: header, debugDescription: "unknown event type '\(type)'")
        }
    }
}

// ModelProgress needs a memberwise decode path; its public init takes a
// LoadProgress, which Codable synthesis cannot use.
extension SpeechEvent.ModelProgress {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        phase = try c.decode(LoadProgress.Phase.self, forKey: .phase)
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
        bytesDone = try c.decodeIfPresent(Int64.self, forKey: .bytesDone)
        bytesTotal = try c.decodeIfPresent(Int64.self, forKey: .bytesTotal)
        file = try c.decodeIfPresent(String.self, forKey: .file)
    }
}

extension SpeechEvent.BatchProgress {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fraction = try c.decode(Double.self, forKey: .fraction)
        audioSecondsDone = try c.decode(Double.self, forKey: .audioSecondsDone)
        audioSecondsTotal = try c.decode(Double.self, forKey: .audioSecondsTotal)
    }
}

extension SpeechEvent.DoneEvent {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = try c.decode(Int.self, forKey: .segments)
        audioSeconds = try c.decode(Double.self, forKey: .audioSeconds)
        wallSeconds = try c.decode(Double.self, forKey: .wallSeconds)
        rtfx = try c.decode(Double.self, forKey: .rtfx)
        peakRSSBytes = try c.decode(Int64.self, forKey: .peakRSSBytes)
        peakMemoryBytes = try c.decode(Int64.self, forKey: .peakMemoryBytes)
        output = try c.decodeIfPresent(String.self, forKey: .output)
    }
}

extension SpeechEvent.EvalSummary {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        rows = try c.decode(Int.self, forKey: .rows)
        wer = try c.decode(Double.self, forKey: .wer)
        cer = try c.decode(Double.self, forKey: .cer)
        audioSeconds = try c.decode(Double.self, forKey: .audioSeconds)
        wallSeconds = try c.decode(Double.self, forKey: .wallSeconds)
        rtfx = try c.decode(Double.self, forKey: .rtfx)
        peakRSSBytes = try c.decode(Int64.self, forKey: .peakRSSBytes)
        peakMemoryBytes = try c.decode(Int64.self, forKey: .peakMemoryBytes)
        worst = try c.decode([SpeechEvent.WorstRow].self, forKey: .worst)
    }
}
