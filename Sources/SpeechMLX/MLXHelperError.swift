// MLXHelperError.swift - what can go wrong while talking to speech-mlx, plus
// the two small pieces every part of that conversation needs: a monotonic
// deadline and a bounded copy of what the helper said on stderr.
//
// The error cases exist to be turned into a `SpeechError` by the engine above,
// and the split is by what the caller should DO about it rather than by where
// the failure happened. `notFound` and `spawnFailed` mean this build cannot run
// MLX rows at all; `refused` means this model or this buffer failed and the
// next one may not; `closed`, `timedOut` and `protocolViolation` mean the
// session is over and a new one has to be started.

import Foundation

public enum MLXHelperError: Error, Equatable, CustomStringConvertible {
    /// No helper binary. The message says where it looked.
    case notFound(String)
    /// The binary is there and would not start.
    case spawnFailed(String)
    /// Nothing arrived before the deadline. The helper is still running; the
    /// caller decides whether to kill it.
    case timedOut(String)
    /// The helper exited, or its output ended, mid-conversation. Carries
    /// whatever it last wrote to stderr, which is usually the actual reason.
    case closed(String)
    /// An `error` event: the helper is alive and declined this request.
    case refused(op: String, message: String)
    /// The helper answered, and the answer does not fit the protocol - a reply
    /// to a request nobody made, an id that does not match, a frame the
    /// decoder rejected. Distinct from `refused` because it means the two sides
    /// disagree about the format rather than about one request.
    case protocolViolation(String)
    /// A read or write failed for a reason the operating system named.
    case io(String)

    public var description: String {
        switch self {
        case .notFound(let message): return message
        case .spawnFailed(let message): return "speech-mlx would not start: \(message)"
        case .timedOut(let message): return "speech-mlx did not answer: \(message)"
        case .closed(let message): return "speech-mlx stopped: \(message)"
        case .refused(let op, let message): return "speech-mlx refused \(op): \(message)"
        case .protocolViolation(let message): return "speech-mlx broke the protocol: \(message)"
        case .io(let message): return "speech-mlx connection failed: \(message)"
        }
    }
}

/// A point in time that arithmetic cannot get wrong.
///
/// `CLOCK_UPTIME_RAW` rather than the wall clock, and rather than
/// `CLOCK_MONOTONIC_RAW`: the wall clock can step backwards over an NTP
/// correction and turn a 30-second timeout into a 30-minute one, and uptime
/// stops while the machine is asleep, so a lid closed during a two-minute model
/// load does not turn into a timeout the user cannot explain.
struct Deadline {
    private let expiry: UInt64

    /// A hundred years, in nanoseconds, and the reason for a number rather than
    /// `UInt64.max` is that the obvious version of this crashed.
    ///
    /// `Double(UInt64.max - now)` rounds UP: the gap between representable
    /// Doubles at that magnitude is 2048, so the nearest one is exactly 2^64,
    /// and converting that back to a UInt64 is a trap rather than a large
    /// number. The first version of this initializer took the whole process
    /// down on `Deadline(seconds: .infinity)`, on `.nan`, and on any finite
    /// value past about 585 years - which includes
    /// `Double.greatestFiniteMagnitude`, the usual way of writing "no timeout".
    /// `Timeouts` is public and its fields are plain Doubles, so those are
    /// values a caller can hand over.
    private static let ceilingNanoseconds = 3.1536e18

    init(seconds: Double) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let nanoseconds: Double
        if seconds.isNaN || seconds <= 0 {
            nanoseconds = 0
        } else if seconds.isInfinite {
            nanoseconds = Self.ceilingNanoseconds
        } else {
            // The multiplication can reach infinity on its own; min handles it.
            nanoseconds = min(seconds * 1_000_000_000, Self.ceilingNanoseconds)
        }
        expiry = now + UInt64(nanoseconds)
    }

    var hasPassed: Bool { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= expiry }

    /// What to hand `poll`. Never negative, because a negative timeout there
    /// means "wait forever" and that is the one behavior a deadline exists to
    /// rule out.
    var millisecondsRemaining: Int32 {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard expiry > now else { return 0 }
        let milliseconds = (expiry - now) / 1_000_000
        return Int32(min(milliseconds, UInt64(Int32.max)))
    }
}

/// The last few kilobytes the helper wrote to stderr.
///
/// Bounded because the helper's stderr also carries whatever the MLX libraries
/// print, and a model that logs a line per chunk would otherwise be held in
/// memory for the length of an evaluation split. The tail is the part worth
/// keeping: when a helper dies, the reason is the last thing it said.
struct BoundedTail {
    private var bytes: [UInt8] = []
    private var dropped = false
    let limit: Int

    init(limit: Int) {
        self.limit = max(0, limit)
        bytes.reserveCapacity(min(self.limit, 4096))
    }

    mutating func append(_ chunk: UnsafeRawBufferPointer) {
        guard limit > 0, !chunk.isEmpty else { return }
        if chunk.count >= limit {
            bytes = Array(chunk.suffix(limit))
            dropped = true
            return
        }
        bytes.append(contentsOf: chunk)
        if bytes.count > limit {
            bytes.removeFirst(bytes.count - limit)
            dropped = true
        }
    }

    /// Trimmed, and prefixed with an ellipsis when the start was dropped, so
    /// that a truncated tail cannot be mistaken for the whole output.
    var text: String {
        let decoded = String(decoding: bytes, as: UTF8.self)
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return dropped ? "... \(trimmed)" : trimmed
    }
}
