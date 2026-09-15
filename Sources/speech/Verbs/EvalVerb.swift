// EvalVerb.swift - `speech eval --model <id> --manifest <tsv>`.
//
// The command the catalog is built out of. Everything interesting happens in
// SpeechCore.Evaluator or SpeechCore.LiveEvaluator; this is argument handling
// and the --limit rule, which matters: it takes the FIRST n rows,
// never a random n, so that a 200-row run of one engine and a 200-row run of
// another are the same 200 utterances.
//
// `--live` swaps the instrument, not the verb. The same manifest, the same
// scorer, the same report - measured through the live path instead of the
// batch one, so the two numbers for one model are directly comparable and the
// difference between them is exactly the cost of streaming it.

import Foundation
import SpeechCore

func runEval(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    var model: String?
    var manifest: URL?
    var language: String?
    var limit: Int?
    var reportDirectory: URL?
    var live = false
    var pace = 1.0
    var segmentation = LiveSegmentation.engine

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
                  --live             Measure the live path: play each row to a live
                                     session in real time, as if it were spoken into
                                     the microphone
                  --pace <x>         With --live, play the audio at x times real time.
                                     The default, 1.0, is the only value whose
                                     latencies mean anything; anything else is a smoke
                                     test and is stamped into the report as one.
                  --segment <how>    With --live, where utterance boundaries come
                                     from: 'engine' (default) or 'vad'. WER is
                                     unaffected either way - the words are the same
                                     and the scorer joins them - so this measures the
                                     latencies and the shape of the transcript.

                Reports WER, CER, RTFx and peak memory. Corpus WER is total edits over
                total reference words, not the mean of the per-row rates.

                --live also reports time to first partial, how far behind the audio
                the committed text runs, the wait after the audio ends, and how many
                reference words the transcript never reached.
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
        case "--live":
            live = true
        case "--pace":
            pace = try scanner.doubleValue(token)
        case "--segment":
            let value = try scanner.value(token)
            guard let parsed = LiveSegmentation(rawValue: value) else {
                throw SpeechError.usage(
                    "--segment wants "
                    + LiveSegmentation.allCases.map(\.rawValue).joined(separator: " or ")
                    + " (got '\(value)')")
            }
            segmentation = parsed
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
    guard live || pace == 1 else {
        throw SpeechError.usage("--pace only means something with --live")
    }
    guard live || segmentation == .engine else {
        throw SpeechError.usage("--segment only means something with --live")
    }
    guard pace > 0 else {
        throw SpeechError.usage("--pace wants a positive multiple of real time (got \(pace))")
    }

    var rows = try Manifest.load(manifest)
    if let limit, rows.count > limit {
        rows = Array(rows.prefix(limit))
    }

    let engine = try makeRegistry().make(catalogID: model, modelsDirectory: globals.modelsDirectory)
    if live {
        guard engine.capabilities.live else {
            throw SpeechError.usage(
                "\(model) has no live mode, so there is nothing for --live to measure;"
                + " run '\(kProgram) engines' and pick a row with the 'live' flag")
        }
        if pace != 1 {
            // Said out loud as well as written into the report. A number taken
            // at another speed is not a latency anyone will experience, and the
            // person most likely to quote it is the person who typed --pace to
            // make the run finish sooner.
            sink.warning(
                "the audio is being played at \(pace)x real time, so the latencies below"
                + " describe no real session; only --pace 1 is quotable",
                code: "pace_not_realtime")
        }
    } else {
        guard engine.capabilities.batch else {
            throw SpeechError.usage(
                "\(model) cannot transcribe files, so it cannot be scored this way")
        }
    }

    // Built before the manifest is played, so a missing detector row costs a
    // download instruction rather than a run that is segmented the old way.
    var vadEngine: (any VoiceActivityEngine)?
    var vad: (any VoiceActivityDetector)?
    if segmentation == .vad {
        let candidate = try makeRegistry().make(
            catalogID: VoiceActivity.defaultRow, modelsDirectory: globals.modelsDirectory)
        guard let detector = candidate as? any VoiceActivityEngine else {
            throw SpeechError.unavailable(
                "'\(VoiceActivity.defaultRow)' in this build cannot detect speech")
        }
        vadEngine = detector
        vad = try await detector.makeDetector { progress in
            sink.modelProgress(model: VoiceActivity.defaultRow, progress)
        }
    }

    // Unloaded on the failure path too - see the note in TranscribeVerb.
    let outcome: EvalOutcome
    do {
        if live {
            outcome = try await LiveEvaluator.run(
                engine: engine, catalogID: model, rows: rows, language: language,
                pace: pace, vad: vad, sink: sink, reportDirectory: reportDirectory)
        } else {
            outcome = try await Evaluator.run(
                engine: engine, catalogID: model, rows: rows, language: language,
                sink: sink, reportDirectory: reportDirectory)
        }
    } catch {
        await engine.unload()
        if let vadEngine { await vadEngine.unload() }
        throw error
    }
    await engine.unload()
    if let vadEngine { await vadEngine.unload() }

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
