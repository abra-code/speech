// AppleResults.swift - one place that turns an Apple transcription result into
// a `Segment`.
//
// Both paths need it and they must not drift: the batch path's numbers are the
// baseline every other row in the catalog is measured against, and the live
// path's numbers are compared to that baseline. Two copies of this mapping
// would eventually differ by a trim or a confidence average, and the difference
// would look like a model difference.

import AVFoundation
import Foundation
import SpeechCore

#if canImport(Speech)
import Speech

@available(macOS 26, *)
enum AppleResults {
    /// An attributed result plus its range, as the project's segment.
    ///
    /// Word timings come from the runs carrying `.audioTimeRange`; a result
    /// with none (which is what a volatile result usually is) yields a segment
    /// with `words == nil` rather than an empty array, because "no word timings
    /// exist" and "this segment contains no words" are different claims.
    static func segment(
        id: Int, text: AttributedString, range: CMTimeRange, language: String
    ) -> Segment {
        var words: [Word] = []
        var confidences: [Double] = []
        for run in text.runs {
            if let confidence = run.transcriptionConfidence {
                confidences.append(confidence)
            }
            guard let timeRange = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            words.append(Word(
                text: piece,
                start: seconds(timeRange.start),
                end: seconds(timeRange.end),
                confidence: run.transcriptionConfidence.map { Float($0) }))
        }

        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let start = seconds(range.start)
        let end = max(start, seconds(range.end))
        return Segment(
            id: id,
            start: words.first?.start ?? start,
            end: words.last?.end ?? end,
            text: plain,
            words: words.isEmpty ? nil : words,
            confidence: confidences.isEmpty
                ? nil
                : Float(confidences.reduce(0, +) / Double(confidences.count)),
            speaker: nil,
            language: Language.primarySubtag(language))
    }

    /// CMTime arithmetic on an invalid or indefinite time yields NaN, which
    /// would encode as invalid JSON and take the whole event stream with it.
    static func seconds(_ time: CMTime) -> Double {
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? max(0, value) : 0
    }
}

#endif
