// RecordVerb.swift - `speech record <file>`: the microphone into a sound file.
//
// The one verb that neither transcribes nor loads a model. It is here because
// Speech.app records the files it then transcribes, and the microphone code in
// this tool already handles what recording needs: choosing a device, formats no
// typed accessor can read, buffers dropped under load, and stopping from a
// signal, stdin or a parent that went away. A separate program would have been
// a second copy of all of it.
//
// The shape is `stream`'s without the engine: a tap copying hardware buffers on
// the audio thread, a writer draining them off it, and one awaited stop. The
// writer mixes the input down to mono at the device's own sample rate and
// writes a hidden file beside the destination, renamed into place when the
// recording ends, so the name the caller asked for never holds half a file.
// A recording cut short by a failure keeps what was captured before it.

import AVFoundation
import Foundation
import SpeechCore

func runRecord(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    var device: String?
    var listDevices = false
    var overwrite = false
    var parentPID: pid_t?
    var watchStdin = true

    var scanner = ArgScanner(verb: "record", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage("""
                Usage: \(kProgram) record <file> [options]

                Records the microphone into a sound file until told to stop.
                The format follows the file's extension: .wav, .aiff or .caf
                (16-bit PCM) or .m4a (AAC). The recording is mono, at the input
                device's own sample rate (at most 48 kHz for .m4a).

                Options:
                  --device <name>    Input device by UID, exact name, or an
                                     unambiguous part of its name
                  --list-devices     Print the audio input devices and exit
                  --overwrite        Replace <file> if it already exists
                  --parent-pid <n>   Stop when process <n> is no longer our parent
                  --no-stdin         Do not watch stdin

                Stopping: 'q' followed by Return on stdin, end of stdin, Ctrl-C,
                SIGTERM or SIGHUP. What was recorded before the stop is kept.
                Because end of stdin stops the run, redirecting stdin from
                /dev/null ends it immediately; use --no-stdin for that.
                """)
            return
        case "--device":
            device = try scanner.value(token)
        case "--list-devices":
            listDevices = true
        case "--overwrite":
            overwrite = true
        case "--no-stdin":
            watchStdin = false
        case "--parent-pid":
            let value = try scanner.intValue(token)
            guard value > 0, value <= Int(pid_t.max) else {
                throw SpeechError.usage("--parent-pid wants a process id (got '\(value)')")
            }
            parentPID = pid_t(value)
        case "--":
            scanner.endOptions()
        default:
            try scanner.addPositional(token)
        }
    }

    if listDevices {
        try scanner.requireNoPositionals()
        try printInputDevices(globals, sink)
        return
    }

    // MARK: Refusals, all before the microphone is asked for

    let requested = try scanner.requirePositional("file")
    let destination = URL(fileURLWithPath: (requested as NSString).expandingTildeInPath)
        .standardizedFileURL
    guard let container = RecordingContainer(pathExtension: destination.pathExtension) else {
        throw SpeechError.usage(
            "record writes .wav, .aiff, .caf or .m4a files (got '\(destination.lastPathComponent)')")
    }
    let directory = destination.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
        throw SpeechError.usage("there is no directory to record into at \(directory.path)")
    }
    // Found here rather than when the file is created, which is after the
    // permission prompt and with the microphone indicator already lit.
    guard FileManager.default.isWritableFile(atPath: directory.path) else {
        throw SpeechError.usage("cannot write into \(directory.path)")
    }
    var destinationIsDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) {
        // A directory is refused whatever --overwrite says: the replacement at
        // the end is a removeItem, which would take the whole tree with it.
        guard !destinationIsDirectory.boolValue else {
            throw SpeechError.usage("\(destination.path) is a directory")
        }
        guard overwrite else {
            throw SpeechError.usage(
                "\(destination.path) already exists; pass --overwrite to replace it")
        }
    }

    guard await Microphone.requestPermission() else {
        throw SpeechError.unavailable(
            "microphone access was refused. macOS grants it to the app that launched this"
            + " tool, not to the tool itself: allow that app under System Settings >"
            + " Privacy & Security > Microphone.")
    }

    // MARK: Wiring

    let stopper = StopController()
    stopper.start(watchStdin: watchStdin, parentPID: parentPID)
    defer { stopper.shutdown() }

    let (captured, capturedContinuation) = AsyncStream<CapturedAudio>.makeStream(
        bufferingPolicy: .bufferingNewest(kRecordQueueDepth))
    let drops = RecordDropCounter()

    // Hidden, beside the destination: the same volume, so the final rename is
    // atomic, and the destination's own extension, which is how AVAudioFile
    // picks the container.
    let stem = destination.deletingPathExtension().lastPathComponent
    let temporary = directory.appendingPathComponent(
        ".\(stem).recording-\(getpid()).\(destination.pathExtension)")

    let microphone = Microphone()
    let writer: RecordingWriter
    do {
        try microphone.start(
            configuration: Microphone.Configuration(device: device),
            onFailure: { message in stopper.stop(.failure(message)) }
        ) { buffer in
            if case .dropped = capturedContinuation.yield(CapturedAudio(buffer)) {
                drops.bump()
            }
        }
        guard let inputFormat = microphone.inputFormat else {
            throw SpeechError.unavailable("the microphone reported no input format")
        }
        writer = try RecordingWriter(url: temporary, container: container, input: inputFormat)
    } catch {
        microphone.stop()
        capturedContinuation.finish()
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }

    let opened = microphone.selectedDevice
    sink.emit(.recordingStarted(.init(
        output: destination.path, device: opened?.name, deviceUID: opened?.uid,
        sampleRate: writer.sampleRate, channels: 1)))

    let writing = Task {
        for await chunk in captured {
            do {
                if let level = try writer.write(chunk.buffer) {
                    sink.emit(.recordingLevel(level))
                }
            } catch {
                stopper.stop(.failure((error as? SpeechError)?.message ?? error.localizedDescription))
                return
            }
        }
    }

    // MARK: Run until stopped

    let reason = await stopper.wait()
    microphone.stop()
    capturedContinuation.finish()
    await writing.value
    writer.close()

    if let failure = microphone.takeFailure(), !reason.isFailure {
        sink.warning(failure, code: "capture")
    }
    if drops.total > 0, !reason.isFailure {
        // Not cosmetic: every dropped buffer is a gap in the file, and a
        // recording with holes in it must not be handed over as if it had none.
        sink.warning(
            "\(drops.total) audio buffer(s) were dropped because writing could not keep up"
            + " with the microphone; the recording has gaps",
            code: "capture_overrun")
    }

    guard writer.frames > 0 else {
        try? FileManager.default.removeItem(at: temporary)
        throw SpeechError.runtime(
            "nothing was recorded (\(reason.label)); no file was written")
    }

    do {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
        throw SpeechError.runtime(
            "the recording could not be moved to \(destination.path): \(error.localizedDescription)."
            + " It is at \(temporary.path)")
    }

    sink.emit(.done(.init(
        segments: 0,
        audioSeconds: writer.seconds,
        wallSeconds: sink.elapsed,
        peakRSSBytes: SystemInfo.peakResidentBytes(),
        peakMemoryBytes: SystemInfo.peakMemoryBytes(),
        output: destination.path)))

    if reason.isFailure {
        throw SpeechError.runtime(
            "recording stopped: \(reason.label); what was recorded before that is in"
            + " \(destination.path)")
    }
}

/// About twenty seconds of hardware buffers at 48 kHz. Deeper than `stream`'s
/// queue because nothing downstream waits on a model: a writer that falls this
/// far behind has a disk problem, and the gap is reported.
private let kRecordQueueDepth = 256

private final class RecordDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// The file formats `record` writes, chosen by extension.
private enum RecordingContainer {
    case wav, aiff, caf, m4a

    init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "wav", "wave": self = .wav
        case "aif", "aiff": self = .aiff
        case "caf": self = .caf
        case "m4a": self = .m4a
        default: return nil
        }
    }

    /// AAC is specified up to 48 kHz; the PCM formats take the device's rate.
    func fileSampleRate(input: Double) -> Double {
        self == .m4a ? min(input, 48_000) : input
    }

    func settings(sampleRate: Double) -> [String: Any] {
        switch self {
        case .wav, .caf, .aiff:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: self == .aiff,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .m4a:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
        }
    }
}

/// Converts capture buffers, mixes them to mono and writes them.
///
/// `@unchecked Sendable` because it is created on the verb's task and then used
/// only by the writer task until the recording ends, when the verb reads the
/// counters and closes it. Nothing touches it from two tasks at once.
private final class RecordingWriter: @unchecked Sendable {
    let sampleRate: Double
    private(set) var frames: AVAudioFramePosition = 0

    var seconds: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    private var file: AVAudioFile?
    /// Input to Float32 at the file's rate, keeping the input's channels. The
    /// mixdown is done here rather than by AVAudioConverter, whose channel
    /// mapping from stereo to mono keeps one channel rather than averaging - a
    /// stereo interface with its microphone on the right would record silence.
    private let converter: AudioFormatConverter
    private let monoFormat: AVAudioFormat

    private var levelSquares: Double = 0
    private var levelPeak: Float = 0
    private var levelFrames = 0
    private let framesPerLevel: Int

    init(url: URL, container: RecordingContainer, input: AVAudioFormat) throws {
        let rate = container.fileSampleRate(input: input.sampleRate)
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: input.channelCount, interleaved: false),
            let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else {
            throw SpeechError.unsupportedFormat(
                "cannot record \(input.channelCount) channel(s) at \(Int(rate)) Hz")
        }
        converter = try AudioFormatConverter(from: input, to: floatFormat)
        monoFormat = mono
        sampleRate = rate
        framesPerLevel = max(1, Int(rate / 5))
        do {
            file = try AVAudioFile(
                forWriting: url, settings: container.settings(sampleRate: rate),
                commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SpeechError.runtime(
                "cannot create \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Writes one capture buffer. Returns a level event when enough audio has
    /// gone by since the last one.
    func write(_ buffer: AVAudioPCMBuffer) throws -> SpeechEvent.RecordingLevel? {
        guard let file else { return nil }
        let converted = try converter.convert(buffer)
        let samples = LiveAudioFormat.samples(converted)
        guard !samples.isEmpty else { return nil }
        guard let mono = AVAudioPCMBuffer(
            pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = mono.floatChannelData?[0]
        else {
            throw SpeechError.runtime("cannot allocate a \(samples.count)-frame recording buffer")
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        mono.frameLength = AVAudioFrameCount(samples.count)
        do {
            try file.write(from: mono)
        } catch {
            throw SpeechError.runtime("cannot write the recording: \(error.localizedDescription)")
        }
        frames += AVAudioFramePosition(samples.count)

        for sample in samples {
            levelSquares += Double(sample) * Double(sample)
            levelPeak = max(levelPeak, abs(sample))
        }
        levelFrames += samples.count
        guard levelFrames >= framesPerLevel else { return nil }
        let rms = (levelSquares / Double(levelFrames)).squareRoot()
        let level = SpeechEvent.RecordingLevel(
            seconds: seconds, rmsDB: 20 * log10(rms), peakDB: 20 * log10(Double(levelPeak)))
        levelSquares = 0
        levelPeak = 0
        levelFrames = 0
        return level
    }

    /// Finishes the file. A PCM header records its length only on close.
    func close() {
        file?.close()
        file = nil
    }
}
