// StreamVerb.swift - `speech stream --model <catalog-id>`: the microphone.
//
// This is the only command that has no end of its own, so its shape is not
// "read, compute, write" but a set of concurrent parts wired together and one
// awaited stop:
//
//   the tap             audio thread, allocates a copy per callback
//   the pump            converts, feeds the session, keeps the refine buffer
//   the session         the draft engine, emitting partials and finals
//   the refine queue    a second engine, one utterance at a time
//   the stop controller signals, stdin, the parent watchdog
//
// The one rule that shapes all of it: nothing on the path from the tap to the
// draft engine may block on anything slower than the draft engine. A refine
// engine at 12x real time and a model load that takes a second both sit off to
// the side, and the audio keeps flowing past them.
//
// `--refine` is why the pump converts twice. The draft session wants whatever
// format it named; refinement wants the project's canonical 16 kHz mono, which
// is what every batch measurement in this project was taken on - handing the
// refine engine anything else would make its output incomparable to its own
// eval numbers.

import AVFoundation
import Foundation
import SpeechCore

/// Counts capture buffers the pump could not keep up with.
///
/// The tap block is `@Sendable` and cannot mutate a captured local, so the
/// count needs an object. Tiny and lock-guarded rather than an atomic, because
/// it is written once per dropped buffer and read once at the end.
private final class DropCounter: @unchecked Sendable {
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

func runStream(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    var model: String?
    var refine: String?
    var language: String?
    var vocabulary: [String] = []
    var device: String?
    var listDevices = false
    var parentPID: pid_t?
    var watchStdin = true

    var scanner = ArgScanner(verb: "stream", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage("""
                Usage: \(kProgram) stream --model <catalog-id> [options]

                Transcribes the microphone until told to stop, emitting partial
                results as you speak and a final result for each utterance.

                Options:
                  --model <id>       Catalog id of the live engine (required)
                  --refine <id>      Re-transcribe each finished utterance with a
                                     second, slower, better engine and emit
                                     segment.refined with the same id
                  --language <tag>   BCP-47 language hint, for example pl-PL
                  --vocab <file>     One term per line; engines without vocabulary
                                     support warn and continue
                  --device <name>    Input device by UID, exact name, or an
                                     unambiguous part of its name
                  --list-devices     Print the audio input devices and exit
                  --parent-pid <n>   Stop when process <n> is no longer our parent
                  --no-stdin         Do not watch stdin

                Stopping: 'q' followed by Return on stdin, end of stdin, Ctrl-C,
                SIGTERM or SIGHUP. Because end of stdin stops the run, redirecting
                stdin from /dev/null ends it immediately; use --no-stdin for that.

                Run '\(kProgram) engines' for the ids this build can run, and look
                for the 'live' flag.
                """)
            return
        case "--model", "-m":
            model = try scanner.value(token)
        case "--refine":
            refine = try scanner.value(token)
        case "--language", "-l":
            language = try scanner.value(token)
        case "--vocab":
            vocabulary = try CLIHelpers.readVocabulary(try scanner.pathValue(token))
        case "--device":
            device = try scanner.value(token)
        case "--list-devices":
            listDevices = true
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
    try scanner.requireNoPositionals()

    if listDevices {
        try printInputDevices(globals, sink)
        return
    }

    guard let model else {
        throw SpeechError.usage("--model <catalog-id> is required")
    }

    let registry = makeRegistry()
    let engine = try registry.make(catalogID: model, modelsDirectory: globals.modelsDirectory)
    guard engine.capabilities.live else {
        throw SpeechError.usage(
            "\(model) has no live mode; use '\(kProgram) transcribe' for it,"
            + " or run '\(kProgram) engines' and pick a row with the 'live' flag")
    }

    var options = TranscribeOptions(
        language: language, vocabulary: vocabulary, wantWordTimestamps: true)
    try await engine.validate(options)
    if !engine.capabilities.supports(language: language) {
        sink.warning(
            "\(model) does not list '\(language ?? "")' among its languages"
            + " (\(engine.capabilities.languages.joined(separator: " ")))",
            code: "language_not_listed")
    }
    if !vocabulary.isEmpty, !engine.capabilities.vocabulary {
        sink.warning(
            "\(model) cannot bias recognition with a custom vocabulary; the terms were ignored",
            code: "vocabulary_unsupported")
        options.vocabulary = []
    }

    // The refine engine is built and validated before the microphone opens, so
    // a mistyped id costs a message rather than a recording session that turns
    // out to have produced no refinements.
    var refineEngine: (any TranscriptionEngine)?
    if let refine {
        guard refine != model else {
            throw SpeechError.usage(
                "--refine \(refine) is the same engine as --model;"
                + " refinement would re-run the model that already produced the text")
        }
        let candidate = try registry.make(
            catalogID: refine, modelsDirectory: globals.modelsDirectory)
        guard candidate.capabilities.batch else {
            throw SpeechError.usage("\(refine) cannot transcribe a buffer, so it cannot refine")
        }
        try await candidate.validate(options)
        refineEngine = candidate
    }

    guard await Microphone.requestPermission() else {
        throw SpeechError.unavailable(
            "microphone access was refused. macOS grants it to the app that launched this"
            + " tool, not to the tool itself: allow that app under System Settings >"
            + " Privacy & Security > Microphone.")
    }

    // MARK: Load

    let loadStart = ContinuousClock().now
    let resolvedLocale = try await engine.prepare(language: language) { progress in
        sink.modelProgress(model: model, progress)
    }
    sink.emit(.engineReady(.init(
        engine: engine.id, model: model, capabilities: engine.capabilities,
        loadSeconds: elapsedSeconds(since: loadStart), locale: resolvedLocale)))

    if let refineEngine, let refine {
        let refineStart = ContinuousClock().now
        let refineLocale = try await refineEngine.prepare(language: language) { progress in
            sink.modelProgress(model: refine, progress)
        }
        sink.emit(.engineReady(.init(
            engine: refineEngine.id, model: refine, capabilities: refineEngine.capabilities,
            loadSeconds: elapsedSeconds(since: refineStart), locale: refineLocale)))
    }

    let session = try await engine.makeLiveSession(options: options)

    // MARK: Wiring

    let stopper = StopController()
    stopper.start(watchStdin: watchStdin, parentPID: parentPID)
    defer { stopper.shutdown() }

    let audio = LiveAudioBuffer()
    let queue = refineEngine.map { engine in
        RefinementQueue(
            engine: engine,
            options: options,
            onRefined: { segment in
                sink.emit(.segmentRefined(.init(segment: segment, refinedBy: engine.id)))
            },
            onWarning: { message, code in sink.warning(message, code: code) })
    }

    // Events out of the session and into the sink. Finals also hand their span
    // to the refine queue and release the audio behind them, which is the only
    // thing keeping the buffer bounded on a long run.
    let pumpEvents = Task { [queue] in
        for await event in session.events {
            switch event {
            case .partial(let segment):
                sink.emit(.segmentPartial(segment))
            case .final(let segment):
                sink.emit(.segmentFinal(segment))
                if let queue {
                    if let samples = await audio.slice(from: segment.start, to: segment.end) {
                        await queue.submit(segment, samples: samples)
                    }
                }
                await audio.discard(before: segment.end)
            }
        }
    }

    // Capture buffers cross into structured concurrency here.
    // `bufferingNewest` rather than an unbounded stream: if the draft engine
    // falls behind real time the choice is to drop audio or to grow without
    // limit, and dropping is the one that keeps the session alive and can be
    // reported.
    let (captured, capturedContinuation) = AsyncStream<CapturedAudio>.makeStream(
        bufferingPolicy: .bufferingNewest(kCaptureQueueDepth))
    let drops = DropCounter()

    // The pump can only be built once the tap is open, because it needs the
    // format the hardware actually chose. A format the converter cannot handle
    // is therefore an error one buffer into the run rather than at startup, and
    // the `catch` below is what turns it back into a clean exit.
    let microphone = Microphone()
    let pump: LivePump
    let pumpAudio: Task<Void, Never>
    do {
        try microphone.start(
            configuration: Microphone.Configuration(device: device),
            // The tap cannot report an error any other way: it returns void, on
            // the audio thread, and simply stops delivering. Ending the run here
            // is the difference between "no audio arrived, here is why" and a
            // session that looks live and is silent until the user gives up.
            onFailure: { message in stopper.stop(.failure(message)) }
        ) { buffer in
            if case .dropped = capturedContinuation.yield(CapturedAudio(buffer)) {
                drops.bump()
            }
        }
        guard let inputFormat = microphone.inputFormat else {
            throw SpeechError.unavailable("the microphone reported no input format")
        }
        pump = try LivePump(
            session: session,
            inputFormat: inputFormat,
            audio: queue == nil ? nil : audio,
            // Silence was appended to keep the refinement clock aligned; say so
            // once, because the refinement covering that span will be wrong.
            onConversionFailure: {
                sink.warning(
                    "some audio could not be converted for refinement;"
                    + " affected utterances are refined from silence",
                    code: "refine_conversion")
            })
        let started = pump
        pumpAudio = Task {
            do {
                try await started.run(captured)
            } catch is CancellationError {
                return
            } catch {
                stopper.stop(.failure(
                    (error as? SpeechError)?.message ?? error.localizedDescription))
            }
        }
    } catch {
        microphone.stop()
        capturedContinuation.finish()
        pumpEvents.cancel()
        await session.cancel()
        await engine.unload()
        if let refineEngine { await refineEngine.unload() }
        throw error
    }

    // MARK: Run until stopped

    let reason = await stopper.wait()
    microphone.stop()
    capturedContinuation.finish()
    _ = await pumpAudio.value
    // Only when it is not already the reason the run ended. When it is, the
    // thrown error below carries the same words, and saying them twice reads
    // like two separate problems.
    if let failure = microphone.takeFailure(), !reason.isFailure {
        sink.warning(failure, code: "capture")
    }
    // Only when the run ended normally. When the pump died, the tap kept
    // yielding into a stream nobody was draining, so every remaining buffer was
    // "dropped" - and blaming that on transcription not keeping up would bury
    // the real reason, which `reason.label` already carries.
    if drops.total > 0, !reason.isFailure {
        // Not cosmetic. Dropped buffers are missing words, and a transcript
        // with a hole in it must not be handed over as if it were complete.
        sink.warning(
            "\(drops.total) audio buffer(s) were dropped because transcription"
            + " could not keep up with the microphone",
            code: "capture_overrun")
    }

    var segments: [Segment] = []
    var runError: Error?
    do {
        segments = try await session.finish()
    } catch let failure as LiveSessionFailure {
        // The transcript survives the failure. `done` must report what the run
        // actually produced, not zero segments for a session that emitted forty
        // of them and then stumbled on its last flush. The message is not also
        // emitted as a warning: it is about to be thrown, and the CLI prints
        // that.
        segments = failure.segments
        runError = SpeechError.runtime(failure.message)
    } catch {
        runError = error
    }
    // Cancel before joining. `pumpEvents` ends when the session finishes its
    // event continuation, which `AppleLiveSession` does on every path - but
    // that is an unenforced contract on a public protocol, and stage 4.2 adds
    // implementations. An await on a stream nobody finished is a hang with no
    // diagnostic; cancelling first costs nothing, because on the happy path the
    // stream has already ended.
    pumpEvents.cancel()
    _ = await pumpEvents.value

    let droppedInputs = await session.droppedInputCount()
    if droppedInputs > 0 {
        sink.warning(
            "\(droppedInputs) audio buffer(s) never reached \(model);"
            + " it could not keep up with the microphone",
            code: "session_overrun")
    }

    var abandonedRefinements = 0
    if let queue {
        // The plan's cap on the *queue*. A refine engine still working when the
        // user stops gets ten seconds of grace and then loses its place in line;
        // the count is reported rather than hidden, because a transcript missing
        // three refinements is a different artifact from a complete one.
        abandonedRefinements = await queue.drain(timeout: .seconds(10))
        if abandonedRefinements > 0 {
            sink.warning(
                "stopped with \(abandonedRefinements) utterance(s) still unrefined",
                code: "refine_incomplete")
        }
    }
    await engine.unload()
    if let refineEngine {
        // Honest about what this can cost. Cancelling the queue stops it taking
        // new work; it does not reach inside an inference already running, and
        // every engine here is an actor, so this call queues behind that
        // inference for however long it takes. Saying so beats a silent pause,
        // and a second Ctrl-C works throughout because `StopController` gave the
        // signals back to the kernel the moment the first stop was recorded.
        if abandonedRefinements > 0 {
            sink.warning(
                "waiting for '\(refineEngine.id)' to finish before releasing it;"
                + " interrupt again to give up",
                code: "refine_draining")
        }
        await refineEngine.unload()
    }

    let captureSeconds = await pump.capturedSeconds
    sink.emit(.done(.init(
        segments: segments.count,
        audioSeconds: captureSeconds,
        wallSeconds: sink.elapsed,
        peakRSSBytes: SystemInfo.peakResidentBytes(),
        peakMemoryBytes: SystemInfo.peakMemoryBytes(),
        output: nil)))

    if let runError { throw runError }
    if reason.isFailure {
        throw SpeechError.runtime("live capture stopped: \(reason.label)")
    }
}

/// About five seconds of hardware buffers. Deep enough to ride out a model
/// hiccup, shallow enough that a session which has genuinely stalled drops
/// audio and says so instead of growing a queue nobody will ever hear.
private let kCaptureQueueDepth = 64

private func printInputDevices(_ globals: GlobalOptions, _ sink: EventSink) throws {
    let devices = AudioInput.devices()
    let defaultID = AudioInput.defaultInputDeviceID()

    if globals.json {
        let payload = devices.map { device -> [String: Any] in
            [
                "name": device.name,
                "uid": device.uid,
                "channels": device.inputChannels,
                "sample_rate": device.sampleRate,
                "default": device.id == defaultID,
            ]
        }
        sink.document(try CLIHelpers.jsonString(["devices": payload], compact: true))
        return
    }

    guard !devices.isEmpty else {
        sink.text("No audio input devices.")
        return
    }
    let width = devices.map(\.name.count).max() ?? 0
    for device in devices {
        let marker = device.id == defaultID ? " (default)" : ""
        sink.text(
            device.name.padding(toLength: width, withPad: " ", startingAt: 0)
            + "  \(device.inputChannels) ch"
            + "  \(Int(device.sampleRate)) Hz"
            + marker)
    }
}
