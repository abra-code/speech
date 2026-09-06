// LiveEvaluator.swift - `speech eval --live`. The instrument for live mode,
// and the reason it exists is worth stating plainly: until this, every claim
// about a live row was a person talking into a laptop and reading the output.
// That found real defects, but it cannot answer "is this stable", "how far
// behind is it" or "did it keep the end of the sentence", and those are the
// only questions live mode is actually judged on.
//
// The design rule is fidelity to `speech stream`, not convenience. The audio
// goes through the same `LivePump`, into the same `LiveSession`, out of the
// same event stream, and through the same bounded queue that drops when the
// engine falls behind. Anything measured here is therefore a property of the
// path a user runs, including its failures - a row whose engine could not keep
// up loses audio in this harness exactly as it would lose it from a
// microphone, and the report says how much.
//
// What is simulated is the microphone and only the microphone: samples decoded
// from a file are handed over in small buffers on a real-time schedule. That
// substitution is what makes the measurement repeatable, and it is also the
// one thing that is not real. A file has no room noise, no AGC and no device
// resampling, so a WER from here is a floor, not a promise.
//
// Three numbers this produces that a batch eval cannot:
//
//   time to first partial   how long the screen stays empty after you speak
//   final lag               how far behind the speaker the committed text is
//   trailing words lost     words that were said and never came out at all
//
// The third is the one that catches the class of defect this project has now
// hit twice: a session that stops transcribing before the speaker stops. See
// `Scorer.trailingReferenceLoss`.

import AVFoundation
import Foundation

/// About four seconds of buffers. The same policy `speech stream` uses and for
/// the same reason: when the engine falls behind, the choice is to drop audio
/// or to grow without limit, and dropping is the one that can be reported.
private let kLiveQueueDepth = 64

/// 64 ms at 16 kHz. A hardware tap at 4096 frames and 48 kHz delivers about
/// 85 ms, so this is the same order without being tied to whatever device the
/// measuring machine happens to have. Smaller would exaggerate per-buffer
/// overhead; much larger would hide it.
private let kLiveChunkFrames = 1024

public enum LiveEvaluator {
    /// - Parameter pace: multiples of real time. 1.0 is the only value whose
    ///   latencies mean anything; anything else is for a smoke test and is
    ///   stamped into the report so the numbers cannot be quoted as if they
    ///   were taken honestly.
    /// - Parameter vad: the detector to segment with, or nil to leave each row
    ///   to its own boundary rule. One detector for the whole run rather than
    ///   one per row: the model is stateless between streams, so it is reset
    ///   before each row and the 1.1 MB is loaded once.
    public static func run(
        engine: any TranscriptionEngine,
        catalogID: String,
        rows: [ManifestRow],
        language: String?,
        pace: Double = 1,
        vad: (any VoiceActivityDetector)? = nil,
        sink: EventSink,
        reportDirectory: URL? = nil
    ) async throws -> EvalOutcome {
        guard pace > 0 else {
            throw SpeechError.usage("--pace wants a positive multiple of real time")
        }
        let baselineRSS = SystemInfo.peakResidentBytes()
        let baselineMemory = SystemInfo.peakMemoryBytes()

        // Word timings are requested, matching `speech stream` rather than
        // `speech eval`. They contribute nothing to WER, but building them is
        // work the live path really does, and latency measured with that work
        // removed would be a latency nobody experiences.
        let segmentation: LiveSegmentation = vad == nil ? .engine : .vad
        let probe = TranscribeOptions(
            language: language, wantWordTimestamps: true, segmentation: segmentation)
        try await engine.validate(probe)

        let prepared = try await Evaluator.prepare(
            engine: engine, catalogID: catalogID, rows: rows,
            language: language, sink: sink)

        // One warning for the run, not one per row.
        var warnedAboutSegmentation = false
        var wordCounts: [ScoreCounts] = []
        var characterCounts: [ScoreCounts] = []
        var emitted: [SpeechEvent.EvalRow] = []
        var skipped: [(index: Int, path: String, reason: String)] = []
        var measurements: [SpeechEvent.LiveRow] = []
        var totalAudio = 0.0
        var totalWall = 0.0

        for row in rows {
            try Task.checkCancellation()
            let rowLanguage = row.language ?? language
            let samples: [Float]
            do {
                samples = try await AudioDecoder.decode(url: row.audioURL)
            } catch {
                let reason = (error as? SpeechError)?.message ?? error.localizedDescription
                skipped.append((row.index, row.audioURL.path, reason))
                sink.warning("row \(row.index): \(reason)", code: "row_skipped")
                continue
            }
            guard !samples.isEmpty else {
                skipped.append((row.index, row.audioURL.path, "decoded to zero samples"))
                sink.warning("row \(row.index): decoded to zero samples", code: "row_skipped")
                continue
            }

            let audioSeconds = Double(samples.count) / AudioDecoder.sampleRate
            let options = TranscribeOptions(
                language: rowLanguage, wantWordTimestamps: true, segmentation: segmentation)
            let measurement: Measurement
            do {
                // Each row is its own stream, so the detector starts over with
                // it. Without this the second row's boundaries would carry the
                // first row's clock and land in a segment nobody played.
                await vad?.reset()
                measurement = try await measure(
                    engine: engine, options: options, samples: samples, pace: pace, vad: vad)
                if vad != nil, !measurement.honorsBoundaries, !warnedAboutSegmentation {
                    warnedAboutSegmentation = true
                    sink.warning(
                        "\(catalogID) decides its own utterance boundaries;"
                        + " --segment vad has no effect on it",
                        code: "segment_ignored")
                }
            } catch {
                // Same rule as the batch evaluator: one bad row is a warning,
                // not the end of a run that may be forty minutes in. A live row
                // has more ways to fail than a batch one - the session can
                // refuse to start, the feed can throw, `finish` can fail with a
                // partial transcript - and none of them is worth scoring,
                // because the resulting WER would describe the failure rather
                // than the model.
                let reason = (error as? SpeechError)?.message
                    ?? (error as? LiveSessionFailure)?.message
                    ?? error.localizedDescription
                skipped.append((row.index, row.audioURL.path, reason))
                sink.warning("row \(row.index): \(reason)", code: "row_skipped")
                continue
            }

            let score = Scorer.score(
                reference: row.reference, hypothesis: measurement.hypothesis,
                language: rowLanguage)
            if score.word.referenceCount == 0 {
                sink.warning(
                    "row \(row.index): reference normalizes to nothing;"
                    + " it contributes no denominator",
                    code: "empty_reference")
            }
            let live = SpeechEvent.LiveRow(
                firstPartialSeconds: measurement.firstPartialSeconds,
                firstFinalSeconds: measurement.firstFinalSeconds,
                finishSeconds: measurement.finishSeconds,
                maxFinalLagSeconds: measurement.maxFinalLagSeconds,
                trailingWordsLost: Scorer.trailingReferenceLoss(
                    reference: row.reference, hypothesis: measurement.hypothesis,
                    language: rowLanguage),
                droppedBuffers: measurement.droppedBuffers,
                partials: measurement.partials,
                finals: measurement.finals)

            if live.droppedBuffers > 0 {
                // Loud, per row, and not only in the summary. A WER measured
                // over audio that was thrown away is not this model's WER, and
                // whoever reads the scrollback rather than the report has to be
                // told which rows are affected.
                sink.warning(
                    "row \(row.index): \(live.droppedBuffers) buffer(s) were dropped because"
                    + " \(catalogID) could not keep up with real time;"
                    + " this row's score is partly a measure of this machine",
                    code: "live_overrun")
            }

            wordCounts.append(score.word)
            characterCounts.append(score.character)
            measurements.append(live)
            totalAudio += audioSeconds
            totalWall += measurement.wallSeconds

            let event = SpeechEvent.EvalRow(
                index: row.index, path: row.audioURL.path,
                reference: row.reference, hypothesis: measurement.hypothesis,
                wer: score.wer, cer: score.cer,
                audioSeconds: audioSeconds, wallSeconds: measurement.wallSeconds,
                live: live)
            emitted.append(event)
            sink.emit(.evalRow(event))
        }

        let word = ScoreCounts.combine(wordCounts)
        let character = ScoreCounts.combine(characterCounts)
        let worst = emitted
            .sorted { lhs, rhs in
                lhs.wer == rhs.wer ? lhs.index < rhs.index : lhs.wer > rhs.wer
            }
            .prefix(10)
            .map {
                SpeechEvent.WorstRow(
                    index: $0.index, wer: $0.wer,
                    reference: $0.reference, hypothesis: $0.hypothesis)
            }

        let memory = SystemInfo.memorySnapshot()
        let summary = SpeechEvent.EvalSummary(
            model: catalogID, language: language, rows: emitted.count,
            wer: word.rate, cer: character.rate,
            audioSeconds: totalAudio, wallSeconds: totalWall,
            peakRSSBytes: memory?.residentPeak ?? SystemInfo.peakResidentBytes(),
            peakMemoryBytes: memory?.peak ?? SystemInfo.peakResidentBytes(),
            worst: Array(worst),
            live: aggregate(measurements, rows: emitted, pace: pace))
        sink.emit(.evalSummary(summary))

        let outcome = EvalOutcome(
            summary: summary, rows: emitted, skipped: skipped,
            baselineRSSBytes: baselineRSS, baselineMemoryBytes: baselineMemory,
            memory: memory, loadSeconds: prepared.loadSeconds,
            resolvedLocales: prepared.resolvedLocales.isEmpty
                ? nil : prepared.resolvedLocales.joined(separator: ","))

        if let reportDirectory {
            try Evaluator.writeReport(outcome, counts: (word, character), to: reportDirectory)
        }
        return outcome
    }

    // MARK: - One utterance, played in real time

    private struct Measurement {
        var hypothesis: String
        var wallSeconds: Double
        var finishSeconds: Double
        var firstPartialSeconds: Double?
        var firstFinalSeconds: Double?
        var maxFinalLagSeconds: Double?
        var droppedBuffers: Int
        var partials: Int
        var finals: Int
        /// Whether this row's session took the boundaries it was handed. Read
        /// once per run rather than per row, to warn a caller who asked for
        /// `--segment vad` on a row that decides its own cuts.
        var honorsBoundaries: Bool
    }

    private static func measure(
        engine: any TranscriptionEngine,
        options: TranscribeOptions,
        samples: [Float],
        pace: Double,
        vad: (any VoiceActivityDetector)?
    ) async throws -> Measurement {
        let format = LiveAudioFormat.canonical
        let rate = format.sampleRate
        let session = try await engine.makeLiveSession(options: options)

        let pump: LivePump
        do {
            // No refinement buffer: `--refine` is a second engine's cost and
            // belongs to its own measurement, not inside this one's latency.
            // The detector is not in that category - it changes where this run's
            // own segments are cut, so its cost belongs inside the latencies.
            pump = try LivePump(session: session, inputFormat: format, audio: nil, vad: vad)
        } catch {
            await session.cancel()
            throw error
        }

        let (captured, continuation) = AsyncStream<CapturedAudio>.makeStream(
            bufferingPolicy: .bufferingNewest(kLiveQueueDepth))
        let collector = LiveRowCollector()

        let rowStart = ContinuousClock().now
        let watching = Task {
            for await event in session.events {
                await collector.record(event, at: seconds(since: rowStart), pace: pace)
            }
        }
        let pumping = Task { try await pump.run(captured) }

        var dropped = 0
        var index = 0
        var producerError: Error?
        while index < samples.count {
            let end = min(index + kLiveChunkFrames, samples.count)
            // The deadline is the END of the chunk. A tap hands a buffer over
            // after recording it, not before, and dating delivery at the start
            // would credit every engine with one free buffer of head start.
            let deadline = rowStart.advanced(by: .seconds(Double(end) / rate / pace))
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                producerError = error
                break
            }
            guard let buffer = makeBuffer(samples[index..<end], format: format) else {
                producerError = SpeechError.runtime("could not allocate a capture buffer")
                break
            }
            if case .dropped = continuation.yield(CapturedAudio(buffer)) { dropped += 1 }
            index = end
        }
        continuation.finish()

        // The pump is joined before `finish()`, so the session has actually
        // been given every buffer it is going to get before it is asked for its
        // transcript. Finishing a session that still has audio queued behind it
        // would measure a shorter tail than a real run has.
        var pumpError: Error?
        do {
            try await pumping.value
        } catch is CancellationError {
            pumpError = CancellationError()
        } catch {
            pumpError = error
        }
        if let error = producerError ?? pumpError {
            watching.cancel()
            _ = await watching.value
            await session.cancel()
            throw error
        }

        let finishStart = ContinuousClock().now
        let segments: [Segment]
        do {
            segments = try await session.finish()
        } catch {
            watching.cancel()
            _ = await watching.value
            throw error
        }
        let finishSeconds = seconds(since: finishStart)
        let wallSeconds = seconds(since: rowStart)

        // Canceled, then joined, and that order is safe rather than lossy:
        // canceling a task that is iterating an `AsyncStream` does not discard
        // what is still buffered in it. `next()` consults cancellation only
        // when it would otherwise suspend, so a reader that is behind still
        // drains the flush before its loop ends. That was measured rather than
        // assumed, because the opposite would silently drop the last finals of
        // every utterance - exactly the events the trailing-loss number is
        // about - and a first version of this waited on a flag instead, which
        // bought nothing and gave a session that never closed its continuation
        // a way to stall the run one row at a time.
        watching.cancel()
        _ = await watching.value
        let collected = await collector.snapshot()
        let droppedInputs = await session.droppedInputCount()

        let hypothesis = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return Measurement(
            hypothesis: hypothesis,
            wallSeconds: wallSeconds,
            finishSeconds: finishSeconds,
            firstPartialSeconds: collected.firstPartial,
            firstFinalSeconds: collected.firstFinal,
            maxFinalLagSeconds: collected.maxLag,
            droppedBuffers: dropped + droppedInputs,
            partials: collected.partials,
            finals: collected.finals,
            honorsBoundaries: session.honorsSpeechBoundaries)
    }

    private static func makeBuffer(
        _ samples: ArraySlice<Float>, format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let count = samples.count
        guard count > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source in
            channel[0].update(from: source.baseAddress!, count: count)
        }
        return buffer
    }

    // MARK: - Aggregation

    private static func aggregate(
        _ rows: [SpeechEvent.LiveRow], rows emitted: [SpeechEvent.EvalRow], pace: Double
    ) -> SpeechEvent.LiveSummary {
        let firstPartials = rows.compactMap(\.firstPartialSeconds)
        let lags = rows.compactMap(\.maxFinalLagSeconds)
        let finishes = rows.map(\.finishSeconds)
        let empty = emitted.filter {
            $0.hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let endedEarly = zip(rows, emitted).filter { live, row in
            live.trailingWordsLost > 0
                && !row.hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count

        return SpeechEvent.LiveSummary(
            pace: pace,
            medianFirstPartialSeconds: median(firstPartials),
            worstFirstPartialSeconds: firstPartials.max(),
            medianFinishSeconds: median(finishes) ?? 0,
            worstFinishSeconds: finishes.max() ?? 0,
            medianFinalLagSeconds: median(lags),
            worstFinalLagSeconds: lags.max(),
            trailingWordsLost: rows.reduce(0) { $0 + $1.trailingWordsLost },
            rowsEndingEarly: endedEarly,
            rowsWithNoText: empty,
            rowsWithoutPartials: rows.filter { $0.partials == 0 }.count,
            droppedBuffers: rows.reduce(0) { $0 + $1.droppedBuffers },
            rowsWithDrops: rows.filter { $0.droppedBuffers > 0 }.count)
    }

    /// The lower of the two middle values on an even count, rather than their
    /// mean. Every number here is a measured latency, and the median of a set
    /// of measurements should be one of them.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        Double((ContinuousClock().now - start) / .milliseconds(1)) / 1000.0
    }
}

/// The per-row event tally.
///
/// An actor rather than a value the reader task returns, because the reader is
/// canceled on the paths where a session misbehaves, and a canceled task
/// still has to leave behind everything it had already counted. A return value
/// would take that with it.
actor LiveRowCollector {
    struct Snapshot: Sendable {
        var partials = 0
        var finals = 0
        var firstPartial: Double?
        var firstFinal: Double?
        var maxLag: Double?
    }

    private var state = Snapshot()

    func record(_ event: LiveEvent, at wallSeconds: Double, pace: Double) {
        switch event {
        case .partial:
            state.partials += 1
            if state.firstPartial == nil { state.firstPartial = wallSeconds }
        case .final(let segment):
            state.finals += 1
            if state.firstFinal == nil { state.firstFinal = wallSeconds }
            // How long after that audio was handed over this text arrived.
            // Dividing the segment's own end by the pace converts an audio
            // position into the wall clock the harness played it at, so the
            // number stays a latency at any speed even though only 1x is worth
            // quoting.
            let lag = wallSeconds - segment.end / pace
            state.maxLag = max(state.maxLag ?? lag, lag)
        }
    }

    func snapshot() -> Snapshot { state }
}
