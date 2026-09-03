// ModelsVerb.swift - `speech models <subcommand>`.
//
// Stage 0 implements `install-locale`, because the Apple engines need it before
// they can be measured in anything but US English, and it is the one model
// operation that has nothing to download from Hugging Face. `list`, `download`,
// `delete` and `status` arrive with the model store in stage 1; they refuse
// clearly rather than being absent, so a script written against the plan gets a
// reason instead of "unknown verb".

import Foundation
import SpeechCore
import SpeechApple

private let gPlannedModelSubcommands: [(name: String, stage: String)] = [
    ("list", "stage 1"),
    ("download", "stage 1"),
    ("delete", "stage 1"),
    ("status", "stage 1"),
]

func runModels(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    func usage() -> String {
        var text = "Usage: \(kProgram) models install-locale <bcp47>\n\n"
        text += "Subcommands:\n"
        text += "  install-locale <bcp47>  Install Apple's speech assets for a locale (for example pl-PL)\n"
        text += "\nNot implemented yet:\n"
        for planned in gPlannedModelSubcommands {
            text += "  \(planned.name.padding(toLength: 22, withPad: " ", startingAt: 0))"
                + "  arrives in \(planned.stage)\n"
        }
        return text
    }

    // A missing subcommand is a usage error like every other missing argument,
    // not a help request. Printing prose on stdout and exiting 0 would break
    // the --json contract and tell a script the command succeeded.
    guard let subcommand = arguments.first else {
        throw SpeechError.usage("missing subcommand\n\n" + usage())
    }
    if subcommand == "--help" || subcommand == "-h" {
        CLIHelpers.printUsage(usage())
        return
    }
    if let planned = gPlannedModelSubcommands.first(where: { $0.name == subcommand }) {
        throw SpeechError.usage(
            "'models \(planned.name)' is not implemented yet (arrives in \(planned.stage))")
    }
    guard subcommand == "install-locale" else {
        throw SpeechError.usage("unknown subcommand 'models \(subcommand)'")
    }

    var scanner = ArgScanner(verb: "models install-locale", Array(arguments.dropFirst()))
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage(usage())
            return
        case "--":
            scanner.endOptions()
        default:
            try scanner.addPositional(token)
        }
    }
    let tag = try scanner.requirePositional("bcp47")

    let installed = try await AppleSpeech.installLocale(tag) { progress in
        sink.modelProgress(model: "apple.\(Language.canonical(tag))", progress)
    }
    // One line per module that took the locale, and no stdout output: this
    // command's product is a side effect, like mkdir. Apple installs the asset
    // system-wide and publishes neither a path nor a size, so the event omits
    // both rather than inventing "system" and 0 bytes.
    for entry in installed {
        sink.emit(.modelInstalled(.init(model: "\(entry.engine)@\(entry.locale)")))
    }
}
