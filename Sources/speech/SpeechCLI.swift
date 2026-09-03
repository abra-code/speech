// SpeechCLI.swift - entry point: the verb table, global help and version,
// dispatch, and the translation of SpeechError into the exit-code contract.
//
// Exit status is part of the published interface (part 4 of the development
// plan) because the applet's shell scripts branch on it:
//   0 success
//   1 runtime error
//   2 usage error or an engine that cannot run here
//   3 the model is not installed - the applet turns this into a download offer

import Foundation
import SpeechCore
import SpeechApple

struct VerbEntry: Sendable {
    let name: String
    let summary: String
    let run: @Sendable (GlobalOptions, EventSink, [String]) async throws -> Void
}

let gVerbs: [VerbEntry] = [
    VerbEntry(name: "info", summary: "Report the machine, engine availability and Apple locales", run: runInfo),
    VerbEntry(name: "engines", summary: "List the engines in this build with their capability flags", run: runEngines),
    VerbEntry(name: "models", summary: "Install Apple locales; download and manage model files", run: runModels),
    VerbEntry(name: "transcribe", summary: "Transcribe an audio or video file", run: runTranscribe),
    VerbEntry(name: "eval", summary: "Score a model against a manifest (WER, CER, RTFx, peak RSS)", run: runEval),
    VerbEntry(name: "export", summary: "Convert a saved json transcript to txt, srt or vtt", run: runExport),
    VerbEntry(name: "decode", summary: "Write the decoded 16 kHz mono wav a model would receive", run: runDecode),
]

/// Verbs the plan defines but a later stage implements. Listed so `--help`
/// tells the truth about where the tool is, rather than pretending they do not
/// exist and then failing with "unknown verb".
let gPlannedVerbs: [(name: String, stage: String)] = [
    ("catalog", "stage 3"),
    ("stream", "stage 4"),
    ("notices", "stage 6"),
]

func printGlobalUsage(to handle: FileHandle) {
    let width = (gVerbs.map { $0.name.count } + gPlannedVerbs.map { $0.name.count }).max() ?? 0
    var out = "Usage: \(kProgram) <verb> [options] [arguments]\n\n"
    out += "Verbs:\n"
    for verb in gVerbs {
        out += "  " + verb.name.padding(toLength: width, withPad: " ", startingAt: 0)
            + "  " + verb.summary + "\n"
    }
    out += "\nNot implemented yet:\n"
    for verb in gPlannedVerbs {
        out += "  " + verb.name.padding(toLength: width, withPad: " ", startingAt: 0)
            + "  arrives in \(verb.stage)\n"
    }
    out += "\nGlobal options:\n"
    out += "  --json               Emit JSONL events on stdout instead of human text\n"
    out += "  --models-dir <path>  Where model files live"
        + " (default ~/Library/Application Support/Transcriber/Models)\n"
    out += "  --log <path>         Append every event as JSONL to this file, whatever the mode\n"
    out += "  --verbose            Show the status line even when stderr is not a terminal\n"
    out += "  --help               Show this help\n"
    out += "  --version            Show the version and exit\n"
    out += "\nRun '\(kProgram) <verb> --help' for a verb's own options.\n"
    out += "Exit status: 0 success, 1 runtime error, 2 usage or unavailable engine,"
        + " 3 model missing.\n"
    try? handle.write(contentsOf: Data(out.utf8))
}

func writeErr(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
}

/// Engines this build was linked with. A build without SpeechFluid simply has
/// no "fluid" entry and reports `unavailable` for those ids rather than failing
/// to link, which is what lets stages land one engine at a time.
func makeRegistry() -> EngineRegistry {
    let registry = EngineRegistry()
    registry.register(prefix: "apple", factory: AppleEngineFactory.make)
    return registry
}

@main
struct SpeechCLI {
    static func main() async {
        // A tool that writes to a pipe must survive the reader closing it
        // (`speech transcribe x.wav | head -1`). Without this the process dies
        // on SIGPIPE before any of the error handling below can run.
        signal(SIGPIPE, SIG_IGN)

        let raw = Array(CommandLine.arguments.dropFirst())

        if raw.isEmpty {
            printGlobalUsage(to: .standardOutput)
            exit(0)
        }
        if raw.contains("--version"), !raw.contains("--") {
            print(kVersion)
            exit(0)
        }

        let globals: GlobalOptions
        let arguments: [String]
        do {
            (globals, arguments) = try GlobalOptions.extract(from: raw)
        } catch let error as SpeechError {
            writeErr("\(kProgram): \(error.message)\n")
            exit(error.exitCode)
        } catch {
            writeErr("\(kProgram): \(error.localizedDescription)\n")
            exit(1)
        }

        guard let first = arguments.first else {
            printGlobalUsage(to: .standardOutput)
            exit(0)
        }
        if first == "--help" || first == "-h" {
            printGlobalUsage(to: .standardOutput)
            exit(0)
        }
        if first == "--version" {
            print(kVersion)
            exit(0)
        }
        if first.hasPrefix("-") {
            writeErr("\(kProgram): unknown option '\(first)'\nTry '\(kProgram) --help'.\n")
            exit(2)
        }
        if let planned = gPlannedVerbs.first(where: { $0.name == first }) {
            writeErr("\(kProgram): '\(planned.name)' is not implemented yet"
                + " (arrives in \(planned.stage) of the development plan).\n")
            exit(2)
        }
        guard let verb = gVerbs.first(where: { $0.name == first }) else {
            writeErr("\(kProgram): unknown verb '\(first)'\nTry '\(kProgram) --help'.\n")
            exit(2)
        }

        let sink = EventSink(
            mode: globals.sinkMode, logURL: globals.logURL, verbose: globals.verbose)

        do {
            try await verb.run(globals, sink, Array(arguments.dropFirst()))
            sink.flush()
            exit(0)
        } catch let error as SpeechError {
            report(error, verb: verb.name, sink: sink, globals: globals)
            exit(error.exitCode)
        } catch is CancellationError {
            report(SpeechError.runtime("canceled"), verb: verb.name, sink: sink, globals: globals)
            exit(1)
        } catch {
            report(
                SpeechError.runtime(error.localizedDescription),
                verb: verb.name, sink: sink, globals: globals)
            exit(1)
        }
    }

    /// Errors reach the caller twice on purpose: as an `error` event for a
    /// machine reader, and on stderr for a person. Under --json stderr stays
    /// human-readable and stdout stays pure JSONL, so both consumers get a
    /// usable stream from the same run.
    private static func report(
        _ error: SpeechError, verb: String, sink: EventSink, globals: GlobalOptions
    ) {
        sink.error(error)
        sink.flush()
        if globals.json {
            writeErr("\(kProgram) \(verb): \(error.message)\n")
        }
        if case .usage = error {
            writeErr("Try '\(kProgram) \(verb) --help'.\n")
        }
    }
}
