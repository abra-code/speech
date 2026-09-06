// Wire.swift - what `speech` and `speech-mlx` say to each other.
//
// These types are compiled into BOTH processes. The helper's Xcode project
// lists this directory as a source path, so there is one definition of the
// format rather than two that agree until somebody edits one of them. That is
// also why this target may not import SpeechCore: pulling SpeechCore in would
// drag FluidAudio and the transcribe.cpp xcframework into a binary whose whole
// point is to be optional and to link nothing but MLX. `protocolTargetIsSelfContained`
// in the test suite fails if an import creeps in.
//
// The shape is a session, not a one-shot call. A FLEURS split is 647 to 862
// utterances and Qwen3-ASR 1.7B takes about a second to load, so a process per
// utterance would spend ten minutes of every cell loading weights it already
// had. So: spawn once, load once, then a request per utterance.
//
// docs/mlx-helper.md is the specification. Changing a name here changes the
// wire format and must change that file in the same commit; `test.sh` regenerates
// the examples in it and diffs them, so the two cannot drift.

import Foundation

// MARK: - Requests

/// A request from `speech` to the helper. One JSON object on one line; a
/// request that carries audio declares `bytes` and the payload follows the
/// newline.
public enum MLXRequest: Sendable, Equatable {
    case load(Load)
    case transcribe(Transcribe)
    case unload
    case bye

    /// Load a model out of a directory this process already owns.
    ///
    /// The helper never downloads. `speech` fetched these files through the
    /// same resumable, LFS-pinned client every other row uses, into the same
    /// model store, so there is one download path and one place that knows
    /// what "installed" means.
    public struct Load: Codable, Sendable, Equatable {
        /// Directory holding config.json and the safetensors shards.
        public var directory: String
        /// The model type, when the caller already knows it. nil means "read
        /// it out of config.json", which is what the library itself does.
        public var type: String?
        /// BCP-47 tag or a language name, for the models that take a hint.
        public var language: String?

        public init(directory: String, type: String? = nil, language: String? = nil) {
            self.directory = directory
            self.type = type
            self.language = language
        }
    }

    /// Transcribe one buffer. The audio follows the newline: `bytes` of
    /// little-endian Float32, mono, 16 kHz, in [-1, 1] - what AudioDecoder
    /// produces, so every engine in this project is measured on identical
    /// samples.
    public struct Transcribe: Codable, Sendable, Equatable {
        /// Echoed back on every event, so a reply can be matched to a request
        /// even though the helper answers strictly in order.
        public var id: Int
        /// Samples in the payload. Redundant with `bytes` on purpose: a short
        /// write then fails a `bytes == samples * 4` check instead of producing
        /// a transcript of whatever the truncation left behind. The framing
        /// layer guarantees `bytes` against the payload it delivers; comparing
        /// that against `samples` is the reader's job, because only the reader
        /// knows what it is going to do with the audio. The helper does it in
        /// `Helper.swift`, with the multiplication overflow-checked.
        public var samples: Int
        public var bytes: Int
        /// Seconds of audio the model is allowed to hold in one chunk.
        ///
        /// Not a tuning knob: mlx-audio-swift's default is 1200, and issue
        /// #249 reports that default building a roughly 7 GB KV cache and
        /// hanging a 108-minute file on a 48 GB machine. `speech` hands over
        /// bounded buffers and says here how the model may cut them.
        public var chunkSeconds: Double?
        public var maxTokens: Int?

        public init(
            id: Int, samples: Int, bytes: Int,
            chunkSeconds: Double? = nil, maxTokens: Int? = nil
        ) {
            self.id = id
            self.samples = samples
            self.bytes = bytes
            self.chunkSeconds = chunkSeconds
            self.maxTokens = maxTokens
        }

        private enum CodingKeys: String, CodingKey {
            case id, samples, bytes
            case chunkSeconds = "chunk_seconds"
            case maxTokens = "max_tokens"
        }
    }

    /// The `op` value on the wire.
    public var op: String {
        switch self {
        case .load: return "load"
        case .transcribe: return "transcribe"
        case .unload: return "unload"
        case .bye: return "bye"
        }
    }

    /// Bytes of payload that must follow this request's line, zero for the
    /// requests that carry none.
    public var payloadBytes: Int {
        if case .transcribe(let request) = self { return request.bytes }
        return 0
    }
}

// MARK: - Responses

/// A response from the helper. Always one JSON object on one line, never with
/// a payload: nothing the helper sends back is large enough to be worth
/// framing, and a text-only reply stream is one `head` away from being
/// readable by a person debugging a run.
public enum MLXResponse: Sendable, Equatable {
    case ready(Ready)
    case loaded(Loaded)
    case segment(SegmentEvent)
    case done(Done)
    case ok(Ok)
    case failure(Failure)

    /// Sent unprompted, once, before any request is read.
    ///
    /// It is emitted only after the helper has run a trivial MLX operation, so
    /// it also answers the question that costs the most to answer late: whether
    /// this build can reach the GPU at all. mlx-swift's Metal kernels are
    /// compiled into a resource bundle that has to sit beside the binary, and a
    /// binary that lost its bundle links, launches, and then aborts on the
    /// first array operation - which without this would happen in the middle of
    /// a measurement rather than at startup.
    public struct Ready: Codable, Sendable, Equatable {
        /// The helper's own version, which is this repository's version.
        public var helper: String
        /// The pinned mlx-audio-swift tag.
        public var mlxAudio: String
        /// The resolved mlx-swift version.
        public var mlxSwift: String
        /// Model types this build can construct, as `config.json` spells them
        /// ("parakeet", "whisper", "qwen3_asr"). Not a capability table:
        /// languages and flags are properties of a checkpoint, not of a type,
        /// and are reported by `loaded` after the weights are read.
        public var types: [String]

        public init(helper: String, mlxAudio: String, mlxSwift: String, types: [String]) {
            self.helper = helper
            self.mlxAudio = mlxAudio
            self.mlxSwift = mlxSwift
            self.types = types
        }

        private enum CodingKeys: String, CodingKey {
            case helper
            case mlxAudio = "mlx_audio"
            case mlxSwift = "mlx_swift"
            case types
        }
    }

    public struct Loaded: Codable, Sendable, Equatable {
        /// The type the helper resolved, whether it was told or read it.
        public var type: String
        public var seconds: Double
        /// Languages the checkpoint itself names. Empty means the files do not
        /// say, which is not the same as "no languages" - a distinction worth
        /// keeping, because the alternative is a list somebody typed from a
        /// model card, and stage 2 found four of those wrong.
        public var languages: [String]
        /// Whether this model's `generate` reads a language hint. A property of
        /// the helper's own implementation, so the helper is the side that
        /// knows it.
        public var languageHint: Bool

        public init(type: String, seconds: Double, languages: [String], languageHint: Bool) {
            self.type = type
            self.seconds = seconds
            self.languages = languages
            self.languageHint = languageHint
        }

        private enum CodingKeys: String, CodingKey {
            case type, seconds, languages
            case languageHint = "language_hint"
        }
    }

    /// A request that did what it was asked and has nothing to report.
    ///
    /// It exists so that the rule is "every request gets exactly one terminal
    /// reply". The alternative - `unload` answering with silence - means the
    /// reader on the other side has to know which requests reply and which do
    /// not, and a reader that gets that wrong blocks forever on a message
    /// nobody is going to send.
    public struct Ok: Codable, Sendable, Equatable {
        public var op: String

        public init(op: String) {
            self.op = op
        }
    }

    /// One piece of transcript. Times are seconds from the start of the buffer
    /// that was handed over, never from the start of the recording: the helper
    /// is not told where in a file its buffer came from, and offsetting is
    /// `speech`'s job because `speech` is the only side that knows.
    public struct SegmentEvent: Codable, Sendable, Equatable {
        public var id: Int
        public var index: Int
        public var start: Double
        public var end: Double
        public var text: String

        public init(id: Int, index: Int, start: Double, end: Double, text: String) {
            self.id = id
            self.index = index
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public struct Done: Codable, Sendable, Equatable {
        public var id: Int
        /// Wall time the model spent on this buffer.
        public var seconds: Double
        public var segments: Int
        /// True when the model returned no timings and the helper covered the
        /// buffer with a single span. The distinction is the difference between
        /// a measured timestamp and an assumed one, and a row that always
        /// synthesizes has no segment timestamps whatever its card claims.
        public var synthesized: Bool
        /// What MLX reports it peaked at, in gigabytes. Recorded but not
        /// trusted as this project's memory number: `peak_memory_bytes` in
        /// `speech` is the instrument, and this is the library's own opinion.
        public var peakMemoryGB: Double?

        public init(
            id: Int, seconds: Double, segments: Int,
            synthesized: Bool, peakMemoryGB: Double? = nil
        ) {
            self.id = id
            self.seconds = seconds
            self.segments = segments
            self.synthesized = synthesized
            self.peakMemoryGB = peakMemoryGB
        }

        private enum CodingKeys: String, CodingKey {
            case id, seconds, segments, synthesized
            case peakMemoryGB = "peak_memory_gb"
        }
    }

    /// A request the helper could not carry out. Never fatal on its own: the
    /// helper stays up and reads the next request, because a model that fails
    /// on one utterance of a 700-row split should cost that row and not the
    /// other 699.
    public struct Failure: Codable, Sendable, Equatable {
        /// The `op` that failed, or "startup" for a failure before any request.
        public var op: String
        /// nil when the failure was not about a particular transcribe request.
        public var id: Int?
        public var message: String

        public init(op: String, id: Int? = nil, message: String) {
            self.op = op
            self.id = id
            self.message = message
        }
    }

    /// The `event` value on the wire.
    public var event: String {
        switch self {
        case .ready: return "ready"
        case .loaded: return "loaded"
        case .segment: return "segment"
        case .done: return "done"
        case .ok: return "ok"
        case .failure: return "error"
        }
    }
}
