// Formats.swift - turning segments into the four things a user asks for: plain
// text, subtitles (srt, vtt) and the json document that lets the applet
// re-export without re-transcribing.
//
// The subtitle cue builder is the only part with judgment in it. Its rules come
// from the conventions broadcast subtitling settled on decades ago, and they
// matter because a cue that breaks them is unreadable even when the words are
// perfect: at most 42 characters per line, at most two lines, at least one
// second and at most seven on screen, and a break at punctuation in preference
// to a break mid-clause.
//
// Engines that report no word timings (Whisper's segment-level output,
// Qwen3-ASR's none at all) cannot be cut finer than the segment they gave us,
// so those produce one cue per segment and the length rules become best-effort.

import Foundation

public enum TranscriptFormat: String, Sendable, CaseIterable {
    case txt, srt, vtt, json

    public static func parse(_ raw: String) throws -> TranscriptFormat {
        guard let format = TranscriptFormat(rawValue: raw.lowercased()) else {
            throw SpeechError.usage(
                "unknown format '\(raw)' (want \(TranscriptFormat.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        return format
    }

    public var fileExtension: String { rawValue }
}

public struct Cue: Sendable, Equatable {
    public var index: Int
    public var start: Double
    public var end: Double
    public var lines: [String]

    public init(index: Int, start: Double, end: Double, lines: [String]) {
        self.index = index
        self.start = start
        self.end = end
        self.lines = lines
    }

    public var text: String { lines.joined(separator: "\n") }
}

public enum SubtitleBuilder {
    public struct Style: Sendable {
        public var maxLineLength: Int
        public var maxLines: Int
        public var minDuration: Double
        public var maxDuration: Double

        public init(
            maxLineLength: Int = 42,
            maxLines: Int = 2,
            minDuration: Double = 1.0,
            maxDuration: Double = 7.0
        ) {
            self.maxLineLength = maxLineLength
            self.maxLines = maxLines
            self.minDuration = minDuration
            self.maxDuration = maxDuration
        }

        /// The most characters a cue could hold if every line were full. Only
        /// an upper bound: whether a cue actually fits is decided by wrapping
        /// it, because word boundaries rarely fall on the 42nd character and a
        /// cue of exactly 84 characters usually needs three lines, not two.
        var capacity: Int { maxLineLength * maxLines }
        /// Past this fill level a punctuation break is taken rather than
        /// packing the cue to the brim; below it, breaking would leave a stub.
        var softBreakThreshold: Int { (capacity * 6) / 10 }
    }

    public static func cues(from segments: [Segment], style: Style = Style()) -> [Cue] {
        var cues: [Cue] = []
        for segment in segments {
            if let words = segment.words, !words.isEmpty {
                cues.append(contentsOf: split(words: words, speaker: segment.speaker, style: style))
            } else {
                let trimmed = splitWords(segment.text).joined(separator: " ")
                guard !trimmed.isEmpty else { continue }
                cues.append(Cue(
                    index: 0, start: segment.start, end: segment.end,
                    lines: wrap(prefixSpeaker(trimmed, speaker: segment.speaker), style: style)))
            }
        }
        return finalize(cues, style: style)
    }

    private static func splitWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    private static func split(words: [Word], speaker: Int?, style: Style) -> [Cue] {
        var cues: [Cue] = []
        var current: [Word] = []

        /// The cue's text as it will actually be rendered, speaker prefix
        /// included. The prefix counts against the line budget, so it has to be
        /// part of the fit test rather than glued on afterwards.
        func rendered(_ candidate: [Word]) -> String {
            prefixSpeaker(
                candidate.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: speaker)
        }

        func flush() {
            guard !current.isEmpty else { return }
            let text = rendered(current)
            if !text.isEmpty {
                cues.append(Cue(
                    index: 0,
                    start: current[0].start,
                    end: current[current.count - 1].end,
                    lines: wrap(text, style: style)))
            }
            current = []
        }

        for word in words {
            // Collapse whatever whitespace the engine put in the token. A
            // newline surviving into a cue truncates it: SRT and VTT treat a
            // blank line as the end of the cue, so the rest is silently lost.
            let trimmed = splitWords(word.text).joined(separator: " ")
            if trimmed.isEmpty { continue }
            let next = Word(
                text: trimmed, start: word.start, end: word.end, confidence: word.confidence)
            if !current.isEmpty {
                // Wrap the candidate rather than counting its characters. The
                // character count is only an upper bound on what fits, and
                // trusting it produced three-line cues.
                let overflows = wrap(rendered(current + [next]), style: style).count > style.maxLines
                let tooLong = next.end - current[0].start > style.maxDuration
                if overflows || tooLong {
                    flush()
                }
            }
            current.append(next)
            if endsSentence(trimmed)
                || (endsClause(trimmed) && rendered(current).count >= style.softBreakThreshold) {
                flush()
            }
        }
        flush()
        return cues
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".!?\u{2026}".contains(last)
    }

    private static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",;:".contains(last)
    }

    private static func prefixSpeaker(_ text: String, speaker: Int?) -> String {
        guard let speaker else { return text }
        return "Speaker \(speaker): \(text)"
    }

    /// Greedy fill, then balance when the result is exactly two lines: a 41/3
    /// split is legal by the length rule and still looks broken, so the second
    /// pass moves the break toward the middle.
    ///
    /// A single word longer than the line limit gets a line of its own and
    /// overruns it. Breaking inside a word is worse than an over-long line, and
    /// the case only arises for URLs and similar tokens.
    static func wrap(_ text: String, style: Style) -> [String] {
        let words = splitWords(text)
        guard !words.isEmpty else { return [] }
        if text.count <= style.maxLineLength { return [text] }

        var lines: [String] = []
        var line = ""
        for word in words {
            if line.isEmpty {
                line = word
            } else if line.count + 1 + word.count <= style.maxLineLength {
                line += " " + word
            } else {
                lines.append(line)
                line = word
            }
        }
        if !line.isEmpty { lines.append(line) }

        if lines.count == 2 {
            let balanced = balance(words, maxLineLength: style.maxLineLength)
            if let balanced { lines = balanced }
        }
        return lines
    }

    /// Pick the two-line split whose halves are closest in length, provided
    /// both still fit. Returns nil when no split fits, leaving the greedy
    /// result alone.
    private static func balance(_ words: [String], maxLineLength: Int) -> [String]? {
        guard words.count >= 2 else { return nil }
        var best: [String]?
        var bestDelta = Int.max
        for cut in 1..<words.count {
            let first = words[0..<cut].joined(separator: " ")
            let second = words[cut...].joined(separator: " ")
            guard first.count <= maxLineLength, second.count <= maxLineLength else { continue }
            let delta = abs(first.count - second.count)
            if delta < bestDelta {
                bestDelta = delta
                best = [first, second]
            }
        }
        return best
    }

    /// Number the cues, enforce the minimum on-screen time, and keep them from
    /// overlapping. A cue shorter than the minimum is stretched forward only as
    /// far as the next cue's start, which is the one thing a player cannot
    /// recover from on its own.
    private static func finalize(_ cues: [Cue], style: Style) -> [Cue] {
        // Sort before anything else. The overlap clamp below sets a cue's end
        // to the next cue's start, which produces an end *before* the start
        // when the input is out of order - a backwards timecode that some
        // players respond to by dropping the whole file. Batch output from one
        // engine is ordered, but `speech export` reads any json document, and
        // diarization merges and refined segments can reorder.
        var result = cues.enumerated()
            .sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset
                                                           : $0.element.start < $1.element.start }
            .map(\.element)
        for i in result.indices {
            if result[i].end < result[i].start { result[i].end = result[i].start }
            if result[i].end - result[i].start < style.minDuration {
                let wanted = result[i].start + style.minDuration
                let ceiling = i + 1 < result.count ? result[i + 1].start : Double.greatestFiniteMagnitude
                result[i].end = max(result[i].end, min(wanted, ceiling))
            }
            if i + 1 < result.count, result[i].end > result[i + 1].start {
                // max() with the start keeps a cue that genuinely overlaps its
                // successor from ending before it began.
                result[i].end = max(result[i].start, result[i + 1].start)
            }
            result[i].index = i + 1
        }
        return result
    }
}

public enum TranscriptRenderer {
    public static func render(_ document: TranscriptDocument, as format: TranscriptFormat) throws -> String {
        switch format {
        case .txt:
            return plainText(document.segments)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            let data = try encoder.encode(document)
            guard let string = String(data: data, encoding: .utf8) else {
                throw SpeechError.runtime("cannot encode transcript as JSON")
            }
            return string
        case .srt:
            return srt(SubtitleBuilder.cues(from: document.segments))
        case .vtt:
            return vtt(SubtitleBuilder.cues(from: document.segments))
        }
    }

    public static func plainText(_ segments: [Segment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public static func srt(_ cues: [Cue]) -> String {
        var out = ""
        for cue in cues {
            out += "\(cue.index)\n"
            out += "\(timecode(cue.start, separator: ",")) --> \(timecode(cue.end, separator: ","))\n"
            out += cue.text + "\n\n"
        }
        return out
    }

    public static func vtt(_ cues: [Cue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(timecode(cue.start, separator: ".")) --> \(timecode(cue.end, separator: "."))\n"
            out += cue.text + "\n\n"
        }
        return out
    }

    /// HH:MM:SS,mmm for srt and HH:MM:SS.mmm for vtt. Rounded rather than
    /// truncated, and clamped at zero: a negative timestamp makes some players
    /// drop the whole file rather than the one cue.
    static func timecode(_ seconds: Double, separator: String) -> String {
        let clamped = max(0, seconds)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, milliseconds)
    }
}
