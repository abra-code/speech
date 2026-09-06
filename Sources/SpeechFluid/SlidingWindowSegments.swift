// SlidingWindowSegments.swift - the state machine that turns FluidAudio's
// sliding-window updates into segments.
//
// Extracted from `ParakeetLiveSession` for the reason the ggml path learned the
// hard way: the session is an actor that cannot be built without four compiled
// CoreML models, so nothing inside it could be tested, and the review that
// followed found three separate mapping defects sitting in exactly the part no
// test could reach. This is the same shape `StreamSegmentAccumulator` has for
// transcribe.cpp - a plain struct with one method, no isolation, no
// dependencies beyond the update type itself, and an initializer any test can
// call.
//
// The mapping it implements is one line long and took a measurement to find:
// every update is a finished segment. The reasoning is in
// `ParakeetLiveSession`'s header; the short version is that the library
// deduplicates each window's tokens against everything decoded so far and sends
// only the new text, so an update is never revised and `isConfirmed` is a
// statement about the update BEFORE it.

import FluidAudio
import Foundation
import SpeechCore

struct SlidingWindowSegments {
    /// Stamped on every segment, as a primary subtag.
    var language: String?
    /// Whether to carry word timings in the segment. It does not affect the
    /// span, which is always taken from the timings when there are any - see
    /// the note in `absorb`.
    var wantWords: Bool

    private(set) var finals: [Segment] = []
    private var nextID = 0

    init(language: String? = nil, wantWords: Bool = true) {
        self.language = language
        self.wantWords = wantWords
    }

    /// Fold one update in, and return the segment to publish - or nil when
    /// there is nothing to say.
    ///
    /// An empty update is dropped rather than emitted. Windows over silence
    /// produce them, and a `segment.final` carrying no text is a real event on
    /// the wire that costs `--refine` a whole model inference to re-transcribe
    /// nothing.
    mutating func absorb(_ update: SlidingWindowTranscriptionUpdate) -> Segment? {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Built whatever the caller asked for, because the span comes from them
        // too. Gating the whole computation on `wantWords` - which the first
        // version of this did - left every segment at start 0, end 0 for any
        // caller that did not want word timings, which meant `lastConfirmedEnd`
        // never advanced and every refinement slice came back empty.
        let timings = update.tokenTimings.isEmpty ? [] : buildWordTimings(from: update.tokenTimings)
        // The window's own timeline, already moved into session time by the
        // library's `applyGlobalFrameOffset`. `update.timestamp` is a wall
        // clock `Date` and says nothing about position in the audio, so it is
        // not a substitute: a window with no timings gets the previous
        // segment's end for both bounds rather than a fabricated range.
        let start = timings.first?.startTime ?? finals.last?.end ?? 0
        let end = max(start, timings.last?.endTime ?? start)
        let words = wantWords && !timings.isEmpty
            ? timings.map { Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
            : nil

        let segment = Segment(
            id: nextID,
            start: start,
            end: end,
            text: text,
            words: words,
            confidence: update.confidence,
            speaker: nil,
            language: language.map(Language.primarySubtag))
        finals.append(segment)
        nextID += 1
        return segment
    }
}
