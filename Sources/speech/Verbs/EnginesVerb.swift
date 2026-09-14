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
import SpeechFluid
import SpeechGGML
import SpeechMLX

struct KnownEngine {
    let id: String
    let capabilities: EngineCapabilities
    let available: Bool
    let reason: String?
}

/// Every catalog id this build can construct, with the live availability
/// answer. Stage 1 and 2 append their rows here as their targets land.
func knownEngines() -> [KnownEngine] {
    let apple: [KnownEngine] = [
        (AppleSpeech.transcriberID, AppleEngineKind.transcriber),
        (AppleSpeech.dictationID, AppleEngineKind.dictation),
    ].compactMap { id, kind in
        let model = String(id.split(separator: ".").dropFirst().joined(separator: "."))
        guard let capabilities = AppleEngineFactory.capabilities(for: model) else { return nil }
        let availability = AppleSpeech.availability(for: kind)
        return KnownEngine(
            id: id,
            capabilities: capabilities,
            available: availability.isAvailable,
            reason: availability.reason)
    }

    // The FluidAudio rows this build can construct. "Available" here means the
    // engine can run on this machine, not that its weights are downloaded -
    // that is `models list`, and conflating the two would leave a user staring
    // at "unavailable" for a row that only needs a download.
    #if arch(arm64)
    let fluidReason: String? = nil
    let fluidAvailable = true
    #else
    let fluidReason: String? = "FluidAudio engines need Apple Silicon"
    let fluidAvailable = false
    #endif
    let fluid: [KnownEngine] = FluidEngineFactory.catalogRows.compactMap {
        model, variant in
        guard let capabilities = FluidEngineFactory.capabilities(for: model, variant: variant)
        else { return nil }
        // The OS floor is per row rather than per engine family, and asked
        // through `capabilities` rather than hardcoded here, so a row that
        // raises its floor is reported correctly without touching this verb.
        //
        // It cannot fire today: every `fluid` row names macOS 15 and the binary
        // will not launch below that. It is kept because the alternative is
        // `available` and `minimum_macos` disagreeing the first time a row
        // needs something newer - which is how Canary shipped as "available" on
        // systems that could not load it, with the real floor sitting in the
        // JSON and nowhere else.
        guard capabilities.runsOnThisOS else {
            return KnownEngine(
                id: variant.map { "fluid.\(model)@\($0)" } ?? "fluid.\(model)",
                capabilities: capabilities,
                available: false,
                reason: "needs macOS \(capabilities.minimumMacOS) or later")
        }
        return KnownEngine(
            id: variant.map { "fluid.\(model)@\($0)" } ?? "fluid.\(model)",
            capabilities: capabilities,
            available: fluidAvailable,
            reason: fluidReason)
    }

    // The ggml rows. Same distinction as above: available means the engine can
    // run here, not that the GGUF is downloaded. There is no architecture gate -
    // transcribe.cpp ships an x86_64 slice and falls back to the CPU backend -
    // but the binary is arm64-only for FluidAudio's sake, so the question never
    // comes up in a shipped build.
    let ggml: [KnownEngine] = GGMLEngineFactory.catalogRows.compactMap { model, variant in
        guard let capabilities = GGMLEngineFactory.capabilities(for: model, variant: variant)
        else { return nil }
        let id = variant.map { "ggml.\(model)@\($0)" } ?? "ggml.\(model)"
        guard capabilities.runsOnThisOS else {
            return KnownEngine(
                id: id, capabilities: capabilities, available: false,
                reason: "needs macOS \(capabilities.minimumMacOS) or later")
        }
        return KnownEngine(id: id, capabilities: capabilities, available: true, reason: nil)
    }

    // The mlx rows. A third distinction joins the two above: these need a
    // second binary. "Available" here means the helper was found - not that it
    // starts, not that it can reach the GPU, and still not that the weights are
    // downloaded. Those are answered by the handshake and by `models list`
    // respectively, and asking them here would mean spawning a helper and
    // initializing Metal once per row just to draw a list.
    let mlxHelper = MLXEngineFactory.availability()
    let mlxReason: String? = {
        guard case .failure(let error) = mlxHelper else { return nil }
        return "\(error)"
    }()
    let mlx: [KnownEngine] = MLXEngineFactory.catalogRows.compactMap { model, variant in
        guard let capabilities = MLXEngineFactory.capabilities(for: model, variant: variant)
        else { return nil }
        let id = variant.map { "mlx.\(model)@\($0)" } ?? "mlx.\(model)"
        guard capabilities.runsOnThisOS else {
            return KnownEngine(
                id: id, capabilities: capabilities, available: false,
                reason: "needs macOS \(capabilities.minimumMacOS) or later")
        }
        return KnownEngine(
            id: id, capabilities: capabilities,
            available: mlxReason == nil, reason: mlxReason)
    }

    // A hidden catalog entry is buildable - an id typed in full still runs -
    // but unlisted, and this is a listing.
    return (apple + fluid + ggml + mlx).filter { !Catalog.isHidden(id: $0.id) }
}

/// The published flag names live on `EngineCapabilities` so that this verb, the
/// catalog file and the applet all spell them the same way.
func capabilityFlags(_ capabilities: EngineCapabilities) -> [String] {
    capabilities.allFlags
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
        // 13, not 11: "unavailable" is itself 11 characters, so padding to the
        // width of the longest word leaves no gutter at all and the flags run
        // straight into it - "unavailablebatch, seg_ts". Only visible once a
        // row is actually unavailable, which on this machine no row was until
        // the mlx rows arrived.
        var line = "\(name)  \(state.padding(toLength: 13, withPad: " ", startingAt: 0))"
        // A row can legitimately have no capability flags at all - the CTC
        // spotter is a store row rather than a transcriber - and the separator
        // between flags and languages then has nothing on its left. Build the
        // pieces and join what is actually there.
        var parts: [String] = []
        let flags = capabilityFlags(engine.capabilities)
        if !flags.isEmpty { parts.append(flags.joined(separator: ", ")) }
        if !engine.capabilities.languages.isEmpty {
            parts.append(engine.capabilities.languages.joined(separator: " "))
        }
        line += parts.joined(separator: "; ")
        sink.text(line)
        if let reason = engine.reason {
            sink.text(String(repeating: " ", count: width + 2) + "  \(reason)")
        }
    }
}
