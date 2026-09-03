// CLI.swift - argument plumbing shared by every verb. No verb-specific logic.
//
// Hand-rolled rather than ArgumentParser, to keep the tool dependency-free the
// way pdfutil and langid are: this binary gets copied into an app bundle and
// signed, and every package it pulls in is another thing to audit and another
// thing that can break the build of a shipping app.

import Foundation
import SpeechCore

let kProgram = "speech"
let kVersionNumber = "0.1.0"
let kVersion = "\(kProgram) \(kVersionNumber)"

/// Flags that mean the same thing to every verb. Extracted in a pre-pass so
/// they may appear before or after the verb: the applet builds these command
/// lines by string concatenation and the order is not worth policing.
struct GlobalOptions: Sendable {
    var json = false
    var verbose = false
    var modelsDirectory: URL
    var logURL: URL?

    var sinkMode: EventSink.Mode { json ? .jsonl : .human }

    /// Default model location. Under the app's own Application Support
    /// directory, never a library's private cache: the applet has to be able to
    /// list, size, reveal and delete these files, and it cannot do that to a
    /// directory some dependency chose.
    static var defaultModelsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SPEECH_MODELS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Transcriber/Models", isDirectory: true)
    }

    /// Pulls the global flags out of the argument list and returns the rest
    /// untouched. Stops at `--`, which every verb treats as end-of-options.
    static func extract(from arguments: [String]) throws -> (GlobalOptions, [String]) {
        var options = GlobalOptions(modelsDirectory: defaultModelsDirectory)
        var rest: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                rest.append(contentsOf: arguments[index...])
                break
            }
            switch argument {
            case "--json":
                options.json = true
            case "--verbose", "-v":
                options.verbose = true
            case "--models-dir":
                index += 1
                guard index < arguments.count else {
                    throw SpeechError.usage("--models-dir requires a path")
                }
                options.modelsDirectory = URL(
                    fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath,
                    isDirectory: true)
            case "--log":
                index += 1
                guard index < arguments.count else {
                    throw SpeechError.usage("--log requires a path")
                }
                options.logURL = URL(
                    fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
            default:
                rest.append(argument)
            }
            index += 1
        }
        return (options, rest)
    }
}

/// A minimal left-to-right token scanner. Each verb drives its own switch; this
/// handles cursor movement, option values, `--`, and the unknown-option versus
/// positional distinction.
struct ArgScanner {
    let verb: String
    private let tokens: [String]
    private var index = 0
    private(set) var positionals: [String] = []

    init(verb: String, _ tokens: [String]) {
        self.verb = verb
        self.tokens = tokens
    }

    mutating func nextToken() -> String? {
        guard index < tokens.count else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    mutating func value(_ option: String) throws -> String {
        guard index < tokens.count else {
            throw SpeechError.usage("option '\(option)' requires a value")
        }
        defer { index += 1 }
        return tokens[index]
    }

    mutating func intValue(_ option: String) throws -> Int {
        let raw = try value(option)
        guard let number = Int(raw) else {
            throw SpeechError.usage("option '\(option)' requires an integer (got '\(raw)')")
        }
        return number
    }

    mutating func pathValue(_ option: String) throws -> URL {
        URL(fileURLWithPath: (try value(option) as NSString).expandingTildeInPath)
    }

    mutating func addPositional(_ argument: String) throws {
        if argument.hasPrefix("-"), argument != "-" {
            throw SpeechError.usage("unknown option '\(argument)'")
        }
        positionals.append(argument)
    }

    mutating func endOptions() {
        while index < tokens.count {
            positionals.append(tokens[index])
            index += 1
        }
    }

    func requirePositional(_ name: String) throws -> String {
        guard let first = positionals.first else {
            throw SpeechError.usage("missing <\(name)>")
        }
        guard positionals.count == 1 else {
            throw SpeechError.usage("expected one <\(name)>, got \(positionals.count)")
        }
        return first
    }
}

enum CLIHelpers {
    /// Usage text goes straight to stdout, not through the event sink.
    ///
    /// `--help` is a question about the tool, asked before any run starts, and
    /// every unix tool answers it on stdout in plain text. Routing it through
    /// the sink would either suppress it under --json or emit prose into a
    /// stream a reader is parsing as JSON. docs/protocol.md records the
    /// exception.
    static func printUsage(_ text: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }

    /// One term per line, blank lines and `#` comments skipped, so a vocabulary
    /// file can be commented.
    static func readVocabulary(_ url: URL) throws -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw SpeechError.usage("cannot read vocabulary file \(url.path)")
        }
        // whereSeparator: \.isNewline, not "\n" - a CRLF pair is one Character
        // and would leave the whole file as a single "term".
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func writeAtomically(_ contents: String, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .atomic)
        } catch {
            throw SpeechError.runtime("cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    /// A JSON document for a query verb (`info`, `engines`, later `catalog`).
    ///
    /// `compact` under --json is not cosmetic: stdout in that mode is a stream
    /// of newline-delimited JSON, and a pretty-printed document would arrive as
    /// a hundred lines that individually parse as nothing.
    static func jsonString(_ value: Any, compact: Bool = false) throws -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if !compact { options.insert(.prettyPrinted) }
        let data = try JSONSerialization.data(withJSONObject: value, options: options)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SpeechError.runtime("cannot encode JSON")
        }
        return string
    }
}
