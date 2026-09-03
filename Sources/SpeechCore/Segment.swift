// Segment.swift - the unit of transcript that every engine produces and every
// consumer reads. Engines differ wildly underneath (transducer token timings,
// Whisper-style segments, Apple's attributed-string runs); this is the shape
// they all normalize to, so the applet never learns which one ran.
//
// Field names are the wire format: these structs encode straight into the
// `segment.partial` / `segment.final` events and into `--format json`. Optional
// fields are omitted when nil rather than encoded as null, which is what
// Codable does by default for Optional and what the plan's "unknown fields must
// be ignored" rule is designed around.

import Foundation

public struct Word: Codable, Sendable, Equatable {
    public var text: String
    /// Seconds from the start of the media, not from the start of the segment.
    public var start: Double
    public var end: Double
    public var confidence: Float?

    public init(text: String, start: Double, end: Double, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct Segment: Codable, Sendable, Equatable {
    /// Monotonically increasing within one session. A `segment.refined` event
    /// reuses the id of the `segment.final` it replaces, which is how the
    /// applet's transcript table knows to overwrite a row instead of appending.
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    /// nil when the engine has no word timings at all (Whisper, Qwen3-ASR).
    /// An empty array would claim "this segment has no words", which is a
    /// different statement.
    public var words: [Word]?
    public var confidence: Float?
    /// 1-based speaker index, nil when no diarization ran.
    public var speaker: Int?
    /// Detected or hinted BCP-47 primary subtag.
    public var language: String?

    public init(
        id: Int,
        start: Double,
        end: Double,
        text: String,
        words: [Word]? = nil,
        confidence: Float? = nil,
        speaker: Int? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.confidence = confidence
        self.speaker = speaker
        self.language = language
    }

    public var duration: Double { max(0, end - start) }
}

/// What `speech transcribe --format json` writes, and what `speech export`
/// reads back so the applet can re-export without re-transcribing.
public struct TranscriptDocument: Codable, Sendable, Equatable {
    public var model: String
    public var language: String?
    public var segments: [Segment]

    public init(model: String, language: String? = nil, segments: [Segment]) {
        self.model = model
        self.language = language
        self.segments = segments
    }
}
