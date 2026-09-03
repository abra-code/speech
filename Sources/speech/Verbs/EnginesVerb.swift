// EnginesVerb.swift - `speech engines`, plus the engine inventory that `info`
// also reports.
//
// "Which engines does this binary have" and "which of them can run on this Mac
// right now" are different questions and both are asked constantly - by the
// applet when it builds a model picker, and by a person wondering why a row is
// grayed out. Every negative answer carries a reason.

import Foundation
import SpeechCore
import SpeechApple

struct KnownEngine {
    let id: String
    let capabilities: EngineCapabilities
    let available: Bool
    let reason: String?
}

/// Every catalog id this build can construct, with the live availability
/// answer. Stage 1 and 2 append their rows here as their targets land.
func knownEngines() -> [KnownEngine] {
    let appleAvailability = AppleSpeech.availability()
    return [AppleSpeech.transcriberID, AppleSpeech.dictationID].compactMap { id in
        let model = String(id.split(separator: ".").dropFirst().joined(separator: "."))
        guard let capabilities = AppleEngineFactory.capabilities(for: model) else { return nil }
        return KnownEngine(
            id: id,
            capabilities: capabilities,
            available: appleAvailability.isAvailable,
            reason: appleAvailability.reason)
    }
}

func capabilityFlags(_ capabilities: EngineCapabilities) -> [String] {
    var flags: [String] = []
    if capabilities.batch { flags.append("batch") }
    if capabilities.live { flags.append("live") }
    if capabilities.wordTimestamps { flags.append("word_ts") }
    if capabilities.segmentTimestamps { flags.append("seg_ts") }
    if capabilities.vocabulary { flags.append("vocab") }
    if capabilities.diarization { flags.append("diarize") }
    if capabilities.languageID { flags.append("lang_id") }
    if capabilities.languageHint { flags.append("lang_hint") }
    return flags
}

func runEngines(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    if arguments.contains("--help") || arguments.contains("-h") {
        CLIHelpers.printUsage("""
            Usage: \(kProgram) engines

            Lists the engines compiled into this binary, their capability flags,
            and whether they can run on this Mac.
            """)
        return
    }

    let engines = knownEngines()
    if globals.json {
        let payload = engines.map { engine -> [String: Any] in
            var row: [String: Any] = [
                "id": engine.id,
                "available": engine.available,
                "capabilities": capabilityFlags(engine.capabilities),
                "languages": engine.capabilities.languages,
                "minimum_macos": engine.capabilities.minimumMacOS,
            ]
            if let reason = engine.reason { row["reason"] = reason }
            return row
        }
        sink.document(try CLIHelpers.jsonString(["engines": payload], compact: true))
        return
    }

    let width = engines.map { $0.id.count }.max() ?? 0
    for engine in engines {
        let name = engine.id.padding(toLength: width, withPad: " ", startingAt: 0)
        let state = engine.available ? "available" : "unavailable"
        var line = "\(name)  \(state.padding(toLength: 11, withPad: " ", startingAt: 0))"
        line += capabilityFlags(engine.capabilities).joined(separator: ", ")
        if !engine.capabilities.languages.isEmpty {
            line += "; " + engine.capabilities.languages.joined(separator: " ")
        }
        sink.text(line)
        if let reason = engine.reason {
            sink.text(String(repeating: " ", count: width + 2) + "  \(reason)")
        }
    }
}
