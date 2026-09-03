// InfoVerb.swift - `speech info`. The first thing to run when something does
// not work, and the thing the applet calls at launch to decide what to offer.
//
// It answers, in one place: what Mac is this, what OS, how much RAM, where do
// models live, which engines exist, and - the part that matters most in
// practice - exactly which Apple speech locales this machine supports and which
// are actually installed. That last distinction is the source of most "it just
// produced nothing" reports: a locale can be supported and absent.

import Foundation
import SpeechCore
import SpeechApple

func runInfo(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    if arguments.contains("--help") || arguments.contains("-h") {
        CLIHelpers.printUsage("""
            Usage: \(kProgram) info

            Reports the machine, the models directory, engine availability, and
            the Apple speech locales this Mac supports and has installed.
            """)
        return
    }

    let engines = knownEngines()
    let localeReports = await AppleSpeech.localeReports()

    if globals.json {
        var payload: [String: Any] = [
            "version": kVersionNumber,
            "machine": [
                "chip": SystemInfo.chip,
                "arch": SystemInfo.isAppleSilicon ? "arm64" : "x86_64",
                "memory_bytes": SystemInfo.physicalMemoryBytes,
                "macos": SystemInfo.operatingSystemVersion,
            ],
            "models_dir": globals.modelsDirectory.path,
            "engines": engines.map { engine -> [String: Any] in
                var row: [String: Any] = [
                    "id": engine.id,
                    "available": engine.available,
                    "capabilities": capabilityFlags(engine.capabilities),
                    "languages": engine.capabilities.languages,
                    "minimum_macos": engine.capabilities.minimumMacOS,
                ]
                if let reason = engine.reason { row["reason"] = reason }
                return row
            },
        ]
        payload["apple_locales"] = localeReports.map {
            ["engine": $0.engine, "supported": $0.supported, "installed": $0.installed]
        }
        sink.document(try CLIHelpers.jsonString(payload, compact: true))
        return
    }

    sink.text(kVersion)
    sink.text("Machine:    \(SystemInfo.chip), "
        + "\(SystemInfo.formatBytes(SystemInfo.physicalMemoryBytes)) RAM, "
        + "macOS \(SystemInfo.operatingSystemVersion), "
        + "\(SystemInfo.isAppleSilicon ? "arm64" : "x86_64")")
    sink.text("Models dir: \(globals.modelsDirectory.path)")

    sink.text("")
    sink.text("Engines:")
    for engine in engines {
        sink.text("  \(engine.id)  \(engine.available ? "available" : "unavailable")")
        sink.text("    \(capabilityFlags(engine.capabilities).joined(separator: ", "))")
        if let reason = engine.reason {
            sink.text("    \(reason)")
        }
    }

    guard !localeReports.isEmpty else { return }
    sink.text("")
    sink.text("Apple speech locales:")
    for report in localeReports {
        sink.text("  \(report.engine)")
        sink.text("    supported (\(report.supported.count)): \(report.supported.joined(separator: " "))")
        let installed = report.installed.isEmpty ? "none" : report.installed.joined(separator: " ")
        sink.text("    installed (\(report.installed.count)): \(installed)")
    }
    sink.text("")
    sink.text("Install a locale with: \(kProgram) models install-locale <bcp47>")
}
