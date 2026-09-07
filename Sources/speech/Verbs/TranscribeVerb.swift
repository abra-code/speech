// TranscribeVerb.swift - `speech transcribe <media> --model <catalog-id>`.
//
// The batch path, and the one the applet drives for dropped files. Its shape is
// the same for every engine and always will be: decode once with AVFoundation,
// hand the samples to whatever the catalog id resolved to, write the result in
// the requested format.
//
// Output routing is the fiddly part, and the rule is: under --json, stdout is
// JSONL and nothing else, ever. Without --json, stdout is the transcript, so
// `speech transcribe x.m4a --model apple.transcriber > x.txt` behaves like a
// unix filter and the progress line still goes to the terminal on stderr.

import Foundation
import SpeechCore

func runTranscribe(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    enum Timestamps: String {
        case word, segment, none
    }

    var model: String?
    var language: String?
    var vocabulary: [String] = []
    var format = TranscriptFormat.txt
    var output: URL?
    var timestamps = Timestamps.word

    var scanner = ArgScanner(verb: "transcribe", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage("""
                Usage: \(kProgram) transcribe <media> --model <catalog-id> [options]

                Options:
                  --model <id>          Catalog id, for example apple.transcriber (required)
                  --language <tag>      BCP-47 language hint, for example pl-PL
                  --vocab <file>        One term per line; engines without vocabulary support warn
                  --format <fmt>        txt (default), srt, vtt or json
                  --output <path>       Write to a file instead of stdout
                  --timestamps <kind>   word (default), segment or none

                Run '\(kProgram) engines' for the ids this build can run.
                """)
            return
        case "--model", "-m":
            model = try scanner.value(token)
        case "--language", "-l":
            language = try scanner.value(token)
        case "--vocab":
            vocabulary = try CLIHelpers.readVocabulary(try scanner.pathValue(token))
        case "--format", "-f":
            format = try TranscriptFormat.parse(try scanner.value(token))
        case "--output", "-o":
            output = try scanner.pathValue(token)
        case "--timestamps":
            let raw = try scanner.value(token)
            guard let parsed = Timestamps(rawValue: raw.lowercased()) else {
                throw SpeechError.usage("--timestamps wants word, segment or none (got '\(raw)')")
            }
            timestamps = parsed
        case "--":
            scanner.endOptions()
        default:
            try scanner.addPositional(token)
        }
    }

    let mediaPath = try scanner.requirePositional("media")
    let media = URL(fileURLWithPath: (mediaPath as NSString).expandingTildeInPath)
    guard let model else {
        throw SpeechError.usage("--model <catalog-id> is required")
    }

    let engine = try makeRegistry().make(catalogID: model, modelsDirectory: globals.modelsDirectory)
    if !engine.capabilities.batch {
        // "Not batch" stopped implying "live" once the catalog gained a row
        // that is neither: `fluid.parakeet-ctc-110m` is the spotter other rows
        // use for custom vocabulary. Telling its user it is a live-only engine
        // sends them to `speech stream`, which refuses it too.
        throw SpeechError.usage(
            engine.capabilities.live
                ? "\(model) cannot transcribe files; it is a live-only engine"
                : "\(model) cannot transcribe files; it is not a transcription engine")
    }
    // Before the file is decoded and the weights are loaded. The engine gets to
    // refuse a request it can already tell it cannot serve - today that is a
    // custom vocabulary whose spotter row is not installed, which would
    // otherwise surface after an hour of audio had been transcribed and thrown
    // away.
    try await engine.validate(
        TranscribeOptions(
            language: language, vocabulary: vocabulary,
            wantWordTimestamps: timestamps == .word))
    if !engine.capabilities.supports(language: language) {
        // A warning, not a refusal. The capability list is a catalog fact that
        // can lag an OS update or a model release; the engine's own resolution
        // is the authority and throws with a better message when it really has
        // nothing for the language. Refusing here would block a combination
        // that works the day Apple ships a new locale.
        sink.warning(
            "\(model) does not list '\(language ?? "")' among its languages"
            + " (\(engine.capabilities.languages.joined(separator: " ")))",
            code: "language_not_listed")
    }
    if !vocabulary.isEmpty, !engine.capabilities.vocabulary {
        sink.warning(
            "\(model) cannot bias recognition with a custom vocabulary; the terms were ignored",
            code: "vocabulary_unsupported")
        vocabulary = []
    }

    let samples = try await AudioDecoder.decode(url: media)
    guard !samples.isEmpty else {
        throw SpeechError.unsupportedFormat("\(media.lastPathComponent) decoded to zero samples")
    }
    let audioSeconds = Double(samples.count) / AudioDecoder.sampleRate
    sink.emit(.progress(.init(audioSecondsDone: 0, audioSecondsTotal: audioSeconds)))

    let loadStart = ContinuousClock().now
    let resolvedLocale = try await engine.prepare(language: language) { progress in
        sink.modelProgress(model: model, progress)
    }
    sink.emit(.engineReady(.init(
        engine: engine.id, model: model, capabilities: engine.capabilities,
        loadSeconds: elapsedSeconds(since: loadStart), locale: resolvedLocale)))

    // Unloaded on the failure path too, not only on the way out. `defer`
    // cannot await, so this is the shape that gets it: an engine that throws
    // still has to give its weights back, and for the ggml rows it is stronger
    // than that - ggml asserts at process exit if a model still holds Metal
    // buffers, so an un-unloaded engine turns a clean error message into a
    // native backtrace printed over it.
    var segments: [Segment]
    do {
        segments = try await engine.transcribe(
            samples: samples,
            options: TranscribeOptions(
                language: language,
                vocabulary: vocabulary,
                wantWordTimestamps: timestamps == .word))
    } catch {
        await engine.unload()
        throw error
    }
    await engine.unload()

    if timestamps != .word {
        // Dropping the words is the whole difference between the three
        // settings: segment timings live on the segment itself, and `none`
        // simply means the caller wants text and will not look at either.
        for index in segments.indices { segments[index].words = nil }
    }

    sink.emit(.progress(.init(audioSecondsDone: audioSeconds, audioSecondsTotal: audioSeconds)))

    // In human mode with the default text output, the segment events are the
    // transcript on stdout. In any other combination they would interleave with
    // a rendered document, so they are held back and the document is written
    // once, whole.
    let streamsSegments = globals.json || (format == .txt && output == nil)
    if streamsSegments {
        for segment in segments {
            sink.emit(.segmentFinal(segment))
        }
    }

    let document = TranscriptDocument(model: model, language: language, segments: segments)
    let rendered = try TranscriptRenderer.render(document, as: format)

    if let output {
        try CLIHelpers.writeAtomically(rendered, to: output)
    } else if !streamsSegments {
        if globals.json {
            sink.warning(
                "--format \(format.rawValue) without --output produces nothing under --json;"
                + " the segments are in the segment.final events",
                code: "format_ignored")
        } else {
            sink.document(rendered)
        }
    }

    sink.emit(.done(.init(
        segments: segments.count,
        audioSeconds: audioSeconds,
        wallSeconds: sink.elapsed,
        peakRSSBytes: SystemInfo.peakResidentBytes(),
        peakMemoryBytes: SystemInfo.peakMemoryBytes() + (await engine.peakOutOfProcessMemoryBytes() ?? 0),
        output: output?.path)))
}

func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
    Double((ContinuousClock().now - start) / .milliseconds(1)) / 1000.0
}
