// ExportVerb.swift - `speech export <json> --format srt|vtt|txt|json`.
//
// Exists so the applet's Export popup never re-transcribes. A transcription is
// minutes of compute; turning the segments it produced into subtitles is
// microseconds, and the json document written by `transcribe --format json`
// holds everything the other three formats need.

import Foundation
import SpeechCore

func runExport(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    var format = TranscriptFormat.srt
    var output: URL?
    var scanner = ArgScanner(verb: "export", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage("""
                Usage: \(kProgram) export <transcript.json> [--format txt|srt|vtt|json] [--output <path>]

                Converts a transcript written by '\(kProgram) transcribe --format json'
                into another format. Writes to stdout when --output is omitted.
                """)
            return
        case "--format", "-f":
            format = try TranscriptFormat.parse(try scanner.value(token))
        case "--output", "-o":
            output = try scanner.pathValue(token)
        case "--":
            scanner.endOptions()
        default:
            try scanner.addPositional(token)
        }
    }

    let path = try scanner.requirePositional("transcript.json")
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url) else {
        throw SpeechError.usage("cannot read \(url.path)")
    }
    let document: TranscriptDocument
    do {
        document = try JSONDecoder().decode(TranscriptDocument.self, from: data)
    } catch {
        throw SpeechError.usage(
            "\(url.lastPathComponent) is not a transcript written by '\(kProgram) transcribe --format json'")
    }

    // Under --json stdout is a JSON event stream, and srt or vtt written into
    // it would corrupt the stream for a reader. Unlike `transcribe`, which can
    // fall back to segment events, this command's entire product is the
    // rendered document, so there is nothing to warn about and continue with.
    if globals.json, output == nil {
        throw SpeechError.usage("--json requires --output; the converted document is not JSON")
    }

    let rendered = try TranscriptRenderer.render(document, as: format)
    if let output {
        try CLIHelpers.writeAtomically(rendered, to: output)
        sink.emit(.done(.init(
            segments: document.segments.count, audioSeconds: document.segments.last?.end ?? 0,
            wallSeconds: sink.elapsed, peakRSSBytes: SystemInfo.peakResidentBytes(),
            peakMemoryBytes: SystemInfo.peakMemoryBytes(),
            output: output.path)))
    } else {
        sink.document(rendered)
    }
}
