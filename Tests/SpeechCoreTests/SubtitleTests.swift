// SubtitleTests.swift - the cue builder and the two subtitle serializations.
//
// The rules being pinned are the broadcast conventions from Formats.swift: at
// most 42 characters a line, at most two lines, at least a second on screen,
// and a preference for breaking where the speaker paused.

import Testing
@testable import SpeechCore

@Suite("Subtitles")
struct SubtitleTests {
    private func words(_ text: String, start: Double = 0, step: Double = 0.4) -> [Word] {
        text.split(separator: " ").enumerated().map { index, word in
            Word(
                text: String(word),
                start: start + Double(index) * step,
                end: start + Double(index + 1) * step)
        }
    }

    @Test("a segment with no word timings becomes one cue")
    func segmentOnly() {
        let segment = Segment(id: 0, start: 1, end: 4, text: "Hello there, world.")
        let cues = SubtitleBuilder.cues(from: [segment])
        #expect(cues.count == 1)
        #expect(cues[0].index == 1)
        #expect(cues[0].start == 1)
        #expect(cues[0].end == 4)
        #expect(cues[0].text == "Hello there, world.")
    }

    @Test("no line exceeds the length limit and no cue exceeds two lines")
    func lineLimits() {
        let text = String(repeating: "alpha bravo charlie delta ", count: 6)
        let segment = Segment(
            id: 0, start: 0, end: 20, text: text, words: words(text))
        for cue in SubtitleBuilder.cues(from: [segment]) {
            #expect(cue.lines.count <= 2)
            for line in cue.lines {
                #expect(line.count <= 42)
            }
        }
    }

    @Test("a sentence end breaks the cue")
    func breaksAtSentenceEnd() {
        let text = "One two three. Four five six."
        let segment = Segment(id: 0, start: 0, end: 4, text: text, words: words(text))
        let cues = SubtitleBuilder.cues(from: [segment])
        #expect(cues.count == 2)
        #expect(cues[0].text == "One two three.")
        #expect(cues[1].text == "Four five six.")
    }

    @Test("no cue runs longer than the maximum on-screen time")
    func maximumDuration() {
        // Twenty words a second apart: 20 s of speech with no punctuation to
        // break on, so only the duration rule can cut it.
        let text = (1...20).map { "word\($0)" }.joined(separator: " ")
        let segment = Segment(
            id: 0, start: 0, end: 20, text: text, words: words(text, step: 1.0))
        let cues = SubtitleBuilder.cues(from: [segment])
        #expect(cues.count > 1)
        for cue in cues {
            #expect(cue.end - cue.start <= 7.0001)
        }
    }

    @Test("a very short cue is stretched, but never over the next one")
    func minimumDuration() {
        let first = Segment(id: 0, start: 0, end: 0.2, text: "Hi.")
        let second = Segment(id: 1, start: 0.5, end: 3, text: "There.")
        let cues = SubtitleBuilder.cues(from: [first, second])
        #expect(cues.count == 2)
        #expect(cues[0].end == 0.5)
        #expect(cues[0].end <= cues[1].start)
        #expect(cues[1].end - cues[1].start >= 1.0)
    }

    @Test("cues are numbered from one and never overlap")
    func numberingAndOverlap() {
        let segments = (0..<5).map {
            Segment(id: $0, start: Double($0) * 2, end: Double($0) * 2 + 1.5, text: "Line \($0).")
        }
        let cues = SubtitleBuilder.cues(from: segments)
        #expect(cues.map(\.index) == [1, 2, 3, 4, 5])
        for pair in zip(cues, cues.dropFirst()) {
            #expect(pair.0.end <= pair.1.start)
        }
    }

    @Test("out-of-order segments never produce a backwards timecode")
    func outOfOrderSegments() {
        // `speech export` reads any json document, and a diarization merge or a
        // refined segment can arrive out of order. The overlap clamp used to
        // set a cue's end to the next cue's start unconditionally, producing
        // 00:00:05 --> 00:00:01, which some players answer by dropping the
        // entire file.
        let cues = SubtitleBuilder.cues(from: [
            Segment(id: 0, start: 5, end: 6, text: "Later."),
            Segment(id: 1, start: 1, end: 2, text: "Earlier."),
        ])
        #expect(cues.count == 2)
        #expect(cues[0].text == "Earlier.")
        for cue in cues {
            #expect(cue.end >= cue.start)
        }
    }

    @Test("a newline inside a segment cannot truncate its cue")
    func newlineInSegment() {
        // A blank line ends a cue in both srt and vtt, so a newline surviving
        // into the text silently drops everything after it.
        let cues = SubtitleBuilder.cues(from: [
            Segment(id: 0, start: 0, end: 3, text: "Hello\n\nworld again"),
        ])
        #expect(cues.count == 1)
        #expect(cues[0].text == "Hello world again")
        #expect(!cues[0].text.contains("\n\n"))
    }

    @Test("srt timecodes use a comma and vtt a period")
    func timecodeFormats() {
        #expect(TranscriptRenderer.timecode(0, separator: ",") == "00:00:00,000")
        #expect(TranscriptRenderer.timecode(3661.5, separator: ",") == "01:01:01,500")
        #expect(TranscriptRenderer.timecode(3661.5, separator: ".") == "01:01:01.500")
        // A negative time would make some players reject the whole file.
        #expect(TranscriptRenderer.timecode(-1, separator: ",") == "00:00:00,000")
        // Rounded, not truncated.
        #expect(TranscriptRenderer.timecode(1.9999, separator: ",") == "00:00:02,000")
    }

    @Test("srt and vtt render the expected envelope")
    func serialization() throws {
        let document = TranscriptDocument(
            model: "apple.transcriber", language: "en",
            segments: [Segment(id: 0, start: 0, end: 2, text: "Hello.")])
        let srt = try TranscriptRenderer.render(document, as: .srt)
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\nHello.\n"))
        let vtt = try TranscriptRenderer.render(document, as: .vtt)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nHello.\n"))
        let txt = try TranscriptRenderer.render(document, as: .txt)
        #expect(txt == "Hello.")
    }

    @Test("a diarized segment prefixes its cues with the speaker")
    func speakerPrefix() {
        let segment = Segment(id: 0, start: 0, end: 2, text: "Hello.", speaker: 2)
        let cues = SubtitleBuilder.cues(from: [segment])
        #expect(cues[0].text == "Speaker 2: Hello.")
    }

    @Test("an unknown format name is a usage error")
    func formatParsing() throws {
        #expect(try TranscriptFormat.parse("SRT") == .srt)
        #expect(throws: SpeechError.self) { _ = try TranscriptFormat.parse("docx") }
    }
}
