// Frames.swift - how a request and its audio share one byte stream.
//
// A pipe is bytes, not messages, and this is the only place in either process
// that knows where one message stops. The rule is small enough to state in a
// sentence: one line of UTF-8 JSON terminated by \n, and if that object carries
// an integer `bytes`, exactly that many raw bytes follow the newline and belong
// to the same frame.
//
// The alternative - base64 audio inside the JSON - was rejected for one
// measurable reason: a FLEURS split is about 2.5 hours of audio, so a full eval
// cell moves roughly 570 MB of Float32 through this pipe, and base64 would make
// that 760 MB plus an encode and a decode per utterance. The cost of the raw
// payload is this state machine.
//
// It is a state machine over pushed buffers rather than a reader over a file
// handle, for the same reason `SampleChunker` is: the arithmetic is the part
// that can be wrong, and a value type with no I/O in it can be tested at every
// split point instead of only at the ones a pipe happens to produce.
//
// `bytes` belongs to this layer. No message type may use that key for anything
// else.

import Foundation

public enum MLXProtocolError: Error, Equatable, CustomStringConvertible {
    /// A line ran past the cap with no newline in it.
    case lineTooLong(limit: Int)
    /// A `bytes` value that is negative, or larger than any buffer this
    /// protocol carries.
    case payloadOutOfRange(bytes: Int, limit: Int)
    case malformedHeader(String)
    /// The stream ended in the middle of a frame.
    case truncated(String)

    public var description: String {
        switch self {
        case .lineTooLong(let limit):
            return "a protocol line exceeded \(limit) bytes with no newline"
        case .payloadOutOfRange(let bytes, let limit):
            return "payload of \(bytes) bytes is outside 0...\(limit)"
        case .malformedHeader(let detail):
            return "malformed frame header: \(detail)"
        case .truncated(let detail):
            return "the stream ended mid-frame: \(detail)"
        }
    }
}

/// What one `push` produced: the frames that came out whole, and the failure
/// that ended the stream if one did.
///
/// `push` returns this rather than throwing, and the difference is not
/// cosmetic. A single read off a pipe routinely carries several messages, so a
/// corrupt one can arrive behind two good ones - and a `throw` discards
/// everything decoded in the same call, because a `mutating func` keeps its
/// property writes when it unwinds but its locals are gone. That loses results
/// the other side legitimately produced, with no trace: the decoder afterwards
/// reports `isIdle` and no pending bytes, which is to say it looks healthy.
///
/// So the good frames come back with the failure beside them, and the failure
/// is latched: every later `push` returns it again and consumes nothing. A
/// stream that stopped being this protocol's cannot quietly become one again.
public struct MLXFrameBatch: Sendable {
    /// Frames that were whole before the failure, in order. Never discarded.
    public var frames: [MLXFrame]
    /// nil while the stream is still this protocol's.
    public var failure: MLXProtocolError?

    public init(frames: [MLXFrame], failure: MLXProtocolError? = nil) {
        self.frames = frames
        self.failure = failure
    }
}

/// One message: its JSON line, and the raw bytes that followed it.
public struct MLXFrame: Sendable, Equatable {
    /// The JSON object, without the terminating newline.
    public var line: Data
    /// Empty unless the line declared `bytes`.
    public var payload: Data

    public init(line: Data, payload: Data = Data()) {
        self.line = line
        self.payload = payload
    }
}

/// Turns pushed byte buffers into whole frames.
public struct MLXFrameDecoder: Sendable {
    /// A megabyte of JSON is already two orders of magnitude past the longest
    /// message this protocol defines; past it, the stream is not one of ours
    /// and reading further only grows a buffer.
    public static let defaultLineLimit = 1 << 20

    /// 256 MB is about 70 minutes of 16 kHz Float32. `speech` hands over
    /// bounded buffers, so nothing legitimate comes near it; the cap is here so
    /// that a corrupted header cannot make either process reserve a size it
    /// read off a broken pipe.
    ///
    /// It bounds what the decoder holds *between* calls, not what one call may
    /// hand it: `push` appends its whole argument before parsing anything, so a
    /// caller that reads a gigabyte in one go has already allocated a gigabyte
    /// before any header is seen. Both callers here read fixed-size chunks off
    /// a pipe, which is what makes that a bound rather than a hope.
    public static let defaultPayloadLimit = 256 << 20

    private let lineLimit: Int
    private let payloadLimit: Int

    /// Bytes received and not yet returned in a frame.
    private var buffer: [UInt8] = []
    /// How far into `buffer` the frames already returned reach. Kept as a
    /// cursor rather than removing from the front, so a stream of small pushes
    /// does not memmove the remainder once per push.
    private var cursor: Int = 0
    /// The line whose payload is still arriving, nil while reading a line.
    private var awaitingPayloadFor: Data?
    private var awaitingPayloadBytes: Int = 0
    /// How far the newline search has already looked without finding one.
    ///
    /// Without it every `push` rescans the whole unterminated prefix from
    /// `cursor`, which is quadratic in the length of a line that never ends -
    /// measured at roughly 4x the time for 2x the input, so a garbage stream
    /// delivered in small chunks would burn minutes of CPU before the 1 MB cap
    /// finally rejected it. The cap bounds the memory; this bounds the work.
    private var scanned: Int = 0
    /// Set once the stream stops being this protocol's, and never cleared.
    private var latched: MLXProtocolError?
    /// Bytes the newline search has looked at, over the decoder's whole life.
    ///
    /// Exposed so that "the scan does not restart" can be a unit test rather
    /// than a stopwatch. The rule is about work rather than output - a decoder
    /// that rescanned would return exactly the same frames - so the only way to
    /// test it is to count.
    private(set) var bytesScanned: Int = 0

    public init(
        lineLimit: Int = MLXFrameDecoder.defaultLineLimit,
        payloadLimit: Int = MLXFrameDecoder.defaultPayloadLimit
    ) {
        self.lineLimit = max(1, lineLimit)
        self.payloadLimit = max(0, payloadLimit)
    }

    /// True when the decoder holds nothing: the only state in which a stream
    /// may end without having been cut in half.
    public var isIdle: Bool { awaitingPayloadFor == nil && cursor == buffer.count }

    /// Bytes held back, for tests and diagnostics.
    public var pendingBytes: Int { buffer.count - cursor }

    /// The failure that ended this stream, once one has.
    public var failure: MLXProtocolError? { latched }

    /// Everything the decoder is holding, including the prefix it has already
    /// returned and not yet dropped.
    ///
    /// Exposed because compaction is a rule about memory rather than about
    /// output: a decoder that never compacted would return exactly the same
    /// frames, and would also hold every byte of a session. An evaluation cell
    /// is about 570 MB of audio through one pipe, so that is the difference
    /// between a bounded buffer and keeping the whole cell.
    var retainedBytes: Int { buffer.count }

    public mutating func push(_ data: Data) -> MLXFrameBatch {
        if let latched {
            // Nothing is consumed and nothing is decoded once the stream has
            // failed: re-reporting is the only honest answer, and it keeps a
            // caller that ignored the first failure from being told everything
            // is fine.
            return MLXFrameBatch(frames: [], failure: latched)
        }
        buffer.append(contentsOf: data)
        var frames: [MLXFrame] = []
        while true {
            if let line = awaitingPayloadFor {
                guard buffer.count - cursor >= awaitingPayloadBytes else { break }
                let payload = Data(buffer[cursor..<(cursor + awaitingPayloadBytes)])
                cursor += awaitingPayloadBytes
                awaitingPayloadFor = nil
                awaitingPayloadBytes = 0
                frames.append(MLXFrame(line: line, payload: payload))
                continue
            }

            guard let newline = indexOfNewline() else {
                // No terminator yet. A line that has already outgrown the cap
                // never will be one of ours, so stop rather than keep buffering.
                if buffer.count - cursor > lineLimit {
                    return fail(.lineTooLong(limit: lineLimit), with: frames)
                }
                break
            }
            let line = Data(buffer[cursor..<newline])
            cursor = newline + 1
            scanned = cursor
            if line.count > lineLimit {
                return fail(.lineTooLong(limit: lineLimit), with: frames)
            }
            // A blank line costs nothing to ignore and makes the stream
            // tolerant of a trailing newline. Anything else that is not a JSON
            // object with an optional integer `bytes` is a protocol error, not
            // something to skip past.
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }

            let declared: Int
            do {
                declared = try Self.payloadBytes(of: line)
            } catch let error as MLXProtocolError {
                return fail(error, with: frames)
            } catch {
                return fail(.malformedHeader(String(describing: error)), with: frames)
            }
            guard declared >= 0, declared <= payloadLimit else {
                return fail(.payloadOutOfRange(bytes: declared, limit: payloadLimit),
                            with: frames)
            }
            if declared == 0 {
                frames.append(MLXFrame(line: line))
            } else {
                awaitingPayloadFor = line
                awaitingPayloadBytes = declared
            }
        }
        compact()
        return MLXFrameBatch(frames: frames)
    }

    /// Latch a failure and hand back whatever was already whole.
    private mutating func fail(
        _ error: MLXProtocolError, with frames: [MLXFrame]
    ) -> MLXFrameBatch {
        latched = error
        return MLXFrameBatch(frames: frames, failure: error)
    }

    /// Call when the stream ends. Throws if a frame was cut in half, because
    /// the alternative is treating half a buffer of audio as a whole one.
    public mutating func finish() throws {
        // A stream that already failed did not end cleanly, whatever is left in
        // the buffer.
        if let latched { throw latched }
        if awaitingPayloadFor != nil {
            throw MLXProtocolError.truncated(
                "\(awaitingPayloadBytes - (buffer.count - cursor)) payload bytes were never sent")
        }
        if cursor != buffer.count {
            throw MLXProtocolError.truncated("\(buffer.count - cursor) bytes with no newline")
        }
    }

    /// The next newline at or after `cursor`, or nil.
    ///
    /// Starting at `max(cursor, scanned)` is what keeps a payload's bytes out
    /// of the search as well as what makes it linear: `scanned` only ever runs
    /// ahead of `cursor` while a line is still being assembled, and a payload
    /// is consumed by the branch above without the search ever running.
    private mutating func indexOfNewline() -> Int? {
        let start = max(cursor, scanned)
        var index = start
        while index < buffer.count {
            if buffer[index] == 0x0A {
                bytesScanned += index - start + 1
                return index
            }
            index += 1
        }
        bytesScanned += index - start
        // Everything up to here is known to hold no newline, so the next call
        // starts where this one stopped.
        scanned = buffer.count
        return nil
    }

    /// Drop what has been consumed, but not on every push: moving the
    /// remainder costs a copy, and the common case is a cursor that is about to
    /// reach the end anyway.
    private mutating func compact() {
        guard cursor > 0 else { return }
        if cursor == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            cursor = 0
            scanned = 0
        } else if cursor > 1 << 16 {
            buffer.removeFirst(cursor)
            scanned = max(0, scanned - cursor)
            cursor = 0
        }
    }

    /// The framing layer's only look inside a message.
    static func payloadBytes(of line: Data) throws -> Int {
        struct Header: Decodable { var bytes: Int? }
        do {
            return try JSONDecoder().decode(Header.self, from: line).bytes ?? 0
        } catch {
            let text = String(decoding: line.prefix(200), as: UTF8.self)
            throw MLXProtocolError.malformedHeader("\(error) in '\(text)'")
        }
    }
}

/// The writing half. Trivial by design - if it needed a state machine, the
/// format would be wrong.
public enum MLXFrameWriter {
    /// A request and its audio as the bytes to write, in one buffer so that a
    /// reader can never see the line without the payload behind it.
    public static func frame(_ request: MLXRequest, payload: Data = Data()) throws -> Data {
        var out = try MLXWire.line(request)
        out.append(0x0A)
        out.append(payload)
        return out
    }

    public static func frame(_ response: MLXResponse) throws -> Data {
        var out = try MLXWire.line(response)
        out.append(0x0A)
        return out
    }

    /// 16 kHz mono Float32 as the bytes on the wire, little-endian, which is
    /// every machine this binary runs on. Stated rather than assumed because
    /// the reader on the other side does the same reinterpretation and a
    /// disagreement would produce audio rather than an error.
    public static func payload(samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The inverse. Returns nil when the byte count is not a whole number of
    /// samples, which is the check that makes a short write a protocol error
    /// instead of a transcript of the truncation.
    public static func samples(from payload: Data) -> [Float]? {
        guard payload.count % MemoryLayout<Float>.size == 0 else { return nil }
        let count = payload.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        // Not `[Float](repeating: 0, count:)` then copy: that writes every byte
        // twice, and this is the path a whole evaluation cell of audio goes
        // through. `copyBytes` honors the slice's own bounds, so an offset
        // slice - which is what comes out of the decoder - is handled correctly.
        return [Float](unsafeUninitializedCapacity: count) { destination, initialized in
            initialized = payload.copyBytes(to: destination) / MemoryLayout<Float>.size
        }
    }
}
