import Foundation
import Testing
import CTranscribe

@testable import TranscribeCpp

@testable import SpeechCore
@testable import SpeechGGML

@Suite("ggml language and mapping")
struct GGMLEngineTests {
    // MARK: - Language spelling

    /// Measured on the real weights: `nemotron-3.5-asr-streaming-0.6b` accepts
    /// `pl-PL` and rejects `pl` with "unsupported language", while
    /// `canary-1b-v2`, `qwen3-asr` and `whisper-large-v3-turbo` accept `pl` and
    /// reject `pl-PL`. Normalizing to a primary subtag breaks one half of the
    /// catalog; passing the caller's tag through breaks the other.
    @Test("a bare request finds the model's regional spelling")
    func bareRequestFindsRegionalTag() {
        let nemotron = ["en-US", "en-GB", "pl-PL", "de-DE"]
        #expect(GGMLEngine.matchLanguage("pl", in: nemotron) == "pl-PL")
        #expect(GGMLEngine.matchLanguage("pl-PL", in: nemotron) == "pl-PL")
        #expect(GGMLEngine.matchLanguage("pl_pl", in: nemotron) == "pl-PL")
    }

    @Test("a regional request finds the model's bare spelling")
    func regionalRequestFindsBareTag() {
        let canary = ["en", "de", "pl", "uk"]
        #expect(GGMLEngine.matchLanguage("pl", in: canary) == "pl")
        #expect(GGMLEngine.matchLanguage("pl-PL", in: canary) == "pl")
        #expect(GGMLEngine.matchLanguage("de-AT", in: canary) == "de")
    }

    @Test("an exact tag wins over a sibling region")
    func exactTagWins() {
        let both = ["pt-BR", "pt-PT"]
        #expect(GGMLEngine.matchLanguage("pt-PT", in: both) == "pt-PT")
        #expect(GGMLEngine.matchLanguage("pt-BR", in: both) == "pt-BR")
        // A bare request has no right answer, so it takes the one the model
        // names first rather than being refused.
        #expect(GGMLEngine.matchLanguage("pt", in: both) == "pt-BR")
    }

    @Test("a language the model does not carry has no match")
    func noMatch() {
        #expect(GGMLEngine.matchLanguage("ja", in: ["en", "de", "pl"]) == nil)
        #expect(GGMLEngine.matchLanguage("", in: ["en"]) == nil)
    }

    // MARK: - Timestamp clamping

    /// Asking for finer timestamps than a family has is a documented way to
    /// earn `UNSUPPORTED_TIMESTAMPS`, which would fail a run that had every
    /// reason to succeed - Whisper is segment-only and Canary has none at all.
    @Test("the request never exceeds what the model can give")
    func timestampClamping() {
        #expect(GGMLEngine.timestampKind(wantWords: true, ceiling: .token) == .word)
        #expect(GGMLEngine.timestampKind(wantWords: true, ceiling: .word) == .word)
        #expect(GGMLEngine.timestampKind(wantWords: true, ceiling: .segment) == .segment)
        #expect(GGMLEngine.timestampKind(wantWords: true, ceiling: .none) == .none)
        #expect(GGMLEngine.timestampKind(wantWords: false, ceiling: .token) == .segment)
        #expect(GGMLEngine.timestampKind(wantWords: false, ceiling: .none) == .none)
        // `.auto` as a ceiling means "the richest this model has", so it clamps
        // nothing.
        #expect(GGMLEngine.timestampKind(wantWords: true, ceiling: .auto) == .word)
    }

    // MARK: - Transcript mapping

    /// A chunked file is several runs whose timestamps all start at zero. If
    /// the offset were dropped, every cue after the first chunk would point at
    /// the beginning of the media.
    @Test("a chunk's timestamps are shifted by where its audio started")
    func chunkOffset() {
        let transcript = Transcript(
            text: "second piece", rawText: "second piece", language: nil,
            timestampKind: .word,
            segments: [makeSegment(t0: 0, t1: 2000, firstWord: 0, nWords: 2, text: "second piece")],
            speakerSegments: [],
            words: [makeWord(t0: 0, t1: 900, text: "second"), makeWord(t0: 900, t1: 2000, text: "piece")],
            tokens: [], timings: makeTimings())

        let segments = GGMLEngine.segments(
            from: transcript, offset: 60, fallbackEnd: 90, firstID: 3, language: "en")
        #expect(segments.count == 1)
        let segment = segments[0]
        #expect(segment.id == 3, "ids continue across chunks")
        #expect(segment.start == 60)
        #expect(segment.end == 62)
        #expect(segment.words?.map { $0.text } == ["second", "piece"])
        #expect(segment.words?.first?.start == 60)
        #expect(segment.words?.last?.end == 62)
        #expect(segment.language == "en")
    }

    /// `firstWord`/`nWords` are `Int32` out of a C struct. A family that
    /// reports a range past the end of the array would crash the process on a
    /// slice rather than produce a slightly wrong transcript.
    @Test("a word range past the end of the array does not crash")
    func outOfRangeWordIndices() {
        let transcript = Transcript(
            text: "hello", rawText: "hello", language: nil, timestampKind: .word,
            segments: [makeSegment(t0: 0, t1: 1000, firstWord: 5, nWords: 40, text: "hello")],
            speakerSegments: [],
            words: [makeWord(t0: 0, t1: 500, text: "hello")],
            tokens: [], timings: makeTimings())

        let segments = GGMLEngine.segments(
            from: transcript, offset: 0, fallbackEnd: 1, firstID: 0, language: nil)
        #expect(segments.count == 1)
        #expect(segments[0].text == "hello")
        #expect(segments[0].words == nil, "an unusable range yields no words, not a crash")
    }

    /// Qwen3-ASR and Moonshine report no segmentation at all. One segment
    /// spanning the piece is right; zero segments would drop the transcript.
    @Test("a model with no segments still produces one")
    func noSegments() {
        let transcript = Transcript(
            text: " some words ", rawText: "some words", language: nil, timestampKind: .none,
            segments: [], speakerSegments: [], words: [], tokens: [], timings: makeTimings())

        let segments = GGMLEngine.segments(
            from: transcript, offset: 10, fallbackEnd: 25, firstID: 0, language: "pl")
        #expect(segments.count == 1)
        #expect(segments[0].text == "some words", "text is trimmed")
        #expect(segments[0].start == 10)
        #expect(segments[0].end == 25, "falls back to the piece's own end")
        #expect(segments[0].words == nil)
    }

    @Test("an empty transcript produces no segments")
    func emptyTranscript() {
        let transcript = Transcript(
            text: "   ", rawText: "", language: nil, timestampKind: .none,
            segments: [], speakerSegments: [], words: [], tokens: [], timings: makeTimings())
        #expect(GGMLEngine.segments(
            from: transcript, offset: 0, fallbackEnd: 1, firstID: 0, language: nil).isEmpty)
    }

    @Test("a native error keeps the library's own message")
    func errorDescription() {
        let described = GGMLEngine.describe(
            TranscribeError.inputTooLong("run: audio exceeds the model's limit"))
        #expect(described == "run: audio exceeds the model's limit")
        #expect(GGMLEngine.describe(
            TranscribeError.other(status: 42, message: "boom")).contains("42"))
    }
}

// MARK: - Fixtures

/// `Transcript` and friends have memberwise initializers only inside their own
/// module for the C-backed members, so the test builds them through the public
/// memberwise init on `Transcript` and small helpers for the rest.
private func makeTimings() -> Timings {
    var raw = transcribe_timings()
    transcribe_timings_init(&raw)
    return Timings(raw)
}

private func makeSegment(
    t0: Int64, t1: Int64, firstWord: Int32, nWords: Int32, text: String
) -> TranscribeCpp.Segment {
    var raw = transcribe_segment()
    transcribe_segment_init(&raw)
    raw.t0_ms = t0
    raw.t1_ms = t1
    raw.first_word = firstWord
    raw.n_words = nWords
    return text.withCString { pointer in
        raw.text = pointer
        return TranscribeCpp.Segment(raw)
    }
}

private func makeWord(t0: Int64, t1: Int64, text: String) -> TranscribeCpp.Word {
    var raw = transcribe_word()
    transcribe_word_init(&raw)
    raw.t0_ms = t0
    raw.t1_ms = t1
    return text.withCString { pointer in
        raw.text = pointer
        return TranscribeCpp.Word(raw)
    }
}
