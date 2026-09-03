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
// Peak RSS is reported as the process peak (`peak_rss_bytes`, the same meaning
// it has in a `done` event) so it can be compared against published figures for
// other tools. The baseline taken before prepare() and the resulting delta go
// into the written report, where the question "what did the model cost" is
// actually being asked.

import Foundation

public struct EvalOutcome: Sendable {
    public var summary: SpeechEvent.EvalSummary
    public var rows: [SpeechEvent.EvalRow]
    public var skipped: [(index: Int, path: String, reason: String)]
    public var baselineRSSBytes: Int64
    public var loadSeconds: Double
    /// The locale identifiers the engine actually used, comma separated. A run
    /// that asked for "de" and measured de_AT has to say so, or its numbers
    /// cannot be reproduced.
    public var resolvedLocales: String?
}

public enum Evaluator {
    public static func run(
        engine: any TranscriptionEngine,
        catalogID: String,
        rows: [ManifestRow],
        language: String?,
        sink: EventSink,
        reportDirectory: URL? = nil
    ) async throws -> EvalOutcome {
        let baselineRSS = SystemInfo.peakResidentBytes()

        // Prepare for every language this run will ask for, before the clock
        // starts on any row. A first run on an uninstalled locale downloads
        // assets, and letting that land inside a row would put a multi-minute
        // download into one utterance's wall time and corrupt RTFx for the
        // whole run.
        //
        // Preparing only the run-level --language is not enough: manifest rows
        // carry their own language column, which is the entire point of a
        // mixed-language corpus, and the row's language would then download
        // inside row 1. Preparing them in row order also turns a language the
        // engine cannot do into an immediate error rather than a row skipped
        // forty minutes in, which for a measuring run is the better failure.
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

        let summary = SpeechEvent.EvalSummary(
            model: catalogID, language: language, rows: emitted.count,
            wer: word.rate, cer: character.rate,
            audioSeconds: totalAudio, wallSeconds: totalWall,
            peakRSSBytes: SystemInfo.peakResidentBytes(), worst: Array(worst))
        sink.emit(.evalSummary(summary))

        let outcome = EvalOutcome(
            summary: summary, rows: emitted, skipped: skipped,
            baselineRSSBytes: baselineRSS, loadSeconds: loadSeconds,
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

        private enum CodingKeys: String, CodingKey {
            case model, engine, language, date, machine, os, rows, skipped, wer, cer
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
        }
    }

    private static func writeReport(
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
            peakRSSDeltaBytes: max(0, summary.peakRSSBytes - outcome.baselineRSSBytes))

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
        markdown += row("RTFx", String(format: "%.1fx", summary.rtfx))
        markdown += row("Load time", String(format: "%.2f s", outcome.loadSeconds))
        markdown += row("Peak RSS", SystemInfo.formatBytes(summary.peakRSSBytes))
        markdown += row("Peak RSS above baseline",
                        SystemInfo.formatBytes(document.peakRSSDeltaBytes))

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

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }

    /// Markdown table cells cannot hold a pipe or a newline. References are
    /// arbitrary text from a corpus, so both happen.
    private static func escapeCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        Double((ContinuousClock().now - start) / .milliseconds(1)) / 1000.0
    }
}
