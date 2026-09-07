// MLXHelperConnectionTests.swift - the `speech` side of the protocol, driven
// against a stub that speaks it.
//
// No MLX here, and deliberately so: everything the supervisor can get wrong is
// reachable over a socket pair with a responder in this process, and a test
// that needed a GPU would not run on the machine that most needs it to.
//
// The one that matters most is `aLargeBufferDoesNotDeadlock`. A helper writing
// to a full stderr pipe stops reading its stdin, and a caller that is blocked
// writing audio to that stdin will wait for it forever. The stub in that test
// writes stderr while the audio is still arriving, which is exactly what the
// real helper does when a model logs during a load, and which is the reason
// this class services every descriptor from one poll rather than writing first
// and reading afterwards.

import Foundation
import Testing
@testable import SpeechMLX
import SpeechMLXProtocol

// MARK: - A helper that is not a helper

/// The other end of the conversation, running on its own thread.
///
/// It uses the same framing code the real helper uses, so a test that passes
/// here is a test against the format rather than against a second opinion of
/// what the format is.
final class StubHelper: @unchecked Sendable {
    typealias Handler = @Sendable (MLXRequest, Data) -> [MLXResponse]

    /// Descriptors to hand the connection under test.
    let clientRead: Int32
    let clientWrite: Int32
    let clientError: Int32

    private let serverRead: Int32
    private var serverWrite: Int32
    private var serverError: Int32
    private let handler: Handler
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    /// Guards the two descriptors the stub writes to. Both the test thread and
    /// the stub thread close them, and closing a descriptor twice in a process
    /// that keeps opening new ones is how a test starts writing into somebody
    /// else's file.
    private let outputs = NSLock()

    /// Bytes written to stderr for every request received, to model a library
    /// that logs while it works.
    var noisePerRequest = 0

    init(handler: @escaping Handler) {
        var requests: [Int32] = [-1, -1]
        var responses: [Int32] = [-1, -1]
        var diagnostics: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &requests) == 0)
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &responses) == 0)
        precondition(pipe(&diagnostics) == 0)
        clientWrite = requests[0]
        serverRead = requests[1]
        clientRead = responses[0]
        serverWrite = responses[1]
        clientError = diagnostics[0]
        serverError = diagnostics[1]
        self.handler = handler
    }

    /// Puts bytes in front of the connection before it reads anything, for the
    /// cases where no request is needed to provoke the answer.
    func preload(_ data: Data) {
        write(data, to: \.serverWrite)
    }

    func preload(_ responses: [MLXResponse]) {
        for response in responses {
            preload(try! MLXFrameWriter.frame(response))
        }
    }

    func preloadStandardError(_ text: String) {
        write(Data(text.utf8), to: \.serverError)
    }

    /// Closes the stub's end of the response channel, which is what a helper
    /// that exited looks like from the other side.
    func hangUp() {
        outputs.lock()
        defer { outputs.unlock() }
        if serverWrite >= 0 { close(serverWrite); serverWrite = -1 }
        if serverError >= 0 { close(serverError); serverError = -1 }
    }

    func start() {
        let thread = Thread { [self] in
            var decoder = MLXFrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            reading: while true {
                let count = buffer.withUnsafeMutableBytes {
                    read(serverRead, $0.baseAddress, $0.count)
                }
                if count <= 0 { break }
                let batch = buffer.withUnsafeBytes {
                    decoder.push(Data(bytes: $0.baseAddress!, count: count))
                }
                for frame in batch.frames {
                    guard let request = try? MLXWire.decoder().decode(MLXRequest.self, from: frame.line)
                    else { continue }
                    if noisePerRequest > 0 {
                        write(Data(repeating: UInt8(ascii: "n"), count: noisePerRequest), to: \.serverError)
                    }
                    if case .bye = request { break reading }
                    for response in handler(request, frame.payload) {
                        write(try! MLXFrameWriter.frame(response), to: \.serverWrite)
                    }
                }
                if batch.failure != nil { break }
            }
            hangUp()
            finished.signal()
        }
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    func stop() {
        close(serverRead)
        if thread != nil { _ = finished.wait(timeout: .now() + 5) }
        hangUp()
    }

    private func write(_ data: Data, to descriptor: KeyPath<StubHelper, Int32>) {
        outputs.lock()
        defer { outputs.unlock() }
        let target = self[keyPath: descriptor]
        guard target >= 0 else { return }
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(target, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if count <= 0 { return }
                sent += count
            }
        }
    }
}

private func makeConnection(
    _ stub: StubHelper,
    timeouts: MLXHelperConnection.Timeouts = MLXHelperConnection.Timeouts(
        handshake: 5, load: 5, control: 5, transcribeBase: 10, transcribeRealTimeFactor: 1),
    tailLimit: Int = 16 << 10
) -> MLXHelperConnection {
    MLXHelperConnection(
        readFD: stub.clientRead, writeFD: stub.clientWrite, errorFD: stub.clientError,
        timeouts: timeouts, tailLimit: tailLimit)
}

private let ready = MLXResponse.ready(
    .init(helper: "0.1.0", mlxAudio: "0.1.3", mlxSwift: "0.31.6", types: ["parakeet", "whisper"]))

// MARK: - Tests

@Suite("Talking to speech-mlx")
struct MLXHelperConnectionTests {
    @Test("the handshake is the first line, and it carries the pins")
    func handshakeIsTheFirstLine() throws {
        let stub = StubHelper { _, _ in [] }
        stub.preload([ready])
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        let hello = try connection.handshake()
        #expect(hello.helper == "0.1.0")
        #expect(hello.mlxAudio == "0.1.3")
        #expect(hello.types.contains("parakeet"))
    }

    @Test("a helper that fails at startup is refused, not misread")
    func startupFailureIsRefused() throws {
        let stub = StubHelper { _, _ in [] }
        stub.preload([.failure(.init(op: "startup", message: "no default.metallib"))])
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        #expect(throws: MLXHelperError.refused(op: "startup", message: "no default.metallib")) {
            try connection.handshake()
        }
    }

    @Test("a helper that says nothing times out rather than hanging")
    func silenceTimesOut() throws {
        let stub = StubHelper { _, _ in [] }
        let connection = makeConnection(
            stub, timeouts: .init(handshake: 0.2, load: 1, control: 1))
        defer { connection.close(); stub.stop() }

        let started = Date()
        #expect(throws: MLXHelperError.self) { try connection.handshake() }
        let waited = Date().timeIntervalSince(started)
        // Both bounds. The upper one says the deadline fires at all; the lower
        // one says it fires because of the deadline rather than because
        // something else gave up immediately, which an upper bound alone would
        // accept.
        #expect(waited >= 0.15, "returned after \(waited)s, which is not a 0.2s deadline")
        #expect(waited < 3)
    }

    @Test("a helper that exits without a word says so, with what it last printed")
    func exitCarriesTheStandardErrorTail() throws {
        let stub = StubHelper { _, _ in [] }
        stub.preloadStandardError("dyld: Library not loaded: @rpath/libMLX.dylib\n")
        stub.hangUp()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        do {
            _ = try connection.handshake()
            Issue.record("a closed connection should not produce a handshake")
        } catch let error as MLXHelperError {
            guard case .closed(let message) = error else {
                Issue.record("expected a closed connection, got \(error)")
                return
            }
            #expect(message.contains("libMLX.dylib"))
        }
    }

    @Test("the stderr tail is bounded, and says when it dropped the beginning")
    func standardErrorTailIsBounded() throws {
        let stub = StubHelper { _, _ in [] }
        // Written before the hang-up so it is all readable in one drain.
        stub.preloadStandardError(String(repeating: "a", count: 4096) + String(repeating: "b", count: 4096))
        stub.hangUp()
        let connection = makeConnection(stub, tailLimit: 1024)
        defer { connection.close(); stub.stop() }

        #expect(throws: MLXHelperError.self) { try connection.handshake() }
        let tail = connection.standardErrorTail
        #expect(tail.count <= 1024 + 4)
        #expect(tail.hasPrefix("... "))
        #expect(tail.hasSuffix("b"))
    }

    // MARK: - Transcribing

    @Test("audio goes out as declared and the segments come back in order")
    func transcribeRoundTrip() throws {
        let audio = (0..<16000).map { Float($0) / 16000 }
        let stub = StubHelper { request, payload in
            guard case .transcribe(let ask) = request else { return [] }
            // The stub checks the same invariant the helper checks, because a
            // supervisor that declares the wrong length is the failure this
            // field exists to catch.
            guard ask.bytes == ask.samples * 4, payload.count == ask.bytes,
                  let samples = MLXFrameWriter.samples(from: payload), samples.count == audio.count,
                  samples.first == audio.first, samples.last == audio.last
            else {
                return [.failure(.init(op: "transcribe", id: ask.id, message: "payload mismatch"))]
            }
            return [
                .segment(.init(id: ask.id, index: 0, start: 0, end: 0.5, text: "one")),
                .segment(.init(id: ask.id, index: 1, start: 0.5, end: 1.0, text: "two")),
                .done(.init(id: ask.id, seconds: 0.02, segments: 2, synthesized: false, peakMemoryGB: 1.25)),
            ]
        }
        stub.preload([ready])
        stub.start()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        _ = try connection.handshake()
        var texts: [String] = []
        let done = try connection.transcribe(id: 1, samples: audio, chunkSeconds: 30) {
            texts.append($0.text)
        }
        #expect(texts == ["one", "two"])
        #expect(done.segments == 2)
        #expect(done.synthesized == false)
        #expect(done.peakMemoryGB == 1.25)
    }

    @Test("a buffer larger than every pipe in the path does not deadlock")
    func aLargeBufferDoesNotDeadlock() throws {
        // Four megabytes: far past a socket buffer, so the write cannot finish
        // in one go and has to be interleaved with reading.
        let audio = [Float](repeating: 0.25, count: 1 << 20)
        let stub = StubHelper { request, payload in
            guard case .transcribe(let ask) = request, payload.count == ask.bytes else {
                return [.failure(.init(op: "transcribe", message: "short payload"))]
            }
            return [.done(.init(id: ask.id, seconds: 1, segments: 0, synthesized: true))]
        }
        // And it writes a megabyte of log lines while doing it, which is what
        // fills the stderr pipe and stops a naive helper from reading its stdin.
        stub.noisePerRequest = 1 << 20
        stub.preload([ready])
        stub.start()
        let connection = makeConnection(stub, tailLimit: 4096)
        defer { connection.close(); stub.stop() }

        _ = try connection.handshake()
        let done = try connection.transcribe(id: 4, samples: audio) { _ in }
        #expect(done.id == 4)
        #expect(done.synthesized)
    }

    @Test("a dropped segment event is caught by the count, not turned into a short transcript")
    func aDroppedSegmentIsCaught() throws {
        let stub = StubHelper { request, _ in
            guard case .transcribe(let ask) = request else { return [] }
            return [
                .segment(.init(id: ask.id, index: 0, start: 0, end: 1, text: "one")),
                .done(.init(id: ask.id, seconds: 0.1, segments: 2, synthesized: false)),
            ]
        }
        stub.start()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        #expect(throws: MLXHelperError.self) {
            try connection.transcribe(id: 1, samples: [0.1, 0.2]) { _ in }
        }
    }

    @Test("a segment out of order is a protocol violation")
    func anOutOfOrderSegmentIsCaught() throws {
        let stub = StubHelper { request, _ in
            guard case .transcribe(let ask) = request else { return [] }
            return [.segment(.init(id: ask.id, index: 1, start: 0, end: 1, text: "second first"))]
        }
        stub.start()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        do {
            _ = try connection.transcribe(id: 1, samples: [0.1]) { _ in }
            Issue.record("an index of 1 where 0 was expected should not be accepted")
        } catch let error as MLXHelperError {
            guard case .protocolViolation = error else {
                Issue.record("expected a protocol violation, got \(error)")
                return
            }
        }
    }

    @Test("a segment belonging to another request is a protocol violation")
    func aSegmentForAnotherRequestIsCaught() throws {
        // The index would line up - a foreign request's first segment is also
        // index 0 - so the id is the only thing that catches this, and a
        // transcript assembled out of two requests' segments is a plausible
        // transcript of neither.
        let stub = StubHelper { request, _ in
            guard case .transcribe = request else { return [] }
            return [.segment(.init(id: 99, index: 0, start: 0, end: 1, text: "not yours"))]
        }
        stub.start()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        do {
            _ = try connection.transcribe(id: 1, samples: [0.1]) { _ in }
            Issue.record("a segment for request 99 should not be accepted during request 1")
        } catch let error as MLXHelperError {
            guard case .protocolViolation = error else {
                Issue.record("expected a protocol violation, got \(error)")
                return
            }
        }
    }

    @Test("a reply belonging to another request is a protocol violation")
    func aReplyForAnotherRequestIsCaught() throws {
        let stub = StubHelper { request, _ in
            guard case .transcribe = request else { return [] }
            return [.done(.init(id: 99, seconds: 0.1, segments: 0, synthesized: true))]
        }
        stub.start()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        #expect(throws: MLXHelperError.self) {
            try connection.transcribe(id: 1, samples: [0.1]) { _ in }
        }
    }

    @Test("one refused buffer does not end the session")
    func aRefusalLeavesTheSessionUsable() throws {
        let stub = StubHelper { request, _ in
            guard case .transcribe(let ask) = request else { return [] }
            if ask.id == 1 {
                return [.failure(.init(op: "transcribe", id: 1, message: "generation failed"))]
            }
            return [.done(.init(id: ask.id, seconds: 0.1, segments: 0, synthesized: true))]
        }
        stub.start()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        #expect(throws: MLXHelperError.refused(op: "transcribe", message: "generation failed")) {
            try connection.transcribe(id: 1, samples: [0.1]) { _ in }
        }
        // The whole reason `error` is not fatal: a 700-row split should lose
        // the row that failed and keep the other 699.
        let done = try connection.transcribe(id: 2, samples: [0.1]) { _ in }
        #expect(done.id == 2)
    }

    // MARK: - load and unload

    @Test("load reports what the helper resolved")
    func loadReportsTheResolvedType() throws {
        let stub = StubHelper { request, _ in
            guard case .load(let ask) = request else { return [] }
            #expect(ask.directory == "/models/mlx/parakeet-tdt-0.6b-v3")
            return [.loaded(.init(type: "parakeet", seconds: 0.13, languages: ["en"], languageHint: false))]
        }
        stub.start()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        let loaded = try connection.load(
            directory: URL(fileURLWithPath: "/models/mlx/parakeet-tdt-0.6b-v3"))
        #expect(loaded.type == "parakeet")
        #expect(loaded.languageHint == false)
    }

    @Test("a load that fails carries the helper's own reason")
    func loadFailureCarriesTheReason() throws {
        let stub = StubHelper { _, _ in
            [.failure(.init(op: "load", message: "no config.json in /models/mlx/whisper"))]
        }
        stub.start()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        do {
            _ = try connection.load(directory: URL(fileURLWithPath: "/models/mlx/whisper"))
            Issue.record("a load of a directory with no config should fail")
        } catch let error as MLXHelperError {
            #expect("\(error)".contains("config.json"))
        }
    }

    @Test("unload wants its ok, and checks which request it names")
    func unloadWantsItsOwnOk() throws {
        let stub = StubHelper { request, _ in
            guard case .unload = request else { return [] }
            return [.ok(.init(op: "load"))]
        }
        stub.start()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        #expect(throws: MLXHelperError.self) { try connection.unload() }
    }

    // MARK: - Malformed input

    @Test("a line that is not a response is a protocol violation, not a crash")
    func garbageIsAProtocolViolation() throws {
        let stub = StubHelper { _, _ in [] }
        stub.preload(Data("this is not json\n".utf8))
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        do {
            _ = try connection.handshake()
            Issue.record("a line of prose should not decode as a response")
        } catch let error as MLXHelperError {
            guard case .protocolViolation = error else {
                Issue.record("expected a protocol violation, got \(error)")
                return
            }
        }
    }

    @Test("a response that claims a payload is refused")
    func aResponseWithAPayloadIsRefused() throws {
        // Responses never carry one, so a line declaring `bytes` would make the
        // reader swallow the next four bytes as audio and then read the stream
        // one message out of step for the rest of the session.
        let stub = StubHelper { _, _ in [] }
        var line = Data(#"{"event":"ok","op":"unload","bytes":4}"#.utf8)
        line.append(0x0A)
        line.append(contentsOf: [0, 0, 0, 0])
        stub.preload(line)
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        do {
            _ = try connection.handshake()
            Issue.record("a response with a payload should be refused")
        } catch let error as MLXHelperError {
            guard case .protocolViolation(let message) = error else {
                Issue.record("expected a protocol violation, got \(error)")
                return
            }
            #expect(message.contains("payload"))
        }
    }

    @Test("a stream that ends mid-frame is reported as broken, not as an exit")
    func aTruncatedStreamIsReported() throws {
        let stub = StubHelper { _, _ in [] }
        stub.preload(Data(#"{"event":"ok","op":"unl"#.utf8))  // no newline
        stub.hangUp()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        do {
            _ = try connection.handshake()
            Issue.record("a truncated line should not decode")
        } catch let error as MLXHelperError {
            guard case .protocolViolation = error else {
                Issue.record("expected a protocol violation, got \(error)")
                return
            }
        }
    }

    @Test("a deadline built from a nonsense number does not take the process down")
    func absurdDeadlinesAreSurvivable() throws {
        // `Timeouts` is public and its fields are plain Doubles, so these are
        // values a caller can hand over. The first version of Deadline crashed
        // on every one of them: Double(UInt64.max - now) rounds up to exactly
        // 2^64, and converting that back is a trap rather than a big number.
        for seconds in [Double.infinity, .nan, .greatestFiniteMagnitude, -1, 0, 1e300] {
            let deadline = Deadline(seconds: seconds)
            #expect(deadline.millisecondsRemaining >= 0)
        }
        // And the two ends still mean what they say.
        #expect(Deadline(seconds: 0).hasPassed)
        #expect(!Deadline(seconds: .infinity).hasPassed)
        #expect(Deadline(seconds: .infinity).millisecondsRemaining == Int32.max)
    }

    @Test("closing the request side still leaves the helper's last words readable")
    func aClosedRequestSideStillReads() throws {
        // `bye` closes stdin, and the documented reason for reading on is that
        // a helper may answer something on its way out.
        let stub = StubHelper { _, _ in [] }
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        connection.closeRequests()
        stub.preload([ready])
        let hello = try connection.handshake()
        #expect(hello.helper == "0.1.0")
    }

    @Test("a connection reports itself finished once there is nothing left to read")
    func finishedMeansFinished() throws {
        let stub = StubHelper { _, _ in [] }
        stub.preload([ready])
        stub.hangUp()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        #expect(!connection.isFinished, "nothing has been read yet")
        _ = try connection.handshake()
        #expect(throws: MLXHelperError.self) { try connection.unload() }
        #expect(connection.isFinished)
    }

    @Test("the frames decoded before a break are still delivered")
    func goodFramesSurviveABreak() throws {
        let stub = StubHelper { _, _ in [] }
        stub.preload([ready])
        stub.preload(Data(#"{"event":"ok","op":"unl"#.utf8))
        stub.hangUp()
        let connection = makeConnection(stub)
        defer { connection.close(); stub.stop() }

        // The handshake is complete and correct, and it arrived before the
        // stream went wrong. Reporting the break first would lose the one line
        // that says which build this is.
        let hello = try connection.handshake()
        #expect(hello.helper == "0.1.0")
    }
}
