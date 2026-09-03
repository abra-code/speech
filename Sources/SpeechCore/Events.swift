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
        case progress(BatchProgress)
        case segmentPartial(Segment)
        case segmentFinal(Segment)
        case segmentRefined(RefinedSegment)
        case warning(WarningEvent)
        case error(ErrorEvent)
        case done(DoneEvent)
        case evalRow(EvalRow)
        case evalSummary(EvalSummary)

        public var type: String {
            switch self {
            case .engineReady: return "engine.ready"
            case .modelProgress: return "model.progress"
            case .modelInstalled: return "model.installed"
            case .progress: return "progress"
            case .segmentPartial: return "segment.partial"
            case .segmentFinal: return "segment.final"
            case .segmentRefined: return "segment.refined"
            case .warning: return "warning"
            case .error: return "error"
            case .done: return "done"
            case .evalRow: return "eval.row"
            case .evalSummary: return "eval.summary"
            }
        }
    }

    // MARK: - Payloads

    public struct EngineReady: Codable, Sendable, Equatable {
        public var engine: String
        public var model: String
        public var capabilities: EngineCapabilities
        public var loadSeconds: Double
        /// What the engine resolved the requested language to, when it is more
        /// specific: "de" reaches Apple as de_AT and "es" as es_US. Omitted
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
        public var peakRSSBytes: Int64
        /// Present only when the run wrote a file.
        public var output: String?

        public init(
            segments: Int, audioSeconds: Double, wallSeconds: Double,
            peakRSSBytes: Int64, output: String? = nil
        ) {
            self.segments = segments
            self.audioSeconds = audioSeconds
            self.wallSeconds = wallSeconds
            self.rtfx = wallSeconds > 0 ? audioSeconds / wallSeconds : 0
            self.peakRSSBytes = peakRSSBytes
            self.output = output
        }

        private enum CodingKeys: String, CodingKey {
            case segments, rtfx, output
            case audioSeconds = "audio_seconds"
            case wallSeconds = "wall_seconds"
            case peakRSSBytes = "peak_rss_bytes"
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

        public init(
            index: Int, path: String, reference: String, hypothesis: String,
            wer: Double, cer: Double, audioSeconds: Double, wallSeconds: Double
        ) {
            self.index = index
            self.path = path
            self.reference = reference
            self.hypothesis = hypothesis
            self.wer = wer
            self.cer = cer
            self.audioSeconds = audioSeconds
            self.wallSeconds = wallSeconds
        }

        private enum CodingKeys: String, CodingKey {
            case index, path, reference, hypothesis, wer, cer
            case audioSeconds = "audio_seconds"
            case wallSeconds = "wall_seconds"
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
        public var peakRSSBytes: Int64
        public var worst: [WorstRow]

        public init(
            model: String, language: String?, rows: Int, wer: Double, cer: Double,
            audioSeconds: Double, wallSeconds: Double, peakRSSBytes: Int64, worst: [WorstRow]
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
            self.worst = worst
        }

        private enum CodingKeys: String, CodingKey {
            case model, language, rows, wer, cer, rtfx, worst
            case audioSeconds = "audio_seconds"
            case wallSeconds = "wall_seconds"
            case peakRSSBytes = "peak_rss_bytes"
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
        case .progress(let p): try p.encode(to: encoder)
        case .segmentPartial(let p): try p.encode(to: encoder)
        case .segmentFinal(let p): try p.encode(to: encoder)
        case .segmentRefined(let p): try p.encode(to: encoder)
        case .warning(let p): try p.encode(to: encoder)
        case .error(let p): try p.encode(to: encoder)
        case .done(let p): try p.encode(to: encoder)
        case .evalRow(let p): try p.encode(to: encoder)
        case .evalSummary(let p): try p.encode(to: encoder)
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
        case "progress": payload = .progress(try BatchProgress(from: decoder))
        case "segment.partial": payload = .segmentPartial(try Segment(from: decoder))
        case "segment.final": payload = .segmentFinal(try Segment(from: decoder))
        case "segment.refined": payload = .segmentRefined(try RefinedSegment(from: decoder))
        case "warning": payload = .warning(try WarningEvent(from: decoder))
        case "error": payload = .error(try ErrorEvent(from: decoder))
        case "done": payload = .done(try DoneEvent(from: decoder))
        case "eval.row": payload = .evalRow(try EvalRow(from: decoder))
        case "eval.summary": payload = .evalSummary(try EvalSummary(from: decoder))
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
        worst = try c.decode([SpeechEvent.WorstRow].self, forKey: .worst)
    }
}
