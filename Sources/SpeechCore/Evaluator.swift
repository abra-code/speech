// Evaluator.swift - `speech eval`. The instrument the whole catalog is built
// with, so it is written to be boring and repeatable rather than clever.
//
// Three properties it must have, in order of importance:
//
//  1. Every engine sees the same audio and the same rows in the same order.
//     Rows are never shuffled and `--limit n` takes the first n, so a 200-row
//     run of one engine is comparable to a 200-row run of another.
//  2. A bad row does not lose the run. A corpus of 758 files will contain one
//     that will not decode; that becomes a warning and a skip, not an abort
//     forty minutes in.
//  3. Corpus WER is total edits over total reference tokens, never the mean of
//     per-row rates. See ScoreCounts.combine.
//
// Memory is reported twice, and the two numbers are not interchangeable.
// `peak_rss_bytes` is the process peak, kept because published figures for
// other tools are RSS - but it is not reproducible here. A CoreML model's
// weights are mapped for the Neural Engine, and whether those pages are counted
// in *our* address space is the system's decision: three identical runs of
// `fluid.parakeet-unified@fp16` measured 1.25 GB, 76 MB and 76 MB.
// `peak_memory_bytes` is peak footprint plus the Neural Engine's mapping,
// which over those same three runs stayed within 0.4% - 1291, 1286, 1286 MB.
// (The Neural Engine half alone was identical to the byte; the footprint is
// what moves the last few megabytes.) Rank engines by that one. The baseline taken before prepare() and the resulting deltas go
// into the written report, where the question "what did the model cost" is
// actually being asked.

import Foundation

public struct EvalOutcome: Sendable {
    public var summary: SpeechEvent.EvalSummary
    public var rows: [SpeechEvent.EvalRow]
    public var skipped: [(index: Int, path: String, reason: String)]
    public var baselineRSSBytes: Int64
    public var baselineMemoryBytes: Int64
    /// The full memory breakdown at the end of the run, or nil on a kernel that
    /// does not carry the ledgers. Nil means the report says so rather than
    /// printing a footprint that omits half a gigabyte of model.
    public var memory: SystemInfo.MemorySnapshot?
    public var loadSeconds: Double
    /// The locale identifiers the engine actually used, comma separated. A run
    /// that asked for "es-419" and measured es_ES has to say so, or its numbers
    /// cannot be reproduced.
    public var resolvedLocales: String?
}

public enum Evaluator {
    /// Load the engine for every language the run will ask for, before the
    /// clock starts on any row, and announce it.
    ///
    /// Shared with `LiveEvaluator`, which has to do exactly the same thing for
    /// the same reasons. A first run on an uninstalled locale downloads
    /// assets, and letting that land inside a row would put a multi-minute
    /// download into one utterance's wall time and corrupt RTFx for the whole
    /// run.
    ///
    /// Preparing only the run-level --language is not enough: manifest rows
    /// carry their own language column, which is the entire point of a
    /// mixed-language corpus, and the row's language would then download
    /// inside row 1. Preparing them in row order also turns a language the
    /// engine cannot do into an immediate error rather than a row skipped
    /// forty minutes in, which for a measuring run is the better failure.
    static func prepare(
        engine: any TranscriptionEngine,
        catalogID: String,
        rows: [ManifestRow],
        language: String?,
        sink: EventSink
    ) async throws -> (loadSeconds: Double, resolvedLocales: [String]) {
        var languagesToPrepare: [String?] = []
        for row in rows {
            let rowLanguage = row.language ?? language
            if !languagesToPrepare.contains(rowLanguage) {
                languagesToPrepare.append(rowLanguage)
            }
        }
        if languagesToPrepare.isEmpty { languagesToPrepare = [language] }

        let loadStart = ContinuousClock().now
        var resolvedLocales: [String] = []
        for candidate in languagesToPrepare {
            // `transcribe` warns about a language the engine does not claim;
            // this is the same warning for the measuring path, which did not
            // have one. A measurement tool silently scoring an English-only
            // model against a Polish reference reports a WER that looks like a
            // result and is not - which is worse here than in `transcribe`,
            // because the number gets written into a report.
            if !engine.capabilities.supports(language: candidate) {
                sink.warning(
                    "\(catalogID) does not list '\(candidate ?? "")' among its languages"
                    + " (\(engine.capabilities.languages.joined(separator: " ")));"
                    + " the scores for those rows will not mean anything",
                    code: "language_unsupported")
            }
            let resolved = try await engine.prepare(language: candidate) { progress in
                sink.modelProgress(model: catalogID, progress)
            }
            if let resolved, !resolvedLocales.contains(resolved) {
                resolvedLocales.append(resolved)
            }
        }
        let loadSeconds = seconds(since: loadStart)
        sink.emit(.engineReady(.init(
            engine: engine.id, model: catalogID,
            capabilities: engine.capabilities, loadSeconds: loadSeconds,
            locale: resolvedLocales.isEmpty ? nil : resolvedLocales.joined(separator: ","))))
        return (loadSeconds, resolvedLocales)
    }

    public static func run(
        engine: any TranscriptionEngine,
        catalogID: String,
        rows: [ManifestRow],
        language: String?,
        sink: EventSink,
        reportDirectory: URL? = nil
    ) async throws -> EvalOutcome {
        let baselineRSS = SystemInfo.peakResidentBytes()
        let baselineMemory = SystemInfo.peakMemoryBytes()

        // Same pre-flight the transcribe path does, and it matters more here:
        // a measuring run that discovers a missing dependency on row 200 has
        // wasted far more than one file.
        try await engine.validate(TranscribeOptions(language: language, wantWordTimestamps: false))

        let prepared = try await prepare(
            engine: engine, catalogID: catalogID, rows: rows, language: language, sink: sink)
        let loadSeconds = prepared.loadSeconds
        let resolvedLocales = prepared.resolvedLocales

        var wordCounts: [ScoreCounts] = []
        var characterCounts: [ScoreCounts] = []
        var emitted: [SpeechEvent.EvalRow] = []
        var skipped: [(index: Int, path: String, reason: String)] = []
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
            let options = TranscribeOptions(language: rowLanguage, wantWordTimestamps: false)
            let start = ContinuousClock().now
            let segments: [Segment]
            do {
                segments = try await engine.transcribe(samples: samples, options: options)
            } catch {
                let reason = (error as? SpeechError)?.message ?? error.localizedDescription
                skipped.append((row.index, row.audioURL.path, reason))
                sink.warning("row \(row.index): \(reason)", code: "row_skipped")
                continue
            }
            let wallSeconds = seconds(since: start)

            let hypothesis = segments
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let score = Scorer.score(
                reference: row.reference, hypothesis: hypothesis, language: rowLanguage)

            if score.word.referenceCount == 0 {
                sink.warning(
                    "row \(row.index): reference normalizes to nothing; it contributes no denominator",
                    code: "empty_reference")
            }

            wordCounts.append(score.word)
            characterCounts.append(score.character)
            totalAudio += audioSeconds
            totalWall += wallSeconds

            let event = SpeechEvent.EvalRow(
                index: row.index, path: row.audioURL.path,
                reference: row.reference, hypothesis: hypothesis,
                wer: score.wer, cer: score.cer,
                audioSeconds: audioSeconds, wallSeconds: wallSeconds)
            emitted.append(event)
            sink.emit(.evalRow(event))
        }

        let word = ScoreCounts.combine(wordCounts)
        let character = ScoreCounts.combine(characterCounts)
        // Worst first, and on a tie the earlier row first. Ties are common -
        // every row that came back empty scores exactly 1.0 - so the tie rule
        // decides most of what this list shows.
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

        // One read, because the report prints the two halves and their sum.
        // Two reads could straddle a page fault and print a breakdown that
        // does not add up, which in a measurement document reads as a bug in
        // the measurement.
        let memory = SystemInfo.memorySnapshot()
        // An engine whose model runs in another process adds that process's
        // peak, because both are resident at once and the figure answers what
        // the run needed. nil for every engine but `mlx`, so this changes no
        // number that has already been recorded.
        let helperMemory = await engine.peakOutOfProcessMemoryBytes() ?? 0
        let summary = SpeechEvent.EvalSummary(
            model: catalogID, language: language, rows: emitted.count,
            wer: word.rate, cer: character.rate,
            audioSeconds: totalAudio, wallSeconds: totalWall,
            peakRSSBytes: memory?.residentPeak ?? SystemInfo.peakResidentBytes(),
            peakMemoryBytes: (memory?.peak ?? SystemInfo.peakResidentBytes()) + helperMemory,
            worst: Array(worst))
        sink.emit(.evalSummary(summary))

        let outcome = EvalOutcome(
            summary: summary, rows: emitted, skipped: skipped,
            baselineRSSBytes: baselineRSS, baselineMemoryBytes: baselineMemory,
            memory: memory, loadSeconds: loadSeconds,
            resolvedLocales: resolvedLocales.isEmpty ? nil : resolvedLocales.joined(separator: ","))

        if let reportDirectory {
            try writeReport(outcome, counts: (word, character), to: reportDirectory)
        }
        return outcome
    }

    // MARK: - Report

    private struct ReportDocument: Codable {
        var model: String
        var engine: String
        var language: String?
        var resolvedLocales: String?
        var date: String
        var machine: String
        var os: String
        var physicalMemoryBytes: Int64
        var rows: Int
        var skipped: Int
        var wer: Double
        var cer: Double
        var substitutions: Int
        var deletions: Int
        var insertions: Int
        var referenceWords: Int
        var characterErrors: Int
        var referenceCharacters: Int
        var audioSeconds: Double
        var wallSeconds: Double
        var rtfx: Double
        var loadSeconds: Double
        var peakRSSBytes: Int64
        var peakRSSBaselineBytes: Int64
        var peakRSSDeltaBytes: Int64
        /// Peak footprint plus the Neural Engine mapping - the reproducible
        /// number, and the one a RAM estimate should be built from.
        var peakMemoryBytes: Int64
        var peakMemoryBaselineBytes: Int64
        var peakMemoryDeltaBytes: Int64
        /// The two halves of `peakMemoryBytes`, absent together on a kernel
        /// that does not report the ledgers.
        var peakFootprintBytes: Int64?
        var peakNeuralBytes: Int64?
        /// Present only for `eval --live`. Its absence is how a reader tells a
        /// batch report from a live one at a glance.
        var live: SpeechEvent.LiveSummary?

        private enum CodingKeys: String, CodingKey {
            case model, engine, language, date, machine, os, rows, skipped, wer, cer, live
            case resolvedLocales = "resolved_locales"
            case substitutions, deletions, insertions, rtfx
            case physicalMemoryBytes = "physical_memory_bytes"
            case referenceWords = "reference_words"
            case characterErrors = "character_errors"
            case referenceCharacters = "reference_characters"
            case audioSeconds = "audio_seconds"
            case wallSeconds = "wall_seconds"
            case loadSeconds = "load_seconds"
            case peakRSSBytes = "peak_rss_bytes"
            case peakRSSBaselineBytes = "peak_rss_baseline_bytes"
            case peakRSSDeltaBytes = "peak_rss_delta_bytes"
            case peakMemoryBytes = "peak_memory_bytes"
            case peakMemoryBaselineBytes = "peak_memory_baseline_bytes"
            case peakMemoryDeltaBytes = "peak_memory_delta_bytes"
            case peakFootprintBytes = "peak_footprint_bytes"
            case peakNeuralBytes = "peak_neural_bytes"
        }
    }

    static func writeReport(
        _ outcome: EvalOutcome,
        counts: (word: ScoreCounts, character: ScoreCounts),
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let summary = outcome.summary
        let formatter = ISO8601DateFormatter()
        let document = ReportDocument(
            model: summary.model,
            engine: String(summary.model.split(separator: ".").first ?? ""),
            language: summary.language,
            resolvedLocales: outcome.resolvedLocales,
            date: formatter.string(from: Date()),
            machine: SystemInfo.chip,
            os: SystemInfo.operatingSystemVersion,
            physicalMemoryBytes: SystemInfo.physicalMemoryBytes,
            rows: summary.rows,
            skipped: outcome.skipped.count,
            wer: summary.wer,
            cer: summary.cer,
            substitutions: counts.word.substitutions,
            deletions: counts.word.deletions,
            insertions: counts.word.insertions,
            referenceWords: counts.word.referenceCount,
            characterErrors: counts.character.edits,
            referenceCharacters: counts.character.referenceCount,
            audioSeconds: summary.audioSeconds,
            wallSeconds: summary.wallSeconds,
            rtfx: summary.rtfx,
            loadSeconds: outcome.loadSeconds,
            peakRSSBytes: summary.peakRSSBytes,
            peakRSSBaselineBytes: outcome.baselineRSSBytes,
            peakRSSDeltaBytes: max(0, summary.peakRSSBytes - outcome.baselineRSSBytes),
            peakMemoryBytes: summary.peakMemoryBytes,
            peakMemoryBaselineBytes: outcome.baselineMemoryBytes,
            peakMemoryDeltaBytes: max(0, summary.peakMemoryBytes - outcome.baselineMemoryBytes),
            peakFootprintBytes: outcome.memory?.footprintPeak,
            peakNeuralBytes: outcome.memory?.neuralPeak,
            live: summary.live)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try encoder.encode(document)
            .write(to: directory.appendingPathComponent("summary.json"), options: .atomic)

        var markdown = "# \(summary.model) - \(summary.language ?? "unspecified language")\n\n"
        markdown += "Measured \(document.date) on \(document.machine), macOS \(document.os),"
        markdown += " \(SystemInfo.formatBytes(document.physicalMemoryBytes)) RAM.\n\n"
        markdown += "| Metric | Value |\n| --- | --- |\n"
        if let resolved = outcome.resolvedLocales {
            markdown += row("Locale actually used", resolved)
        }
        markdown += row("Rows scored", "\(summary.rows)")
        markdown += row("Rows skipped", "\(outcome.skipped.count)")
        markdown += row("WER", percent(summary.wer))
        markdown += row("CER", percent(summary.cer))
        markdown += row("Substitutions / deletions / insertions",
                        "\(counts.word.substitutions) / \(counts.word.deletions) / \(counts.word.insertions)")
        markdown += row("Reference words", "\(counts.word.referenceCount)")
        markdown += row("Audio", String(format: "%.1f s", summary.audioSeconds))
        markdown += row("Wall time", String(format: "%.1f s", summary.wallSeconds))
        if summary.live == nil {
            markdown += row("RTFx", String(format: "%.1fx", summary.rtfx))
        } else {
            // RTFx under live pacing measures the harness, not the engine: the
            // audio was played at a fixed speed, so the ratio is that speed
            // plus whatever `finish()` added. Printing it next to a batch
            // report's RTFx would invite exactly the comparison it cannot
            // support.
            markdown += row("RTFx", "not applicable - the audio was paced, see Live below")
        }
        markdown += row("Load time", String(format: "%.2f s", outcome.loadSeconds))
        markdown += row("Peak memory", SystemInfo.formatBytes(summary.peakMemoryBytes))
        if let footprint = document.peakFootprintBytes, let neural = document.peakNeuralBytes {
            markdown += row("  of which process footprint", SystemInfo.formatBytes(footprint))
            markdown += row("  of which Neural Engine", SystemInfo.formatBytes(neural))
        } else {
            // Without the ledgers "peak memory" is the resident peak wearing a
            // better name, and a reader comparing this report against another
            // has to be told which one they are holding.
            markdown += row("  measured how", "resident peak - this kernel reports no ledgers")
        }
        markdown += row("Peak memory above baseline",
                        SystemInfo.formatBytes(document.peakMemoryDeltaBytes))
        markdown += row("Peak RSS (not reproducible, see docs/protocol.md)",
                        SystemInfo.formatBytes(summary.peakRSSBytes))

        if let live = summary.live {
            markdown += "\n## Live\n\n"
            markdown += "Audio was played to a live session at "
            markdown += String(format: "%.2fx", live.pace)
            markdown += " real time through the same pump, session and bounded"
            markdown += " capture queue `speech stream` uses.\n\n"
            if live.pace != 1 {
                markdown += "**These latencies are not quotable.** They were taken at "
                markdown += String(format: "%.2fx", live.pace)
                markdown += " rather than 1x, which changes both what the engine has time"
                markdown += " to do and what gets dropped.\n\n"
            }
            markdown += "| Metric | Median | Worst |\n| --- | --- | --- |\n"
            markdown += liveRow(
                "Time to first partial", live.medianFirstPartialSeconds,
                live.worstFirstPartialSeconds)
            markdown += liveRow(
                "Final behind the audio", live.medianFinalLagSeconds, live.worstFinalLagSeconds)
            markdown += liveRow(
                "Wait after the audio ended", live.medianFinishSeconds, live.worstFinishSeconds)
            markdown += "\n| Count | Value |\n| --- | --- |\n"
            markdown += row("Trailing reference words lost", "\(live.trailingWordsLost)")
            markdown += row("Rows that stopped short of the end", "\(live.rowsEndingEarly)")
            markdown += row("Rows that produced no text at all", "\(live.rowsWithNoText)")
            markdown += row("Rows with no partial before the final", "\(live.rowsWithoutPartials)")
            markdown += row("Capture buffers dropped", "\(live.droppedBuffers)")
            markdown += row("Rows affected by a drop", "\(live.rowsWithDrops)")
            if live.droppedBuffers > 0 {
                markdown += "\nBuffers were dropped, so the WER above is partly a"
                markdown += " measurement of this machine rather than of the model. A row that"
                markdown += " loses audio loses the words in it.\n"
            }
        }

        if !summary.worst.isEmpty {
            markdown += "\n## Ten worst utterances\n\n"
            markdown += "| Row | WER | Reference | Hypothesis |\n| --- | --- | --- | --- |\n"
            for worst in summary.worst {
                markdown += "| \(worst.index) | \(percent(worst.wer)) |"
                markdown += " \(escapeCell(worst.reference)) | \(escapeCell(worst.hypothesis)) |\n"
            }
        }

        if !outcome.skipped.isEmpty {
            markdown += "\n## Skipped rows\n\n"
            for entry in outcome.skipped {
                markdown += "- row \(entry.index): \((entry.path as NSString).lastPathComponent)"
                markdown += " - \(entry.reason)\n"
            }
        }

        try Data(markdown.utf8)
            .write(to: directory.appendingPathComponent("report.md"), options: .atomic)
    }

    private static func row(_ name: String, _ value: String) -> String {
        "| \(name) | \(value) |\n"
    }

    /// A median/worst pair, with "none" rather than a zero when the engine
    /// never produced the thing being timed. Zero would read as instant.
    private static func liveRow(_ name: String, _ median: Double?, _ worst: Double?) -> String {
        func format(_ value: Double?) -> String {
            guard let value else { return "none" }
            return String(format: "%.2f s", value)
        }
        return "| \(name) | \(format(median)) | \(format(worst)) |\n"
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }

    /// Markdown table cells cannot hold a pipe or a newline. References are
    /// arbitrary text from a corpus, so both happen.
    private static func escapeCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        Double((ContinuousClock().now - start) / .milliseconds(1)) / 1000.0
    }
}
