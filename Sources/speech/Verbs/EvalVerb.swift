// EvalVerb.swift - `speech eval --model <id> --manifest <tsv>`.
//
// The command the catalog is built out of. Everything interesting happens in
// SpeechCore.Evaluator; this is argument handling and the --limit rule, which
// is load-bearing: it takes the FIRST n rows, never a random n, so that a
// 200-row run of one engine and a 200-row run of another are the same 200
// utterances.

import Foundation
import SpeechCore

func runEval(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    var model: String?
    var manifest: URL?
    var language: String?
    var limit: Int?
    var reportDirectory: URL?

    var scanner = ArgScanner(verb: "eval", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage("""
                Usage: \(kProgram) eval --model <catalog-id> --manifest <tsv> [options]

                Options:
                  --model <id>       Catalog id to measure (required)
                  --manifest <tsv>   audio_path<TAB>reference[<TAB>language], no header (required)
                  --language <tag>   Language for rows that do not name one
                  --limit <n>        Score the first n rows only
                  --report <dir>     Also write summary.json and report.md there

                Reports WER, CER, RTFx and peak memory. Corpus WER is total edits over
                total reference words, not the mean of the per-row rates.
                """)
            return
        case "--model", "-m":
            model = try scanner.value(token)
        case "--manifest":
            manifest = try scanner.pathValue(token)
        case "--language", "-l":
            language = try scanner.value(token)
        case "--limit":
            limit = try scanner.intValue(token)
        case "--report":
            reportDirectory = try scanner.pathValue(token)
        case "--":
            scanner.endOptions()
        default:
            try scanner.addPositional(token)
        }
    }
    guard scanner.positionals.isEmpty else {
        throw SpeechError.usage("unexpected argument '\(scanner.positionals[0])'")
    }
    guard let model else { throw SpeechError.usage("--model <catalog-id> is required") }
    guard let manifest else { throw SpeechError.usage("--manifest <tsv> is required") }
    if let limit, limit <= 0 {
        throw SpeechError.usage("--limit wants a positive count (got \(limit))")
    }

    var rows = try Manifest.load(manifest)
    if let limit, rows.count > limit {
        rows = Array(rows.prefix(limit))
    }

    let engine = try makeRegistry().make(catalogID: model, modelsDirectory: globals.modelsDirectory)
    guard engine.capabilities.batch else {
        throw SpeechError.usage("\(model) cannot transcribe files, so it cannot be scored this way")
    }

    // Unloaded on the failure path too - see the note in TranscribeVerb.
    let outcome: EvalOutcome
    do {
        outcome = try await Evaluator.run(
            engine: engine, catalogID: model, rows: rows, language: language,
            sink: sink, reportDirectory: reportDirectory)
    } catch {
        await engine.unload()
        throw error
    }
    await engine.unload()

    if let reportDirectory, !globals.json {
        sink.text("Report written to \(reportDirectory.path)")
    }
    if !outcome.skipped.isEmpty {
        sink.warning(
            "\(outcome.skipped.count) of \(rows.count) rows were skipped; see the warnings above",
            code: "rows_skipped")
    }
    // An eval that scored nothing reports WER 0.00%, which reads as a perfect
    // result and is the most dangerous possible output from a measuring
    // instrument. It is a failure, and the exit code has to say so - the report
    // is still written first, because the skip reasons in it are the whole
    // diagnosis.
    if outcome.summary.rows == 0 {
        let reason = outcome.skipped.first?.reason ?? "the manifest produced no usable rows"
        throw SpeechError.runtime(
            "no rows could be scored, so there is no measurement: \(reason)")
    }
}
