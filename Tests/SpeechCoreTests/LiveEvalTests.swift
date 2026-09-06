// LiveEvalTests.swift - `speech eval --live`.
//
// Two things are pinned here, and they are pinned separately on purpose.
//
// The trailing-loss rule is pure arithmetic over token arrays, so it is tested
// as arithmetic: no audio, no engine, no clock. It is the number the whole live
// measurement exists to produce, and every one of its edge cases - a wrong last
// word, an empty hypothesis, a hallucinated tail - has a defensible answer that
// is written down below rather than left to whatever the alignment happened to
// do.
//
// The evaluator itself is driven with a scripted session that publishes text on
// a clock made of the audio it was fed. That makes the metrics deterministic:
// a cue at 1.0 s IS at 1.0 s of audio, whatever the machine was doing, because
// the session counts frames rather than looking at a wall clock.
//
// The runs here use --pace far above 1, which is exactly what the CLI warns
// about for a real measurement. That is correct for a test - what is being
// checked is that the numbers are computed and carried, not what they are on
// this machine - and it is also why none of these tests assert a latency value.

import AVFoundation
import Foundation
import Testing

@testable import SpeechCore

@Suite("Trailing reference loss")
struct TrailingLossTests {
    @Test("a complete transcript loses nothing")
    func complete() {
        #expect(Scorer.trailingReferenceLoss(
            reference: "the quick brown fox jumps",
            hypothesis: "the quick brown fox jumps") == 0)
    }

    @Test("a transcript that stops early loses the rest")
    func stopsEarly() {
        #expect(Scorer.trailingReferenceLoss(
            reference: "the quick brown fox jumps over the lazy dog",
            hypothesis: "the quick brown fox jumps") == 4)
    }

    @Test("a wrong last word is a substitution, not a loss")
    func wrongLastWord() {
        // The tie between "the prefix ends before this word" and "this word was
        // recognized wrongly" resolves toward the longer prefix, so a bad word
        // counts against WER and leaves this metric alone. Otherwise every
        // mis-heard final word in the corpus would be reported as dropped
        // audio, which is a different defect with a different fix.
        #expect(Scorer.trailingReferenceLoss(
            reference: "the quick brown fox",
            hypothesis: "the quick brown box") == 0)
    }

    @Test("errors in the middle do not count as a trailing loss")
    func middleErrors() {
        #expect(Scorer.trailingReferenceLoss(
            reference: "one two three four five",
            hypothesis: "one seven four five") == 0)
    }

    @Test("an empty hypothesis loses the whole reference")
    func emptyHypothesis() {
        #expect(Scorer.trailingReferenceLoss(
            reference: "one two three", hypothesis: "") == 3)
        #expect(Scorer.trailingReferenceLoss(reference: "", hypothesis: "") == 0)
        #expect(Scorer.trailingReferenceLoss(reference: "", hypothesis: "one two") == 0)
    }

    @Test("a hallucinated tail is not a loss")
    func hallucinatedTail() {
        // Words the engine invented past the end of the reference are
        // insertions. WER already charges for them; counting them here as well
        // would report a model that says too much as a model that says too
        // little.
        #expect(Scorer.trailingReferenceLoss(
            reference: "one two three",
            hypothesis: "one two three four five six") == 0)
    }

    @Test("normalization applies, so punctuation and case are not a loss")
    func normalized() {
        #expect(Scorer.trailingReferenceLoss(
            reference: "Hello, world.", hypothesis: "hello world") == 0)
    }

    @Test("the rule works on any equatable sequence")
    func generic() {
        #expect(Scorer.trailingLoss(reference: [1, 2, 3, 4], hypothesis: [1, 2]) == 2)
        #expect(Scorer.trailingLoss(reference: [1, 2, 3, 4], hypothesis: [1, 2, 3, 4]) == 0)
        #expect(Scorer.trailingLoss(reference: [Int](), hypothesis: [1]) == 0)
    }
}

@Suite("Live evaluator")
struct LiveEvaluatorTests {
    static func sink() -> EventSink {
        EventSink(mode: .jsonl, out: .nullDevice, err: .nullDevice)
    }

    static func manifest(
        in directory: URL, seconds: Double, reference: String
    ) throws -> [ManifestRow] {
        let audio = try Fixtures.makeWAV(in: directory, seconds: seconds)
        return [ManifestRow(index: 1, audioURL: audio, reference: reference)]
    }

    @Test("the whole transcript is scored and the live metrics come back")
    func scoresAndMeasures() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }
        let rows = try Self.manifest(
            in: directory, seconds: 4, reference: "one two three four")

        let engine = ScriptedLiveEngine(cues: [
            .partial("one", at: 0.5),
            .final("one two", at: 1.5, end: 1.5),
            .partial("three", at: 2.5),
            .final("three four", at: 3.5, end: 3.5),
        ])
        let outcome = try await LiveEvaluator.run(
            engine: engine, catalogID: "fake.live", rows: rows, language: "en-US",
            pace: 40, sink: Self.sink())

        #expect(outcome.summary.rows == 1)
        #expect(outcome.rows.first?.hypothesis == "one two three four")
        #expect(outcome.summary.wer == 0)

        let live = try #require(outcome.rows.first?.live)
        #expect(live.finals == 2)
        #expect(live.partials == 2)
        #expect(live.trailingWordsLost == 0)
        #expect(live.droppedBuffers == 0)
        // Timed, not asserted to a value: what matters is that something was
        // recorded rather than left nil, because nil is the answer for an
        // engine that emits no partials at all.
        #expect(live.firstPartialSeconds != nil)
        #expect(live.firstFinalSeconds != nil)
        #expect(live.maxFinalLagSeconds != nil)

        let summary = try #require(outcome.summary.live)
        #expect(summary.pace == 40)
        #expect(summary.trailingWordsLost == 0)
        #expect(summary.rowsEndingEarly == 0)
        #expect(summary.rowsWithNoText == 0)
        #expect(summary.rowsWithoutPartials == 0)
        #expect(summary.droppedBuffers == 0)
    }

    @Test("a session that stops before the speaker does is reported as a trailing loss")
    func trailingLossIsMeasured() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }
        let rows = try Self.manifest(
            in: directory, seconds: 4, reference: "one two three four five six")

        // The FluidAudio #855 shape, and the shape of this project's own
        // `finish()` defect: the session tracks the speaker and then simply
        // stops, with no error anywhere.
        let engine = ScriptedLiveEngine(cues: [.final("one two three", at: 1.5, end: 1.5)])
        let outcome = try await LiveEvaluator.run(
            engine: engine, catalogID: "fake.live", rows: rows, language: "en-US",
            pace: 40, sink: Self.sink())

        let live = try #require(outcome.rows.first?.live)
        #expect(live.trailingWordsLost == 3)
        #expect(live.partials == 0)
        let summary = try #require(outcome.summary.live)
        #expect(summary.rowsEndingEarly == 1)
        #expect(summary.rowsWithNoText == 0)
        #expect(summary.rowsWithoutPartials == 1)
    }

    @Test("a silent session is counted as no text rather than as an early stop")
    func silentRow() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }
        let rows = try Self.manifest(in: directory, seconds: 2, reference: "one two three")

        let engine = ScriptedLiveEngine(cues: [])
        let outcome = try await LiveEvaluator.run(
            engine: engine, catalogID: "fake.live", rows: rows, language: "en-US",
            pace: 40, sink: Self.sink())

        let summary = try #require(outcome.summary.live)
        // Both are true of this row, and the report has to separate them: a
        // model that heard nothing is a different problem from one that lost
        // the end of a sentence, and they are fixed in different places.
        #expect(summary.rowsWithNoText == 1)
        #expect(summary.rowsEndingEarly == 0)
        #expect(summary.trailingWordsLost == 3)
        #expect(outcome.summary.wer == 1)
    }

    @Test("a flush the reader has not caught up with is still counted")
    func tailEventsAreCounted() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }
        // Fifty finals, published in one synchronous burst inside `finish()`.
        // The size is the test: a single tail segment is delivered to a reader
        // that is already suspended on `next()` and so gets recorded whatever
        // the join rule is, which makes a one-segment version of this test pass
        // against the bug it is supposed to catch. A burst leaves a real
        // backlog sitting in the stream's buffer at the moment `finish()`
        // returns, which is the state the join rule exists for.
        let words = (1...50).map { "word\($0)" }
        let rows = try Self.manifest(
            in: directory, seconds: 2, reference: words.joined(separator: " "))

        // The regression this pins: the event reader is joined after
        // `finish()`, so a backlog is drained rather than abandoned. Reading it
        // before the flush, or not awaiting it at all, would undercount the
        // finals of every utterance - and it would do so invisibly, because the
        // transcript comes from somewhere else.
        let engine = ScriptedLiveEngine(cues: [], tail: words)
        let outcome = try await LiveEvaluator.run(
            engine: engine, catalogID: "fake.live", rows: rows, language: "en-US",
            pace: 40, sink: Self.sink())

        let live = try #require(outcome.rows.first?.live)
        #expect(live.finals == words.count)
        // The transcript itself comes from `finish()`'s return value rather
        // than from the events, so it is complete either way. That is the point
        // of checking the count: the events are what the latency and
        // trailing-loss numbers are built from, and they can go missing without
        // the transcript showing a mark.
        #expect(outcome.summary.wer == 0)
    }

    @Test("a session that cannot keep up drops audio and says so")
    func dropsAreCounted() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }
        let rows = try Self.manifest(in: directory, seconds: 12, reference: "one two")

        // 12 seconds is 188 buffers at 64 ms. The queue holds 64. A session
        // that takes 15 ms per buffer cannot drain it while the harness is
        // filling it at 100x, so the overflow is not a matter of timing luck.
        let engine = ScriptedLiveEngine(
            cues: [.final("one two", at: 1, end: 1)], feedDelay: .milliseconds(15))
        let outcome = try await LiveEvaluator.run(
            engine: engine, catalogID: "fake.live", rows: rows, language: "en-US",
            pace: 100, sink: Self.sink())

        let live = try #require(outcome.rows.first?.live)
        #expect(live.droppedBuffers > 0)
        let summary = try #require(outcome.summary.live)
        #expect(summary.rowsWithDrops == 1)
    }

    @Test("a row whose session fails is skipped, not fatal")
    func failingRowIsSkipped() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }
        let audio = try Fixtures.makeWAV(in: directory, seconds: 2, name: "a.wav")
        let second = try Fixtures.makeWAV(in: directory, seconds: 2, name: "b.wav")
        let rows = [
            ManifestRow(index: 1, audioURL: audio, reference: "one two"),
            ManifestRow(index: 2, audioURL: second, reference: "one two"),
        ]

        let engine = ScriptedLiveEngine(
            cues: [.final("one two", at: 1, end: 1)], failSessionAfter: 1)
        let outcome = try await LiveEvaluator.run(
            engine: engine, catalogID: "fake.live", rows: rows, language: "en-US",
            pace: 40, sink: Self.sink())

        #expect(outcome.summary.rows == 1)
        #expect(outcome.skipped.count == 1)
        #expect(outcome.skipped.first?.index == 2)
    }

    @Test("the report carries a Live section and the batch RTFx line does not lie")
    func reportHasLiveSection() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }
        let rows = try Self.manifest(in: directory, seconds: 2, reference: "one two")
        let reportDirectory = directory.appendingPathComponent("report", isDirectory: true)

        let engine = ScriptedLiveEngine(cues: [
            .partial("one", at: 0.5),
            .final("one two", at: 1, end: 1),
        ])
        _ = try await LiveEvaluator.run(
            engine: engine, catalogID: "fake.live", rows: rows, language: "en-US",
            pace: 40, sink: Self.sink(), reportDirectory: reportDirectory)

        let markdown = try String(
            contentsOf: reportDirectory.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(markdown.contains("## Live"))
        #expect(markdown.contains("Time to first partial"))
        #expect(markdown.contains("Trailing reference words lost"))
        // RTFx is the pacing here, not the engine's speed, and printing it as a
        // number invites the one comparison it cannot support.
        #expect(!markdown.contains("| RTFx | 40"))
        #expect(markdown.contains("not applicable"))
        // The pace was not 1, so the report has to say the latencies are not
        // quotable.
        #expect(markdown.contains("not quotable"))

        let json = try String(
            contentsOf: reportDirectory.appendingPathComponent("summary.json"), encoding: .utf8)
        #expect(json.contains("\"trailing_words_lost\""))
        #expect(json.contains("\"median_first_partial_seconds\""))
    }

    @Test("a batch report still has no live keys in it")
    func batchReportUnchanged() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }
        let rows = try Self.manifest(in: directory, seconds: 2, reference: "one two")
        let reportDirectory = directory.appendingPathComponent("report", isDirectory: true)

        _ = try await Evaluator.run(
            engine: ScriptedLiveEngine(cues: [], batchText: "one two"),
            catalogID: "fake.live", rows: rows, language: "en-US",
            sink: Self.sink(), reportDirectory: reportDirectory)

        let json = try String(
            contentsOf: reportDirectory.appendingPathComponent("summary.json"), encoding: .utf8)
        // Optionals encode through `encodeIfPresent`, so a batch run's report
        // is byte for byte what it was before live mode existed. Anything else
        // would break every summary.json already sitting in Private/.
        #expect(!json.contains("\"live\""))
        let markdown = try String(
            contentsOf: reportDirectory.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(!markdown.contains("## Live"))
        #expect(markdown.contains("| RTFx |"))
    }

    @Test("the median of a measurement set is one of its measurements")
    func medianIsAMeasurement() {
        #expect(LiveEvaluator.median([]) == nil)
        #expect(LiveEvaluator.median([3]) == 3)
        #expect(LiveEvaluator.median([3, 1, 2]) == 2)
        // Even count: the lower middle, not the mean of the two, so the answer
        // is a number that was actually observed.
        #expect(LiveEvaluator.median([4, 1, 2, 3]) == 2)
    }
}

// MARK: - Doubles

/// A live session that publishes text on a clock made of the audio it has been
/// fed, so a cue at 1.5 s fires after 1.5 s of samples have arrived however
/// fast the harness played them.
actor ScriptedLiveSession: LiveSession {
    struct Cue: Sendable {
        var atSeconds: Double
        var text: String
        var isFinal: Bool
        var end: Double

        static func partial(_ text: String, at seconds: Double) -> Cue {
            Cue(atSeconds: seconds, text: text, isFinal: false, end: seconds)
        }

        static func final(_ text: String, at seconds: Double, end: Double) -> Cue {
            Cue(atSeconds: seconds, text: text, isFinal: true, end: end)
        }
    }

    nonisolated let events: AsyncStream<LiveEvent>
    private let continuation: AsyncStream<LiveEvent>.Continuation
    private var cues: [Cue]
    private let tail: [String]
    private let feedDelay: Duration
    private var fedSeconds: Double = 0
    private var finals: [Segment] = []
    private var nextID = 0
    private var finished = false

    init(cues: [Cue], tail: [String], feedDelay: Duration) {
        self.cues = cues
        self.tail = tail
        self.feedDelay = feedDelay
        let (events, continuation) = AsyncStream<LiveEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func feed(_ audio: CapturedAudio) async throws {
        if feedDelay > .zero { try await Task.sleep(for: feedDelay) }
        let buffer = audio.buffer
        guard buffer.format.sampleRate > 0 else { return }
        fedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        while let next = cues.first, next.atSeconds <= fedSeconds {
            cues.removeFirst()
            publish(next.text, end: next.end, isFinal: next.isFinal)
        }
    }

    func finish() async throws -> [Segment] {
        guard !finished else { return finals }
        finished = true
        // Published, then the stream is closed in the same call - the shape a
        // real session's flush has, and the one that makes the harness's join
        // rule observable.
        for text in tail { publish(text, end: fedSeconds, isFinal: true) }
        continuation.finish()
        return finals
    }

    func cancel() async {
        finished = true
        continuation.finish()
    }

    private func publish(_ text: String, end: Double, isFinal: Bool) {
        let segment = Segment(id: nextID, start: 0, end: end, text: text)
        if isFinal {
            finals.append(segment)
            nextID += 1
            continuation.yield(.final(segment))
        } else {
            continuation.yield(.partial(segment))
        }
    }
}

/// The engine around it. Also answers `transcribe`, so one double covers the
/// "a batch report is unchanged" test as well.
final class ScriptedLiveEngine: TranscriptionEngine, @unchecked Sendable {
    nonisolated let id = "fake.live"
    nonisolated let capabilities = EngineCapabilities(
        batch: true, live: true, languages: ["en"])

    private let cues: [ScriptedLiveSession.Cue]
    private let tail: [String]
    private let feedDelay: Duration
    private let batchText: String
    /// Sessions after this many succeed at being made and then throw, which is
    /// how a live row fails in practice: not at startup, but part way through.
    private let failSessionAfter: Int?
    private let lock = NSLock()
    private var sessions = 0

    init(
        cues: [ScriptedLiveSession.Cue],
        tail: [String] = [],
        feedDelay: Duration = .zero,
        batchText: String = "",
        failSessionAfter: Int? = nil
    ) {
        self.cues = cues
        self.tail = tail
        self.feedDelay = feedDelay
        self.batchText = batchText
        self.failSessionAfter = failSessionAfter
    }

    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        nil
    }

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        guard !batchText.isEmpty else { return [] }
        return [Segment(id: 0, start: 0, end: 1, text: batchText)]
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        let index = lock.withLock { sessions += 1; return sessions }
        if let failSessionAfter, index > failSessionAfter {
            throw SpeechError.runtime("this session was scripted to fail")
        }
        return ScriptedLiveSession(cues: cues, tail: tail, feedDelay: feedDelay)
    }

    func unload() async {}
}
