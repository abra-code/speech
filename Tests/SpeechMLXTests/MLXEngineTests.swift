// MLXEngineTests.swift - the engine, driven against a helper that is a shell
// script.
//
// The script speaks the real protocol: it emits the handshake unprompted,
// answers `load`, consumes exactly the bytes a `transcribe` line declares
// before replying, and exits on `bye`. That is enough to test everything the
// engine decides - the order it checks things in, what it turns each failure
// into, where a chunk's timestamps end up - on a machine with no MLX, no Metal
// and no weights.
//
// Reading the payload with `dd bs=1 count=N` after the shell's own `read` is
// the part that looks odd and is not: a POSIX shell reading from a pipe or a
// socket consumes one byte at a time, so it stops at the newline and leaves the
// audio for the next reader. The buffers here are a few samples for that
// reason.

import Foundation
import Testing
import SpeechCore
import SpeechMLXProtocol
@testable import SpeechMLX

/// A helper made of `/bin/sh`, plus a model store with something in it.
private final class ScriptedHelper {
    let directory: URL
    let executable: URL
    let modelsDirectory: URL

    /// - Parameters:
    ///   - ready: the handshake line, or nil to emit none.
    ///   - replies: what to answer for `load` and for `transcribe`.
    ///   - install: catalog ids whose directories should look downloaded.
    init(
        ready: MLXResponse? = MLXEngineTests.ready,
        loaded: MLXResponse? = MLXEngineTests.loaded,
        transcribed: [MLXResponse] = MLXEngineTests.transcribed,
        install: [String] = [],
        dieAfterTranscribe: Bool = false,
        transcribeDelay: Int = 0
    ) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-engine-\(UUID().uuidString)")
        modelsDirectory = directory.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent(MLXHelperProcess.executableName)

        try write(ready.map { [$0] } ?? [], to: "ready.jsonl")
        try write(loaded.map { [$0] } ?? [], to: "loaded.jsonl")
        try write(transcribed, to: "transcribed.jsonl")

        let script = """
            #!/bin/sh
            here="$(dirname "$0")"
            cat "$here/ready.jsonl"
            while IFS= read -r line ; do
                case "$line" in
                    *'"op":"load"'*)
                        cat "$here/loaded.jsonl" ;;
                    *'"op":"transcribe"'*)
                        bytes=$(printf '%s' "$line" | sed -n 's/.*"bytes":\\([0-9]*\\).*/\\1/p')
                        id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
                        if [ -n "$bytes" ] && [ "$bytes" -gt 0 ] ; then
                            dd bs=1 count="$bytes" of=/dev/null 2>/dev/null
                        fi
                        # Every reply carries the id it is answering. A stub
                        # that always said 1 would be refused by the connection
                        # on the second request of a cut recording, which is how
                        # this line came to be here.
                        \(transcribeDelay > 0 ? "sleep \(transcribeDelay)\n                        " : "")sed "s/\\"id\\":[0-9]*/\\"id\\":${id:-1}/g" "$here/transcribed.jsonl"
                        \(dieAfterTranscribe ? "exit 0" : "") ;;
                    *'"op":"unload"'*)
                        printf '{"event":"ok","op":"unload"}\\n' ;;
                    *'"op":"bye"'*)
                        exit 0 ;;
                esac
            done
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        for id in install { try pretendInstalled(id) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A directory the store will call installed: every file the row's assets
    /// name, with nothing behind them.
    func pretendInstalled(_ catalogID: String) throws {
        let spec = try EngineSpec.parse(catalogID: catalogID, modelsDirectory: modelsDirectory)
        let row = try #require(MLXCatalog.row(model: spec.model, variant: spec.variant))
        try FileManager.default.createDirectory(at: spec.directory, withIntermediateDirectories: true)
        for asset in row.assets {
            try Data("x".utf8).write(to: spec.directory.appendingPathComponent(asset.file))
        }
    }

    func spec(_ catalogID: String) throws -> EngineSpec {
        try EngineSpec.parse(catalogID: catalogID, modelsDirectory: modelsDirectory)
    }

    private func write(_ responses: [MLXResponse], to name: String) throws {
        var data = Data()
        for response in responses { data.append(try MLXFrameWriter.frame(response)) }
        try data.write(to: directory.appendingPathComponent(name))
    }
}

private func makeEngine(
    _ helper: ScriptedHelper, id: String = "mlx.parakeet-tdt_ctc-110m", locatable: Bool = true,
    timeouts: MLXHelperConnection.Timeouts = MLXHelperConnection.Timeouts(
        handshake: 3, load: 3, control: 3, transcribeBase: 5, transcribeRealTimeFactor: 1)
) throws -> MLXEngine {
    let spec = try helper.spec(id)
    let row = try #require(MLXCatalog.row(model: spec.model, variant: spec.variant))
    let executable = helper.executable
    return MLXEngine(
        spec: spec, row: row, segmenter: EnergySegmenter(),
        // Short by default, because one of these tests is a helper that never
        // answers and the production ceiling for that is a minute.
        timeouts: timeouts,
        locate: {
            locatable
                ? .success(executable)
                : .failure(.notFound("no speech-mlx beside /nowhere"))
        })
}

@Suite("The MLX engine")
struct MLXEngineTests {
    static let ready = MLXResponse.ready(
        .init(helper: "0.1.0", mlxAudio: "0.1.3", mlxSwift: "0.31.6",
              types: ["parakeet", "whisper"], cacheMegabytes: 512))
    static let loaded = MLXResponse.loaded(
        .init(type: "parakeet", seconds: 0.13, languages: [], languageHint: false))
    static let transcribed: [MLXResponse] = [
        .segment(.init(id: 1, index: 0, start: 0.1, end: 0.4, text: "hello")),
        .segment(.init(id: 1, index: 1, start: 0.4, end: 0.6, text: "there")),
        .done(.init(id: 1, seconds: 0.02, segments: 2, synthesized: false, peakMemoryGB: 0.5)),
    ]

    // MARK: - What is checked, and in what order

    @Test("with no helper the row is unavailable, whatever the store holds")
    func noHelperIsUnavailable() async throws {
        // Deliberately with the weights present, so the answer cannot be
        // coming from the store.
        let helper = try ScriptedHelper(install: ["mlx.parakeet-tdt_ctc-110m"])
        let engine = try makeEngine(helper, locatable: false)

        do {
            _ = try await engine.prepare(language: nil) { _ in }
            Issue.record("a row with no helper should not prepare")
        } catch let error as SpeechError {
            #expect(error.code == "unavailable")
            #expect(error.message.contains("speech-mlx"))
        }
    }

    @Test("the helper is checked before the weights, so the exit code is about the build")
    func theHelperIsCheckedFirst() async throws {
        // Neither present. The useful answer is the one that applies to every
        // mlx row rather than the one that sends a user to fetch 2.5 GB for a
        // row that would still not run.
        let helper = try ScriptedHelper()
        let engine = try makeEngine(helper, locatable: false)

        do {
            _ = try await engine.prepare(language: nil) { _ in }
            Issue.record("nothing is installed and there is no helper")
        } catch let error as SpeechError {
            #expect(error.code == "unavailable", "got '\(error.message)'")
        }
    }

    @Test("with a helper and no weights, the answer is the download")
    func aMissingModelIsReportedOnceTheHelperIsThere() async throws {
        let helper = try ScriptedHelper()
        let engine = try makeEngine(helper)

        do {
            _ = try await engine.prepare(language: nil) { _ in }
            Issue.record("nothing is installed")
        } catch let error as SpeechError {
            #expect(error.code == "model_missing")
            #expect(error.message.contains("models download"))
        }
    }

    @Test("a helper that does not implement the row's type is unavailable, and says what it has")
    func anUnimplementedTypeIsUnavailable() async throws {
        let helper = try ScriptedHelper(
            ready: .ready(.init(
                helper: "0.1.0", mlxAudio: "0.1.3", mlxSwift: "0.31.6",
                types: ["sensevoice"], cacheMegabytes: 512)),
            install: ["mlx.parakeet-tdt_ctc-110m"])
        let engine = try makeEngine(helper)

        do {
            _ = try await engine.prepare(language: nil) { _ in }
            Issue.record("this helper cannot load a parakeet")
        } catch let error as SpeechError {
            #expect(error.code == "unavailable")
            #expect(error.message.contains("sensevoice"))
        }
    }

    @Test("a helper that says nothing at all is unavailable rather than hanging")
    func aSilentHelperIsReported() async throws {
        let helper = try ScriptedHelper(ready: nil, install: ["mlx.parakeet-tdt_ctc-110m"])
        let engine = try makeEngine(helper)

        // The script emits no handshake and then blocks reading stdin, which
        // is a helper that started and did not come up.
        do {
            _ = try await engine.prepare(language: nil) { _ in }
            Issue.record("no handshake arrived")
        } catch let error as SpeechError {
            // Runtime, not unavailable: the binary is there and started, so
            // "install the helper" would be the wrong advice.
            #expect(error.code == "runtime", "got '\(error.message)'")
        }
    }

    @Test("a load the helper refuses carries its reason")
    func aRefusedLoadCarriesTheReason() async throws {
        let helper = try ScriptedHelper(
            loaded: .failure(.init(op: "load", message: "no config.json in that directory")),
            install: ["mlx.parakeet-tdt_ctc-110m"])
        let engine = try makeEngine(helper)

        do {
            _ = try await engine.prepare(language: nil) { _ in }
            Issue.record("the helper refused the load")
        } catch let error as SpeechError {
            #expect(error.message.contains("no config.json"))
        }
    }

    // MARK: - Transcribing

    @Test("a prepared engine sends audio and returns the model's spans")
    func prepareThenTranscribe() async throws {
        let helper = try ScriptedHelper(install: ["mlx.parakeet-tdt_ctc-110m"])
        let engine = try makeEngine(helper)

        _ = try await engine.prepare(language: nil) { _ in }
        let segments = try await engine.transcribe(
            samples: [Float](repeating: 0.1, count: 8), options: TranscribeOptions())
        await engine.unload()

        #expect(segments.map(\.text) == ["hello", "there"])
        #expect(segments[0].start == 0.1)
        #expect(segments[1].end == 0.6)
        #expect(segments[0].id == 0)
        #expect(segments[1].id == 1)
    }

    @Test("transcribing without preparing is an error, not a crash")
    func transcribeWithoutPrepare() async throws {
        let helper = try ScriptedHelper(install: ["mlx.parakeet-tdt_ctc-110m"])
        let engine = try makeEngine(helper)

        await #expect(throws: SpeechError.self) {
            _ = try await engine.transcribe(samples: [0.1, 0.2], options: TranscribeOptions())
        }
    }

    @Test("no row streams, and the refusal names the flag to look for")
    func noRowStreams() async throws {
        let helper = try ScriptedHelper(install: ["mlx.parakeet-tdt_ctc-110m"])
        let engine = try makeEngine(helper)

        do {
            _ = try await engine.makeLiveSession(options: TranscribeOptions())
            Issue.record("the protocol has no streaming request")
        } catch let error as SpeechError {
            #expect(error.code == "unavailable")
            #expect(error.message.contains("live"))
        }
    }

    @Test("a helper that dies mid-run ends the session instead of failing every later row the same way")
    func aDeadHelperEndsTheSession() async throws {
        // A closed connection is not one buffer's problem. Leaving the runner
        // in place would fail every remaining row of a 700-row split against
        // the same dead process, which reads as "the model cannot do this
        // corpus" rather than "the helper died on row 12".
        let helper = try ScriptedHelper(
            install: ["mlx.parakeet-tdt_ctc-110m"], dieAfterTranscribe: true)
        let engine = try makeEngine(helper)

        _ = try await engine.prepare(language: nil) { _ in }
        // The stub answers the first request and then exits, so this one is
        // fine and the helper is gone by the time the next arrives.
        let first = try await engine.transcribe(samples: [0.1, 0.2], options: TranscribeOptions())
        #expect(first.count == 2)

        // The row that finds the helper gone reports what actually happened.
        do {
            _ = try await engine.transcribe(samples: [0.1, 0.2], options: TranscribeOptions())
            Issue.record("the helper is gone; this cannot have transcribed anything")
        } catch let error as SpeechError {
            #expect(error.message.contains("exited"), "got '\(error.message)'")
        }

        // And every row after it says the session is over rather than repeating
        // a connection error against a process that is not there.
        do {
            _ = try await engine.transcribe(samples: [0.1, 0.2], options: TranscribeOptions())
            Issue.record("the session ended; this cannot have transcribed anything")
        } catch let error as SpeechError {
            #expect(error.message.contains("session ended"), "got '\(error.message)'")
        }
    }

    @Test("unloading waits for a transcription that is still running")
    func unloadWaitsForAnInFlightTranscription() async throws {
        // An actor is reentrant, so this can arrive BETWEEN TWO CHUNKS of a
        // call that is still going - which is why this cuts the audio up. A
        // single-chunk call is already safe without the wait, because the
        // runner's queue puts the unload behind the request that is running;
        // what the queue cannot do is put it behind a request that has not been
        // submitted yet. Without the wait, chunk two arrives at a helper whose
        // model has just been unloaded, and every span chunk one produced is
        // thrown away with the error.
        let base = try #require(MLXCatalog.row(model: "parakeet-tdt_ctc-110m", variant: nil))
        var capped = base
        capped.maxSeconds = 1

        let helper = try ScriptedHelper(
            install: ["mlx.parakeet-tdt_ctc-110m"], transcribeDelay: 1)
        let spec = try helper.spec("mlx.parakeet-tdt_ctc-110m")
        let executable = helper.executable
        let engine = MLXEngine(
            spec: spec, row: capped, segmenter: EnergySegmenter(),
            timeouts: MLXHelperConnection.Timeouts(
                handshake: 5, load: 5, control: 5, transcribeBase: 30, transcribeRealTimeFactor: 5),
            locate: { .success(executable) })
        _ = try await engine.prepare(language: nil) { _ in }

        async let transcription = engine.transcribe(
            samples: [Float](repeating: 0.1, count: 40_000), options: TranscribeOptions())
        // Long enough to be inside the first chunk's second of sleep, and not
        // long enough to be past the last one.
        try await Task.sleep(for: .milliseconds(500))
        await engine.unload()

        let segments = try await transcription
        #expect(segments.count >= 4, "the unload cut the transcription short")
    }

    @Test("two prepares at once load once")
    func concurrentPreparesLoadOnce() async throws {
        // `prepare` is documented as idempotent - "calling it twice loads once"
        // - and nothing before its first await protects anything, so without a
        // guard both calls spawn a helper and load the weights, and whichever
        // finishes last wins. The loser is then reachable only through a deinit.
        let helper = try ScriptedHelper(install: ["mlx.parakeet-tdt_ctc-110m"])
        let engine = try makeEngine(helper)
        defer { Task { await engine.unload() } }

        async let first: String? = engine.prepare(language: nil) { _ in }
        async let second: String? = engine.prepare(language: nil) { _ in }
        _ = try await (first, second)

        #expect(await engine.helperGeneration == 1, "the weights were loaded more than once")
    }

    // MARK: - Languages

    @Test("the catalog's languages gate when the checkpoint names none")
    func theCatalogGatesWhenTheCheckpointIsSilent() async throws {
        // The NeMo configs these rows ship carry no language list, so `loaded`
        // comes back with an empty one - which means "the files do not say",
        // not "none". Falling through to the row is what keeps a wrong
        // --language from reaching the model.
        let helper = try ScriptedHelper(install: ["mlx.parakeet-tdt-0.6b-v3"])
        let engine = try makeEngine(helper, id: "mlx.parakeet-tdt-0.6b-v3")

        let resolved = try await engine.prepare(language: "pl") { _ in }
        #expect(resolved == "pl")

        await #expect(throws: SpeechError.self) {
            _ = try await engine.prepare(language: "xx") { _ in }
        }
        await engine.unload()
    }

    @Test("a row's language reaches the helper for a model whose decoder reads one")
    func aRowsLanguageReloadsTheHelper() async throws {
        // The bug this exists for. `Evaluator` prepares each distinct language
        // in a manifest up front - a validation pass - and then transcribes
        // rows in order, so whatever the last prepare loaded is what every row
        // would get. On a mixed-language corpus that means decoding the Polish
        // rows with a model told to expect English while labeling the segments
        // "pl". The failure has no symptom except a WER that looks like a
        // result.
        let helper = try ScriptedHelper(
            loaded: .loaded(.init(
                type: "whisper", seconds: 0.1, languages: [], languageHint: true)),
            install: ["mlx.whisper-large-v3-turbo"])
        let engine = try makeEngine(helper, id: "mlx.whisper-large-v3-turbo")
        defer { Task { await engine.unload() } }

        // The evaluator's up-front pass, both languages, in its order.
        _ = try await engine.prepare(language: "en") { _ in }
        _ = try await engine.prepare(language: "de") { _ in }
        #expect(await engine.loadedHelperLanguage == "en", "prepare loads once and validates")

        // Now the rows, which is where the language has to be applied.
        _ = try await engine.transcribe(
            samples: [0.1, 0.2], options: TranscribeOptions(language: "en"))
        let afterEnglish = await engine.helperGeneration
        #expect(await engine.loadedHelperLanguage == "en")

        _ = try await engine.transcribe(
            samples: [0.1, 0.2], options: TranscribeOptions(language: "de"))
        #expect(await engine.loadedHelperLanguage == "de", "the German row was decoded as English")
        #expect(await engine.helperGeneration == afterEnglish + 1)

        // And a second German row must not pay for the load again.
        let afterGerman = await engine.helperGeneration
        _ = try await engine.transcribe(
            samples: [0.1, 0.2], options: TranscribeOptions(language: "de"))
        #expect(await engine.helperGeneration == afterGerman)
    }

    @Test("a model whose decoder ignores the hint is not reloaded for a new language")
    func aModelThatIgnoresTheHintIsNotReloaded() async throws {
        // Parakeet's `generate` does not read one - it answers
        // `language_hint: false` - so a reload would cost a multi-second weight
        // load and change nothing about the transcript.
        let helper = try ScriptedHelper(
            loaded: .loaded(.init(
                type: "parakeet", seconds: 0.1, languages: [], languageHint: false)),
            install: ["mlx.parakeet-tdt-0.6b-v3"])
        let engine = try makeEngine(helper, id: "mlx.parakeet-tdt-0.6b-v3")
        defer { Task { await engine.unload() } }

        _ = try await engine.prepare(language: "en") { _ in }
        let before = await engine.helperGeneration
        _ = try await engine.transcribe(
            samples: [0.1, 0.2], options: TranscribeOptions(language: "pl"))
        #expect(await engine.helperGeneration == before)
    }

    @Test("a long recording is cut, and the second chunk's timestamps are not the first's")
    func aCutRecordingIsPutBackTogether() async throws {
        // Every shipped row has a ceiling now; this builds a two-second one so
        // the cut happens on a buffer a test can hold. The path it exercises -
        // more than one request per call, ids that keep counting, spans offset
        // into the recording - is the one every row takes on a recording longer
        // than its ceiling.
        let base = try #require(MLXCatalog.row(model: "parakeet-tdt_ctc-110m", variant: nil))
        var capped = base
        capped.maxSeconds = 1

        let helper = try ScriptedHelper(install: ["mlx.parakeet-tdt_ctc-110m"])
        let spec = try helper.spec("mlx.parakeet-tdt_ctc-110m")
        let executable = helper.executable
        let engine = MLXEngine(
            spec: spec, row: capped, segmenter: EnergySegmenter(),
            timeouts: MLXHelperConnection.Timeouts(
                handshake: 3, load: 3, control: 3, transcribeBase: 5, transcribeRealTimeFactor: 1),
            locate: { .success(executable) })

        _ = try await engine.prepare(language: nil) { _ in }
        // Two and a half seconds at a one-second ceiling: three requests.
        let segments = try await engine.transcribe(
            samples: [Float](repeating: 0.1, count: 40_000), options: TranscribeOptions())
        await engine.unload()

        // The stub answers every request with the same two spans, at 0.1-0.4
        // and 0.4-0.6 of whatever buffer it was given. So every span past the
        // second is only where it is because it was offset, and any span
        // sitting back at 0.1 would be a chunk whose timestamps were left
        // belonging to the first piece of audio.
        //
        // How many chunks there are is the segmenter's business - it cuts at
        // the quietest point near the ceiling, not at the ceiling - so this
        // asserts the shape rather than a count it does not control.
        #expect(segments.count >= 4, "2.5 s at a 1 s ceiling is more than one request")
        #expect(segments.count % 2 == 0, "two spans per request")
        #expect(segments.map(\.id) == Array(0..<segments.count), "ids run on across chunks")
        #expect(segments[0].start == 0.1)
        #expect(segments.map(\.start) == segments.map(\.start).sorted(), "spans went backwards")
        #expect(segments[2].start > segments[1].start, "the second chunk was not offset")
        let last = try #require(segments.last)
        #expect(last.start > 1.0, "nothing was placed past the first chunk")
    }

    @Test("what the checkpoint does name wins over the row")
    func theCheckpointWinsWhenItSpeaks() async throws {
        let helper = try ScriptedHelper(
            loaded: .loaded(.init(
                type: "parakeet", seconds: 0.1, languages: ["en"], languageHint: false)),
            install: ["mlx.parakeet-tdt-0.6b-v3"])
        let engine = try makeEngine(helper, id: "mlx.parakeet-tdt-0.6b-v3")

        // The row claims 25 languages and these weights admit to one, so a
        // request for Polish is refused even though the catalog lists it.
        await #expect(throws: SpeechError.self) {
            _ = try await engine.prepare(language: "pl") { _ in }
        }
        await engine.unload()
    }
}
