// MLXHelperRunner.swift - one helper, driven from Swift concurrency.
//
// MLXHelperConnection is deliberately synchronous and thread-confined: its
// whole job is a poll loop, and a poll loop that is also an async state machine
// is two hard things wearing one coat. This is the coat. Every call is
// dispatched onto one serial queue, so the connection is touched by one thread
// at a time and blocking reads happen on a thread whose job is to block -
// never on the cooperative pool, where a blocked thread is a thread the whole
// program's concurrency was counting on.
//
// `kill` is the exception and has to be: it is what cancellation does, and by
// definition it is called while the queue is busy inside a transcription that
// is not coming back. It touches no connection state, only the pid, under the
// process's own lock.

import Foundation
import SpeechMLXProtocol

/// What one `transcribe` produced.
struct MLXTranscription: Sendable {
    var segments: [MLXResponse.SegmentEvent]
    var done: MLXResponse.Done
}

final class MLXHelperRunner: @unchecked Sendable {
    private let queue: DispatchQueue
    private let process: MLXHelperProcess

    init(executable: URL, timeouts: MLXHelperConnection.Timeouts) throws {
        self.process = try MLXHelperProcess(executable: executable, timeouts: timeouts)
        self.queue = DispatchQueue(label: "com.abracode.speech.mlx-helper")
    }

    func handshake() async throws -> MLXResponse.Ready {
        try await onQueue { try $0.handshake() }
    }

    func load(directory: URL, type: String?, language: String?) async throws
        -> MLXResponse.Loaded
    {
        try await onQueue { try $0.load(directory: directory, type: type, language: language) }
    }

    func transcribe(
        id: Int, samples: [Float], chunkSeconds: Double?
    ) async throws -> MLXTranscription {
        try await onQueue { connection in
            var segments: [MLXResponse.SegmentEvent] = []
            let done = try connection.transcribe(
                id: id, samples: samples, chunkSeconds: chunkSeconds
            ) { segments.append($0) }
            return MLXTranscription(segments: segments, done: done)
        }
    }

    func unload() async throws {
        try await onQueue { try $0.unload() }
    }

    /// What the helper last wrote to stderr. Read on the queue like everything
    /// else, so it cannot be sampled while a drain is in progress.
    func standardErrorTail() async -> String {
        (try? await onQueue { $0.standardErrorTail }) ?? ""
    }

    /// Ends the session politely and waits for the process. Queued behind
    /// whatever is running, which is what makes it polite: a helper torn away
    /// mid-transcription would be `kill`.
    func shutdown() async {
        // Both halves on the queue, the stop included. `stop` closes the
        // connection's descriptors, so running it anywhere else would be
        // closing fds out from under whatever the queue is doing - which is
        // the one thing this class exists to prevent.
        _ = try? await onQueue { connection in
            try? connection.sayGoodbye()
            return 0
        }
        await withCheckedContinuation { continuation in
            queue.async { [process] in
                process.stop(within: 5)
                continuation.resume()
            }
        }
    }

    /// Ends it now. Safe from any thread and from inside a cancellation
    /// handler; see MLXHelperProcess for what it does and does not signal.
    func kill() {
        process.kill()
    }

    var isRunning: Bool { process.isRunning }

    /// The helper's peak footprint, or nil once it has gone. Read straight off
    /// the pid rather than through the queue: it is a kernel call about the
    /// process, not a message to it, and the moment it is most worth having is
    /// while the queue is busy.
    func peakFootprintBytes() -> Int64? { process.peakFootprintBytes() }

    private func onQueue<T: Sendable>(
        _ body: @escaping @Sendable (MLXHelperConnection) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [process] in
                do {
                    continuation.resume(returning: try body(process.connection))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
