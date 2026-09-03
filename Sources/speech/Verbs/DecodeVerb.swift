// DecodeVerb.swift - `speech decode <media> --output <wav>`.
//
// A debugging aid with one job: prove what the engines were actually given. If
// a model produces nonsense on a file, the first question is whether the audio
// that reached it was the audio in the file, and this is the only way to listen
// to the answer.

import Foundation
import SpeechCore

func runDecode(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    var output: URL?
    var scanner = ArgScanner(verb: "decode", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage("""
                Usage: \(kProgram) decode <media> --output <wav>

                Writes the 16 kHz mono wav that every engine would receive for
                this file. Use it to confirm what was decoded, or to hand the
                same audio to another tool.
                """)
            return
        case "--output", "-o":
            output = try scanner.pathValue(token)
        case "--":
            scanner.endOptions()
        default:
            try scanner.addPositional(token)
        }
    }

    let input = URL(fileURLWithPath: (try scanner.requirePositional("media") as NSString).expandingTildeInPath)
    guard let output else {
        throw SpeechError.usage("--output <wav> is required")
    }

    let samples = try await AudioDecoder.decode(url: input)
    guard !samples.isEmpty else {
        throw SpeechError.unsupportedFormat("\(input.lastPathComponent) decoded to zero samples")
    }
    try AudioDecoder.writeWAV(samples: samples, to: output)

    let audioSeconds = Double(samples.count) / AudioDecoder.sampleRate
    sink.emit(.done(.init(
        segments: 0, audioSeconds: audioSeconds, wallSeconds: sink.elapsed,
        peakRSSBytes: SystemInfo.peakResidentBytes(), output: output.path)))
}
