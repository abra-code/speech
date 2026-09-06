// FluidStreamingTests.swift - the cache-aware streaming mapping and the
// session lifecycle around it, both without a model.
//
// The two rows this covers cannot be constructed in a test: between them they
// want seven compiled CoreML bundles and about a gigabyte of weights. That is
// the same wall the sliding-window row hit, and it is why the mapping is a
// plain struct and the session takes its manager behind a protocol - a fake
// backend is four lines, and the lifecycle is where the last two reviews found
// every defect worth finding.

import AVFoundation
import Foundation
import Testing

@testable import SpeechCore
@testable import SpeechFluid

@Suite("Fluid streaming segments")
struct FluidStreamingSegmentsTests {
    static func words(_ entries: [(String, Double, Double)]) -> [Word] {
        entries.map { Word(text: $0.0, start: $0.1, end: $0.2) }
    }

    static func segment(_ event: LiveEvent?) -> Segment? {
        switch event {
        case .final(let segment), .partial(let segment): return segment
        case nil: return nil
        }
    }

    static func finals(_ events: [LiveEvent]) -> [Segment] {
        events.compactMap { if case .final(let segment) = $0 { return segment } else { return nil } }
    }

    static func partials(_ events: [LiveEvent]) -> [Segment] {
        events.compactMap { if case .partial(let segment) = $0 { return segment } else { return nil } }
    }

    @Test("text with no sentence in it is a partial and nothing else")
    func partialUntilSentence() {
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "hello there",
            words: Self.words([("hello", 0.5, 1.0), ("there", 1.0, 1.5)]),
            receivedSeconds: 2.0,
            isFinal: false)

        #expect(Self.finals(events).isEmpty)
        let partial = Self.partials(events).first
        #expect(partial?.text == "hello there")
        // The start is the first word's, not the accumulator's zero: a partial
        // that claims to begin at the top of the session would make every
        // refinement slice start there too.
        #expect(partial?.start == 0.5)
        // The end is the audio position. The text is still growing, and the
        // honest answer for where it reaches is what has been heard.
        #expect(partial?.end == 2.0)
        // No words on a partial: its last one is the most likely to change.
        #expect(partial?.words == nil)
    }

    @Test("a closed segment takes its span from the words its text is made of")
    func spanFromWords() {
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "hello there. bye",
            words: Self.words([("hello", 0.5, 1.0), ("there.", 1.0, 1.5), ("bye", 2.0, 2.4)]),
            receivedSeconds: 2.6,
            isFinal: false)

        let final = Self.finals(events).first
        #expect(final?.text == "hello there.")
        // The accumulator cut this sentence at 1.8 s by interpolating the
        // character position into the time range. The words say 1.5, which is
        // when the speaker actually stopped saying it.
        #expect(final?.start == 0.5)
        #expect(final?.end == 1.5)
        #expect(final?.words?.map(\.text) == ["hello", "there."])

        // And the word that belongs to the next sentence stayed there.
        let partial = Self.partials(events).first
        #expect(partial?.text == "bye")
        #expect(partial?.start == 2.0)
    }

    @Test("the span survives wantWords being false")
    func spanIndependentOfWantWords() {
        // The regression this pins cost the sliding-window row every one of its
        // refinement slices: gating the timing computation on the payload flag
        // left every segment at 0..0. The payload is optional; the span is not.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: false)
        let events = mapper.absorb(
            transcript: "hello there.",
            words: Self.words([("hello", 0.5, 1.0), ("there.", 1.0, 1.5)]),
            receivedSeconds: 2.0,
            isFinal: true)

        let final = Self.finals(events).first
        #expect(final?.start == 0.5)
        #expect(final?.end == 1.5)
        #expect(final?.words == nil)
    }

    @Test("a growing word is corrected rather than published truncated")
    func frontierWordIsNotPublishedEarly() {
        // Why the word list arrives whole rather than as a delta. `hel` is a
        // real intermediate state - the tokenizer emits sub-word pieces - and a
        // delta would have published it as a finished word with an end time.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(
            transcript: "hel",
            words: Self.words([("hel", 0.5, 0.7)]),
            receivedSeconds: 0.8,
            isFinal: false)
        let events = mapper.absorb(
            transcript: "hello.",
            words: Self.words([("hello.", 0.5, 1.0)]),
            receivedSeconds: 1.2,
            isFinal: true)

        let final = Self.finals(events).first
        #expect(final?.text == "hello.")
        #expect(final?.words?.map(\.text) == ["hello."])
        #expect(final?.end == 1.0)
    }

    @Test("words that do not match the text are dropped, and the text is kept")
    func mismatchKeepsTheText() {
        // The failure worth having. A segment with no word timings is
        // incomplete; a segment whose word timings describe different text is
        // wrong, and nothing downstream can tell.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "hello there.",
            words: Self.words([("bonjour", 0.5, 1.0)]),
            receivedSeconds: 2.0,
            isFinal: true)

        let final = Self.finals(events).first
        #expect(final?.text == "hello there.")
        #expect(final?.words == nil)
        // The estimated span stands rather than being replaced by a word from
        // some other transcript.
        #expect(final?.end == 1.0)
    }

    @Test("consecutive segments do not share a word or overlap in time")
    func segmentsDoNotOverlap() {
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(
            transcript: "one. two. three.",
            words: Self.words([
                ("one.", 0.0, 1.0), ("two.", 1.2, 2.0), ("three.", 2.2, 3.0),
            ]),
            receivedSeconds: 3.2,
            isFinal: true)

        #expect(mapper.finals.map(\.text) == ["one.", "two.", "three."])
        #expect(mapper.finals.map(\.start) == [0.0, 1.2, 2.2])
        #expect(mapper.finals.map(\.end) == [1.0, 2.0, 3.0])
        for (earlier, later) in zip(mapper.finals, mapper.finals.dropFirst()) {
            #expect(later.start >= earlier.end)
        }
        // Each word landed in exactly one segment.
        let published = mapper.finals.flatMap { $0.words ?? [] }.map(\.text)
        #expect(published == ["one.", "two.", "three."])
    }

    @Test("the end of the stream closes text with no terminator")
    func flushClosesTheRemainder() {
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(
            transcript: "no full stop here",
            words: Self.words([("no", 0.0, 0.4), ("full", 0.4, 0.8),
                               ("stop", 0.8, 1.2), ("here", 1.2, 1.6)]),
            receivedSeconds: 1.8,
            isFinal: false)
        #expect(mapper.finals.isEmpty)

        let events = mapper.absorb(
            transcript: "no full stop here",
            words: Self.words([("no", 0.0, 0.4), ("full", 0.4, 0.8),
                               ("stop", 0.8, 1.2), ("here", 1.2, 1.6)]),
            receivedSeconds: 1.8,
            isFinal: true)
        #expect(Self.finals(events).map(\.text) == ["no full stop here"])
        #expect(Self.finals(events).first?.end == 1.6)
        // A flush publishes no partial - there is nothing left to revise.
        #expect(Self.partials(events).isEmpty)
    }

    @Test("a transcript with no timings still reaches the wire")
    func noTimingsAtAll() {
        // Should not happen: both managers record a timing for every token they
        // emit. If it ever does, losing the text would be far worse than losing
        // the span, and a span pinned at zero would leave every refinement
        // slice empty.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "text with no timings.",
            words: [],
            receivedSeconds: 4.0,
            isFinal: true)

        let final = Self.finals(events).first
        #expect(final?.text == "text with no timings.")
        #expect(final?.end == 4.0)
        #expect(final?.words == nil)
    }

    @Test("the language tag is stamped as a primary subtag")
    func languageTag() {
        var mapper = FluidStreamingSegments(language: "pl-PL", wantWords: true)
        let events = mapper.absorb(
            transcript: "dzien dobry.", words: Self.words([("dzien dobry.", 0, 1)]),
            receivedSeconds: 1, isFinal: true)
        #expect(Self.finals(events).first?.language == "pl")
    }

    @Test("matching takes the words this text is made of and leaves the rest")
    func matchTakesWhatTheTextCovers() {
        // Words past the end of the text are the next segment's, not a failure.
        let words = Self.words([("one", 0, 1), ("two", 1, 2), ("three", 2, 3)])
        let matched = FluidStreamingSegments.match(words[...], to: "one two")
        #expect(matched.map(\.text) == ["one", "two"])
    }

    @Test("a word list that covers only part of the text matches nothing")
    func partialCoverageIsNoMatch() {
        // All or nothing, and a review earned it. A prefix looks like a partial
        // success and is worse than a failure: the segment would be published
        // ending where the scan stopped - in the middle of itself - and the
        // refinement slice and the buffer's discard point would both be cut
        // short with nothing saying so. Here the tokenizer dropped `quick`.
        let words = Self.words([("The", 0, 0.4), ("brown", 0.8, 1.2), ("fox.", 1.2, 1.6)])
        #expect(FluidStreamingSegments.match(words[...], to: "The quick brown fox.").isEmpty)
    }

    @Test("a word is matched where it sits, not wherever it next appears")
    func matchIsAnchored() {
        // The unanchored version of this scan found a one-character word inside
        // the middle of the following sentence and handed that sentence the
        // span of a token from the previous one.
        let words = Self.words([("!", 0.96, 1.04), ("Wow!", 2.0, 2.4)])
        #expect(FluidStreamingSegments.match(words[...], to: "Wow!").isEmpty)
    }

    @Test("words sharing an encoder frame do not make segments overlap")
    func sharedFrameDoesNotOverlap() {
        // Token times are a frame index times 0.08 s and the decoder emits
        // several tokens on one frame, so a word boundary falling inside a
        // frame gives the next word a start before the previous word's end.
        // That is a real overlap in the audio and an impossible one on the
        // wire, so the span moves forward and the words keep their own times.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        _ = mapper.absorb(
            transcript: "I saw a cat. A dog ran.",
            words: Self.words([
                ("I", 0.0, 0.24), ("saw", 0.24, 0.48), ("a", 0.48, 0.56), ("cat.", 0.56, 1.00),
                ("A", 0.96, 1.04), ("dog", 1.04, 1.40), ("ran.", 1.40, 1.80),
            ]),
            receivedSeconds: 2.0,
            isFinal: true)

        #expect(mapper.finals.map(\.text) == ["I saw a cat.", "A dog ran."])
        #expect(mapper.finals.map(\.start) == [0.0, 1.0])
        #expect(mapper.finals.map(\.end) == [1.0, 1.8])
        // The word keeps the time it was said at, which is before the segment
        // it belongs to is allowed to start.
        #expect(mapper.finals.last?.words?.first?.start == 0.96)
    }

    @Test("a partial cannot open before the last final closed either")
    func partialDoesNotReachBack() {
        // The straddling word is usually the one that opens the next partial,
        // so this is the commoner half of the same defect rather than the
        // rarer one.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "I saw a cat. A dog",
            words: Self.words([
                ("I", 0.0, 0.24), ("saw", 0.24, 0.48), ("a", 0.48, 0.56), ("cat.", 0.56, 1.00),
                ("A", 0.96, 1.04), ("dog", 1.04, 1.40),
            ]),
            receivedSeconds: 1.6,
            isFinal: false)

        #expect(Self.finals(events).map(\.end) == [1.0])
        let partial = Self.partials(events).first
        #expect(partial?.text == "A dog")
        #expect(partial?.start == 1.0)
    }

    @Test("a segment whose words do not match still cannot open behind the one before it")
    func unmatchedSegmentStaysMonotonic() {
        // The overlap does not come from the matched segments, it comes from
        // mixing the two clocks. A final that matched publishes an end taken
        // from the audio, which is later here than the character-fraction
        // estimate the accumulator cut on - so the next final, if its words do
        // not match and it keeps that estimate, opens 110 ms behind the final
        // before it.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "A very long first sentence indeed. Hi.",
            words: Self.words([
                ("A", 0.10, 0.20), ("very", 0.20, 0.60), ("long", 0.60, 0.90),
                ("first", 0.90, 1.20), ("sentence", 1.20, 1.60), ("indeed.", 1.60, 1.90),
                ("Bonjour", 1.95, 2.00),
            ]),
            receivedSeconds: 2.0,
            isFinal: true)

        let finals = Self.finals(events)
        #expect(finals.map(\.text) == ["A very long first sentence indeed.", "Hi."])
        #expect(finals.first?.end == 1.90)
        // Not the accumulator's estimate, which is behind that.
        #expect(finals.last?.start == 1.90)
        #expect(finals.last?.words == nil)
        for (earlier, later) in zip(finals, finals.dropFirst()) {
            #expect(later.start >= earlier.end)
        }
    }

    @Test("a partial with no word of its own still cannot open behind the last final")
    func partialWithNoFrontierWord() {
        // Reachable through the drop loop: it takes any word ending exactly
        // where the segment did, and two tokens landing on one encoder frame
        // produce exactly that. The partial is then left with no word to open
        // on, and without the clamp it falls back to an estimate that sits
        // behind the final just published.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let events = mapper.absorb(
            transcript: "One. Two",
            words: Self.words([("One.", 0.0, 1.0), ("Two", 0.5, 1.0)]),
            receivedSeconds: 1.4,
            isFinal: false)

        #expect(Self.finals(events).map(\.end) == [1.0])
        let partial = Self.partials(events).first
        #expect(partial?.text == "Two")
        #expect(partial?.start == 1.0)
        #expect(partial?.end == 1.4)
    }

    @Test("words are consumed across polls, not rematched from the start")
    func consumedAcrossPolls() {
        // Nothing else drives `close` more than once, and the index that says
        // which words are already inside a segment only moves there.
        var mapper = FluidStreamingSegments(language: "en-US", wantWords: true)
        let first = Self.words([("One.", 0.0, 0.8), ("Two", 1.0, 1.4)])
        _ = mapper.absorb(
            transcript: "One. Two", words: first, receivedSeconds: 1.5, isFinal: false)
        let second = first + Self.words([("more.", 1.4, 1.9), ("Three.", 2.1, 2.6)])
        _ = mapper.absorb(
            transcript: "One. Two more. Three.", words: second,
            receivedSeconds: 2.8, isFinal: true)

        #expect(mapper.finals.map(\.text) == ["One.", "Two more.", "Three."])
        #expect(mapper.finals.map(\.start) == [0.0, 1.0, 2.1])
        #expect(mapper.finals.map(\.end) == [0.8, 1.9, 2.6])
        #expect(mapper.finals.map { $0.words?.map(\.text) ?? [] }
            == [["One."], ["Two", "more."], ["Three."]])
    }

    @Test("a segment with no word boundary in it keeps its text and loses only its words")
    func scriptWithoutWordBoundaries() {
        // Reachable in the scripts that do not separate words. This model's
        // vocabulary marks a word start on 206 of its 6910 CJK pieces, so a
        // Japanese segment can easily contain none at all - and then the
        // joiner's one "word" spans the whole utterance and matches no single
        // sentence.
        //
        // What is asserted here is the safe degradation, not a claim about the
        // language: the text and the segmentation are right and the span falls
        // back to the accumulator's estimate. Where marked pieces DO occur the
        // words line up exactly as they do in English, because the detokenizer
        // renders each mark as a space - checked against the model's own
        // tokenizer.json, after the first version of this comment asserted the
        // opposite from reading the joiner alone.
        var mapper = FluidStreamingSegments(language: "ja-JP", wantWords: true)
        let events = mapper.absorb(
            transcript: "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{3002}\u{3055}\u{3088}\u{3046}\u{306A}\u{3089}\u{3002}",
            words: Self.words([("\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{3002}\u{3055}\u{3088}\u{3046}\u{306A}\u{3089}\u{3002}", 0.0, 2.0)]),
            receivedSeconds: 2.2,
            isFinal: true)

        #expect(Self.finals(events).map(\.text)
            == ["\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{3002}", "\u{3055}\u{3088}\u{3046}\u{306A}\u{3089}\u{3002}"])
        #expect(Self.finals(events).allSatisfy { $0.words == nil })
    }
}

/// A backend that hands over whatever the test scripted, so the session's
/// lifecycle can be driven without a model.
actor ScriptedStreamingBackend: FluidStreamingBackend {
    private var polls: [FluidStreamingPoll?]
    private let final: FluidStreamingPoll
    private let failOnFlush: Bool
    private(set) var resets = 0
    private(set) var feeds = 0

    init(polls: [FluidStreamingPoll?], final: FluidStreamingPoll, failOnFlush: Bool = false) {
        self.polls = polls
        self.final = final
        self.failOnFlush = failOnFlush
    }

    func feed(_ samples: [Float]) async throws -> FluidStreamingPoll? {
        feeds += 1
        guard !polls.isEmpty else { return nil }
        return polls.removeFirst()
    }

    func flush() async throws -> FluidStreamingPoll {
        if failOnFlush { throw SpeechError.runtime("the encoder gave up") }
        return final
    }

    func reset() async { resets += 1 }
}

/// A backend whose `feed` parks until the test lets it go, so `finish()` can be
/// made to land in the middle of a chunk decode.
actor GatedStreamingBackend: FluidStreamingBackend {
    private var release: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    private var feedArrived = false
    private let late: FluidStreamingPoll
    private let final: FluidStreamingPoll

    init(late: FluidStreamingPoll, final: FluidStreamingPoll) {
        self.late = late
        self.final = final
    }

    func feed(_ samples: [Float]) async throws -> FluidStreamingPoll? {
        feedArrived = true
        arrived?.resume()
        arrived = nil
        await withCheckedContinuation { release = $0 }
        return late
    }

    func flush() async throws -> FluidStreamingPoll { final }
    func reset() async {}

    /// Returns once `feed` has parked.
    func waitForFeed() async {
        if feedArrived { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func letFeedFinish() {
        release?.resume()
        release = nil
    }
}

@Suite("Fluid streaming session")
struct FluidStreamingSessionTests {
    static func poll(_ text: String, _ words: [(String, Double, Double)]) -> FluidStreamingPoll {
        FluidStreamingPoll(
            transcript: text,
            words: words.map { Word(text: $0.0, start: $0.1, end: $0.2) })
    }

    static func buffer(seconds: Double) -> CapturedAudio {
        let format = LiveAudioFormat.canonical
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: 0.01, count: Int(frames))
        return CapturedAudio(buffer)
    }

    static func collect(_ session: FluidStreamingSession) -> Task<[LiveEvent], Never> {
        let events = session.events
        return Task { var seen: [LiveEvent] = []; for await event in events { seen.append(event) }; return seen }
    }

    @Test("a session publishes partials, then a final, then closes its stream")
    func happyPath() async throws {
        let backend = ScriptedStreamingBackend(
            polls: [Self.poll("hello", [("hello", 0.0, 0.5)]), nil],
            final: Self.poll("hello there.", [("hello", 0.0, 0.5), ("there.", 0.5, 1.0)]))
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)

        try await session.feed(Self.buffer(seconds: 0.5))
        try await session.feed(Self.buffer(seconds: 0.5))
        let finals = try await session.finish()

        let events = await reader.value
        #expect(finals.map(\.text) == ["hello there."])
        #expect(finals.first?.end == 1.0)
        // Two feeds, one of which decoded nothing: the session must not have
        // published anything for the nil poll.
        #expect(events.count == 2)
        if case .partial(let partial) = events[0] {
            #expect(partial.text == "hello")
        } else {
            Issue.record("the first event was not a partial")
        }
        if case .final(let final) = events[1] {
            #expect(final.text == "hello there.")
        } else {
            Issue.record("the last event was not a final")
        }
        // The manager goes back to the engine clean, whichever way the session
        // ended.
        #expect(await backend.resets == 1)
    }

    @Test("a failed flush keeps the transcript and reports the failure every time")
    func flushFailureKeepsWork() async throws {
        let backend = ScriptedStreamingBackend(
            polls: [Self.poll("first sentence. second", [
                ("first", 0.0, 0.5), ("sentence.", 0.5, 1.0), ("second", 1.2, 1.6),
            ])],
            final: Self.poll("", []),
            failOnFlush: true)
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)
        try await session.feed(Self.buffer(seconds: 1.6))

        // The transcript travels with the error rather than being thrown away.
        await #expect(throws: LiveSessionFailure.self) { try await session.finish() }
        do {
            _ = try await session.finish()
            Issue.record("a repeated finish() reported a clean run")
        } catch let failure as LiveSessionFailure {
            #expect(failure.segments.map(\.text) == ["first sentence."])
        }
        _ = await reader.value
        #expect(await backend.resets == 1)
    }

    @Test("cancel closes the stream without flushing")
    func cancelDoesNotFlush() async throws {
        let backend = ScriptedStreamingBackend(
            polls: [Self.poll("half a sentence", [("half", 0.0, 0.5)])],
            final: Self.poll("should never be published.", []),
            failOnFlush: false)
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)

        try await session.feed(Self.buffer(seconds: 0.5))
        await session.cancel()

        let events = await reader.value
        #expect(events.count == 1)
        for event in events {
            if case .final(let segment) = event {
                Issue.record("cancel published a final: \(segment.text)")
            }
        }
        #expect(await backend.resets == 1)
    }

    @Test("a decode that lands after finish does not add a segment nobody saw")
    func feedResumingAfterFinish() async throws {
        // `feed` suspends for the length of a chunk decode, and a `finish()`
        // arriving in that gap publishes the final and closes the event stream.
        // Yielding into a closed continuation is a silent no-op, so without the
        // second check the resumed feed would append a segment to `finals` that
        // no reader ever saw - and the transcript returned by a repeated
        // `finish()` would disagree with the events the session published.
        // The late transcript has to CLOSE a sentence, not merely carry text.
        // The first version of this test ended it in a bare terminator, which
        // mid-stream is not a sentence at all - so the resumed feed emitted a
        // partial, nothing was appended to `finals`, and the test passed with
        // the guard deleted. It is append-only relative to what the flush
        // already published, the way these managers really behave.
        let backend = GatedStreamingBackend(
            late: Self.poll(
                "in time. far too late. and more",
                [("in", 0.0, 0.4), ("time.", 0.4, 0.8),
                 ("far", 2.0, 2.2), ("too", 2.2, 2.4), ("late.", 2.4, 2.8),
                 ("and", 3.0, 3.2), ("more", 3.2, 3.4)]),
            final: Self.poll("in time.", [("in", 0.0, 0.4), ("time.", 0.4, 0.8)]))
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)

        let feeding = Task { try await session.feed(Self.buffer(seconds: 0.5)) }
        await backend.waitForFeed()
        let finals = try await session.finish()
        await backend.letFeedFinish()
        try await feeding.value

        let events = await reader.value
        #expect(finals.map(\.text) == ["in time."])
        #expect(events.count == 1)
        // The transcript a second caller sees is the one that went out.
        let again = try await session.finish()
        #expect(again.map(\.text) == ["in time."])
    }

    @Test("feeding after finish is ignored rather than decoded")
    func feedAfterFinish() async throws {
        let backend = ScriptedStreamingBackend(
            polls: [Self.poll("one.", [("one.", 0.0, 0.5)])],
            final: Self.poll("one.", [("one.", 0.0, 0.5)]))
        let session = FluidStreamingSession(
            backend: backend, catalogID: "fluid.test", language: "en-US", wantWords: true)
        let reader = Self.collect(session)

        try await session.feed(Self.buffer(seconds: 0.5))
        _ = try await session.finish()
        try await session.feed(Self.buffer(seconds: 0.5))

        _ = await reader.value
        // One feed reached the backend. The second arrived after the stream was
        // closed, and yielding into a finished continuation is a silent no-op -
        // so the audio has to stop at the session rather than at the stream.
        #expect(await backend.feeds == 1)
    }
}
