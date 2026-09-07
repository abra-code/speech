// MLXHelperConnection.swift - the `speech` side of docs/mlx-helper.md.
//
// One conversation over three descriptors: requests out, responses in, and the
// helper's stderr drained alongside them. It knows nothing about processes -
// MLXHelperProcess spawns one and hands the descriptors over - so the whole
// protocol is testable against a responder in this process, over a socket pair,
// with no MLX, no Metal and no GPU.
//
// WHY ONE POLL LOOP AND NOT THREE. A helper writing to a full pipe blocks, and
// a caller that is itself blocked writing has produced a deadlock that only a
// timeout gets out of. That is not hypothetical here: the helper's stderr
// carries whatever the MLX libraries print, including a tokenizer being
// synthesized during `load`, and its stdout carries a segment event per span.
// So every descriptor is serviced by the same `poll` - the write side included,
// which is why they are all non-blocking. Nothing here ever waits on one
// descriptor while another has bytes to give.

import Foundation
import SpeechMLXProtocol

public final class MLXHelperConnection {
    /// How long each exchange may take, in total, before the caller is told the
    /// helper is not answering.
    ///
    /// TOTAL, not a gap between events: `transcribe` sets one deadline before
    /// it writes and every segment event is read against that same deadline, so
    /// a helper that emits a span a second forever still stops. An earlier
    /// version of this comment called these "ceilings on silence", which is a
    /// nicer property and not the one implemented - and a per-event timer would
    /// have no answer for the helper that never finishes but never goes quiet.
    ///
    /// Nothing is measured against them and no row is failed for being slow in
    /// any sense the numbers below can notice: the transcription ceiling is
    /// thirty times the audio duration, against a measured cost of about one
    /// hundredth of it.
    public struct Timeouts: Sendable, Equatable {
        /// The handshake is emitted after a real MLX operation, which on a cold
        /// build includes Metal compiling and caching its kernels - measured at
        /// 2.9 s here for the first run after a build, against 0.05 s warm.
        public var handshake: Double
        /// Reading weights off disk. Generous because a 1.7B model on a cold
        /// page cache is disk-bound and a user who has just downloaded 3 GB is
        /// exactly the person whose page cache is cold.
        public var load: Double
        /// `unload` and any other request that only has to answer `ok`.
        public var control: Double
        /// Transcription is allowed `base` plus `realTimeFactor` seconds per
        /// second of audio. A fixed ceiling would either fail long buffers or
        /// be useless on short ones; the measured warm figure for Parakeet here
        /// is about 0.01 s per second of audio, so a factor of 30 is three
        /// thousand times the observed cost and still bounded.
        public var transcribeBase: Double
        public var transcribeRealTimeFactor: Double

        public init(
            handshake: Double = 60,
            load: Double = 600,
            control: Double = 30,
            transcribeBase: Double = 120,
            transcribeRealTimeFactor: Double = 30
        ) {
            self.handshake = handshake
            self.load = load
            self.control = control
            self.transcribeBase = transcribeBase
            self.transcribeRealTimeFactor = transcribeRealTimeFactor
        }
    }

    public let timeouts: Timeouts

    private var readFD: Int32
    private var writeFD: Int32
    private var errorFD: Int32

    private var decoder = MLXFrameDecoder()
    private var pending: [MLXFrame] = []
    private var readEnded = false
    /// A framing failure found while draining the last bytes of a dead helper.
    /// Held rather than thrown, so that the frames decoded before it are still
    /// delivered - the reason the helper stopped is usually in them.
    private var endFailure: MLXProtocolError?
    private var tail: BoundedTail
    private var scratch: [UInt8]

    /// Takes ownership of all three descriptors. `errorFD` may be -1 when there
    /// is no separate stderr to drain, which is what an in-process test over a
    /// socket pair uses.
    public init(
        readFD: Int32,
        writeFD: Int32,
        errorFD: Int32 = -1,
        timeouts: Timeouts = Timeouts(),
        tailLimit: Int = 16 << 10,
        readChunk: Int = 64 << 10
    ) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.errorFD = errorFD
        self.timeouts = timeouts
        self.tail = BoundedTail(limit: tailLimit)
        self.scratch = [UInt8](repeating: 0, count: max(1, readChunk))
        for descriptor in [readFD, writeFD, errorFD] where descriptor >= 0 {
            let flags = fcntl(descriptor, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }
    }

    deinit { close() }

    /// What the helper last wrote to stderr, trimmed and bounded.
    public var standardErrorTail: String { tail.text }

    /// True once the helper's output has ended. A connection in this state
    /// answers nothing further.
    public var isFinished: Bool { readEnded && pending.isEmpty }

    public func close() {
        for descriptor in [readFD, writeFD, errorFD] where descriptor >= 0 {
            Darwin.close(descriptor)
        }
        readFD = -1
        writeFD = -1
        errorFD = -1
    }

    /// Closes only the request side, which is the helper's other stop signal:
    /// end of stdin means exit. Reading continues, so a helper that answers
    /// something on its way out is still heard.
    public func closeRequests() {
        guard writeFD >= 0 else { return }
        Darwin.close(writeFD)
        writeFD = -1
    }

    // MARK: - The conversation

    /// Reads the unprompted `ready` line. Anything else - including a helper
    /// that exits without a word - is what makes the engine unavailable.
    public func handshake() throws -> MLXResponse.Ready {
        let deadline = Deadline(seconds: timeouts.handshake)
        let response = try nextResponse(deadline: deadline, what: "the handshake")
        switch response {
        case .ready(let ready):
            return ready
        case .failure(let failure):
            throw MLXHelperError.refused(op: failure.op, message: failure.message)
        default:
            throw MLXHelperError.protocolViolation(
                "the first line was '\(response.event)' rather than 'ready'")
        }
    }

    public func load(directory: URL, type: String? = nil, language: String? = nil) throws
        -> MLXResponse.Loaded
    {
        let request = MLXRequest.load(MLXRequest.Load(
            directory: directory.path, type: type, language: language))
        let deadline = Deadline(seconds: timeouts.load)
        try send(request, deadline: deadline, what: "load")
        let response = try nextResponse(deadline: deadline, what: "load")
        switch response {
        case .loaded(let loaded):
            return loaded
        case .failure(let failure):
            // The failure's own op, not "load": the helper names `startup`,
            // `framing` and `request` for failures that belong to no request,
            // and relabeling one of those as a load failure hides which half of
            // the conversation broke.
            throw MLXHelperError.refused(op: failure.op, message: failure.message)
        default:
            throw MLXHelperError.protocolViolation(
                "answered load with '\(response.event)'")
        }
    }

    /// One buffer in, its segments out.
    ///
    /// `onSegment` is called as each event arrives rather than after the fact,
    /// so a caller that wants to stream has the option; the returned `done` is
    /// still the authority on how many there were, and a disagreement between
    /// the two is a protocol violation rather than a short transcript.
    @discardableResult
    public func transcribe(
        id: Int,
        samples: [Float],
        chunkSeconds: Double? = nil,
        maxTokens: Int? = nil,
        onSegment: (MLXResponse.SegmentEvent) throws -> Void
    ) throws -> MLXResponse.Done {
        let bytes = samples.count * MemoryLayout<Float>.size
        let request = MLXRequest.transcribe(MLXRequest.Transcribe(
            id: id, samples: samples.count, bytes: bytes,
            chunkSeconds: chunkSeconds, maxTokens: maxTokens))
        let seconds = Double(samples.count) / 16000
        let deadline = Deadline(
            seconds: timeouts.transcribeBase + timeouts.transcribeRealTimeFactor * seconds)

        try send(request, samples: samples, deadline: deadline, what: "transcribe")

        var seen = 0
        while true {
            let response = try nextResponse(deadline: deadline, what: "transcribe")
            switch response {
            case .segment(let event):
                guard event.id == id else {
                    throw MLXHelperError.protocolViolation(
                        "a segment for request \(event.id) arrived during request \(id)")
                }
                // The helper numbers its events 0, 1, 2 within a request. The
                // check is not pedantry: this is the only place a dropped or
                // reordered event can be caught, and the failure it prevents is
                // a transcript that is quietly missing a sentence.
                guard event.index == seen else {
                    throw MLXHelperError.protocolViolation(
                        "segment index \(event.index) arrived where \(seen) was expected")
                }
                seen += 1
                try onSegment(event)
            case .done(let done):
                guard done.id == id else {
                    throw MLXHelperError.protocolViolation(
                        "done for request \(done.id) arrived during request \(id)")
                }
                guard done.segments == seen else {
                    throw MLXHelperError.protocolViolation(
                        "done says \(done.segments) segments after sending \(seen)")
                }
                return done
            case .failure(let failure):
                guard failure.id == nil || failure.id == id else {
                    throw MLXHelperError.protocolViolation(
                        "an error for request \(failure.id.map(String.init) ?? "none")"
                            + " arrived during request \(id)")
                }
                throw MLXHelperError.refused(op: failure.op, message: failure.message)
            default:
                throw MLXHelperError.protocolViolation(
                    "answered transcribe with '\(response.event)'")
            }
        }
    }

    public func unload() throws {
        let deadline = Deadline(seconds: timeouts.control)
        try send(.unload, deadline: deadline, what: "unload")
        let response = try nextResponse(deadline: deadline, what: "unload")
        switch response {
        case .ok(let ok):
            guard ok.op == "unload" else {
                throw MLXHelperError.protocolViolation("ok names '\(ok.op)' after unload")
            }
        case .failure(let failure):
            throw MLXHelperError.refused(op: failure.op, message: failure.message)
        default:
            throw MLXHelperError.protocolViolation("answered unload with '\(response.event)'")
        }
    }

    /// Asks the helper to stop and closes the request side behind it. There is
    /// no reply to wait for: `bye` is the one request that does not answer,
    /// because the answer would be the process exiting.
    public func sayGoodbye() throws {
        defer { closeRequests() }
        try send(.bye, deadline: Deadline(seconds: timeouts.control), what: "bye")
    }

    // MARK: - Writing

    private func send(
        _ request: MLXRequest, samples: [Float]? = nil, deadline: Deadline, what: String
    ) throws {
        guard writeFD >= 0 else {
            throw MLXHelperError.closed(closedMessage("the request side is already closed"))
        }
        var line = try wireLine(request)
        line.append(0x0A)
        try line.withUnsafeBytes { try writeAll($0, deadline: deadline, what: what) }
        if let samples, !samples.isEmpty {
            // Written straight out of the array rather than through
            // MLXFrameWriter.payload: a whole evaluation split goes through
            // here, and the copy that call makes is the size of the audio.
            try samples.withUnsafeBytes { try writeAll($0, deadline: deadline, what: what) }
        }
    }

    private func wireLine(_ request: MLXRequest) throws -> Data {
        do {
            return try MLXWire.line(request)
        } catch {
            throw MLXHelperError.protocolViolation("could not encode a \(request.op) request: \(error)")
        }
    }

    private func writeAll(
        _ buffer: UnsafeRawBufferPointer, deadline: Deadline, what: String
    ) throws {
        var sent = 0
        while sent < buffer.count {
            try service(writing: buffer, sent: &sent, deadline: deadline, what: what)
        }
    }

    // MARK: - Reading

    private func nextResponse(deadline: Deadline, what: String) throws -> MLXResponse {
        while true {
            if !pending.isEmpty {
                return try decode(pending.removeFirst())
            }
            if readEnded {
                if let failure = endFailure {
                    throw MLXHelperError.protocolViolation(
                        "\(failure.description)\(tailSuffix())")
                }
                throw MLXHelperError.closed(closedMessage("it exited during \(what)"))
            }
            var ignored = 0
            try service(writing: nil, sent: &ignored, deadline: deadline, what: what)
        }
    }

    private func decode(_ frame: MLXFrame) throws -> MLXResponse {
        guard frame.payload.isEmpty else {
            throw MLXHelperError.protocolViolation(
                "a response declared \(frame.payload.count) bytes of payload; responses carry none")
        }
        do {
            return try MLXWire.decoder().decode(MLXResponse.self, from: frame.line)
        } catch {
            // Both halves matter, and the second one was added because it was
            // missing when it was needed: the line alone leaves the reader to
            // spot what changed, while `DecodingError` names the key. A helper
            // built before a field was added fails here, and "keyNotFound
            // cache_mb" is the difference between a rebuild and an afternoon.
            let text = String(decoding: frame.line.prefix(200), as: UTF8.self)
            throw MLXHelperError.protocolViolation(
                "could not read a response: \(text) - \(error)")
        }
    }

    // MARK: - The loop

    /// One turn: wait until something can move, then move all of it.
    ///
    /// Every descriptor is offered to the same `poll`, and stderr is drained
    /// before the response side is read. That order is deliberate - when a
    /// helper dies, the reason is on stderr and the only symptom on stdout is
    /// the end of it, so draining stderr first means the message is already in
    /// hand when the closure is reported.
    private func service(
        writing outgoing: UnsafeRawBufferPointer?,
        sent: inout Int,
        deadline: Deadline,
        what: String
    ) throws {
        var fds: [pollfd] = []
        var readSlot = -1
        var errorSlot = -1
        var writeSlot = -1

        if readFD >= 0 && !readEnded {
            fds.append(pollfd(fd: readFD, events: Int16(POLLIN), revents: 0))
            readSlot = fds.count - 1
        }
        if errorFD >= 0 {
            fds.append(pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0))
            errorSlot = fds.count - 1
        }
        let wantsWrite = outgoing.map { sent < $0.count } ?? false
        if wantsWrite, writeFD >= 0 {
            fds.append(pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0))
            writeSlot = fds.count - 1
        }
        guard !fds.isEmpty else {
            // Nothing left that could make progress. Reached when the helper's
            // output has ended and there is still a request to write, which is
            // exactly the case a caller must not spin on.
            throw MLXHelperError.closed(closedMessage("it exited during \(what)"))
        }

        let rc = poll(&fds, nfds_t(fds.count), deadline.millisecondsRemaining)
        if rc < 0 {
            if errno == EINTR { return }
            throw MLXHelperError.io("poll failed during \(what): \(errnoText())")
        }
        if rc == 0 {
            throw MLXHelperError.timedOut("nothing arrived during \(what)\(tailSuffix())")
        }

        if errorSlot >= 0, fds[errorSlot].revents != 0 { drainStandardError() }
        if readSlot >= 0, fds[readSlot].revents != 0 { try readResponses(what: what) }
        if writeSlot >= 0, fds[writeSlot].revents != 0, let outgoing {
            try writeSome(outgoing, sent: &sent, what: what)
        }
    }

    private func readResponses(what: String) throws {
        let count = scratch.withUnsafeMutableBytes { buffer in
            read(readFD, buffer.baseAddress, buffer.count)
        }
        if count == 0 {
            readEnded = true
            // One more drain before anyone is told the helper is gone. Draining
            // stderr first in `service` is not enough on its own: a poll that
            // reports only the response side readable would see the end of it
            // and leave the reason for it unread, and the caller checks
            // `readEnded` before it polls again. This is what makes the tail
            // complete rather than usually complete.
            drainStandardError()
            do {
                try decoder.finish()
            } catch let failure as MLXProtocolError {
                endFailure = failure
            } catch {
                endFailure = .truncated("\(error)")
            }
            return
        }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            throw MLXHelperError.io("could not read during \(what): \(errnoText())")
        }
        let batch = scratch.withUnsafeBytes { buffer in
            decoder.push(Data(bytes: buffer.baseAddress!, count: count))
        }
        pending.append(contentsOf: batch.frames)
        if let failure = batch.failure {
            // The frames decoded before the failure stay in `pending` on
            // purpose: the helper's last good line is often the error event
            // that explains what follows.
            readEnded = true
            endFailure = failure
        }
    }

    private func drainStandardError() {
        while true {
            let count = scratch.withUnsafeMutableBytes { buffer in
                read(errorFD, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                scratch.withUnsafeBytes { tail.append(UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
                // A read shorter than the buffer means there was nothing more
                // to give. Leaving on that rather than on EAGAIN is what keeps
                // this from blocking if the descriptor is not non-blocking
                // after all - the `fcntl` in `init` reports a failure nobody
                // reads, and a blocking read here would hang the whole loop.
                if count < scratch.count { return }
                continue
            }
            if count == 0 {
                Darwin.close(errorFD)
                errorFD = -1
            }
            // count < 0 with EAGAIN is the normal end of a drain.
            return
        }
    }

    private func writeSome(
        _ buffer: UnsafeRawBufferPointer, sent: inout Int, what: String
    ) throws {
        guard let base = buffer.baseAddress, sent < buffer.count else { return }
        let count = Darwin.write(writeFD, base.advanced(by: sent), buffer.count - sent)
        if count > 0 {
            sent += count
            return
        }
        if count < 0 {
            switch errno {
            case EINTR, EAGAIN:
                return
            case EPIPE:
                throw MLXHelperError.closed(closedMessage("it exited while being sent a \(what)"))
            default:
                throw MLXHelperError.io("could not write during \(what): \(errnoText())")
            }
        }
    }

    // MARK: - Messages

    private func closedMessage(_ what: String) -> String {
        let suffix = tailSuffix()
        return suffix.isEmpty ? what : "\(what)\(suffix)"
    }

    private func tailSuffix() -> String {
        let text = tail.text
        return text.isEmpty ? "" : "; it last said: \(text)"
    }

    private func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
