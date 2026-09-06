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
//
// `absorb` returns a `LiveEvent` rather than a `Segment` so that one line is
// inside the tested surface. A review found the gap: while this returned a
// segment, the partial-versus-final decision lived in the actor, and putting
// `isConfirmed ? .final : .partial` back at the call site left all nine tests
// green while restoring the exact defect they were written for.

import FluidAudio
import Foundation
import SpeechCore

struct SlidingWindowSegments {
    /// Stamped on every segment, as a primary subtag.
    let language: String?
    /// Whether to carry word timings in the segment. It does not affect the
    /// span, which is always taken from the timings when there are any - see
    /// the note in `absorb`.
    let wantWords: Bool

    private(set) var finals: [Segment] = []
    private var nextID = 0

    init(language: String? = nil, wantWords: Bool = true) {
        self.language = language
        self.wantWords = wantWords
    }

    /// Fold one update in, and return the event to publish - or nil when there
    /// is nothing to say.
    ///
    /// Always `.final`, never `.partial`, and that is the whole mapping: the
    /// library deduplicates each window's tokens against everything decoded so
    /// far and never re-sends a window, so there is no later version of this
    /// text to wait for. `isConfirmed` describes the update before this one.
    ///
    /// An empty update is dropped rather than emitted. Windows over silence
    /// produce them, and a `segment.final` carrying no text is a real event on
    /// the wire that costs `--refine` a whole model inference to re-transcribe
    /// nothing.
    mutating func absorb(_ update: SlidingWindowTranscriptionUpdate) -> LiveEvent? {
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
        //
        // Clamped forward, and not defensively: the library's final-window
        // re-decode backs its emission cutoff off by
        // `redecodeEmissionJitterFrames` (5 frames, 0.40 s at 0.08 s per
        // encoder frame) because a re-decoded token can land a few frames from
        // where it first emitted. A token that survives dedup with a timestamp
        // inside that margin is new text whose audio genuinely overlaps the
        // previous segment's tail - so the overlap is real, and what has to
        // give is the wire format, which cannot express two segments covering
        // the same instant. The words keep their true times; only the span the
        // transcript is ordered and sliced by is moved forward.
        let floor = finals.last?.end ?? 0
        let start = max(timings.first?.startTime ?? floor, floor)
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
        return .final(segment)
    }
}
