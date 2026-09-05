// GGMLSession.swift - the one place a transcribe.cpp `Session` is touched.
//
// `Session` is deliberately not `Sendable`: the C contract is one session per
// thread, and one in-flight run per model across all its sessions. An actor can
// hold one as isolated state, but it cannot hand it to the wrapper's own async
// `run` - that method hops to a background queue, which under Swift 6 is
// "sending 'session' risks causing data races", and the compiler is right.
//
// So the session gets an owner instead. Every touch happens on one serial
// queue, which is what makes the `@unchecked Sendable` true rather than merely
// asserted, and `run` bridges that queue back to async with a continuation. Two
// things fall out of doing it here rather than on the actor. Neither the load
// nor the decode occupies a cooperative thread, which matters once Speech.app
// runs one of these behind a window. And Swift task cancellation reaches the
// native abort, so Ctrl-C during a twenty-minute file stops it.
//
// One honest exception to "every touch happens on the queue": destruction.
// When the last reference to this class drops, `Session.deinit` calls
// `transcribe_session_free` on whatever thread ARC happened to be on. That is
// after every run has completed - so it is not concurrent use, which is the
// property the C contract actually cares about - but it is not on the queue
// either, and the upstream wrapper has the same shape.

import Foundation
import SpeechCore
import TranscribeCpp

/// Serialized owner of a `Session`, and the boundary the rest of the module
/// talks to.
final class GGMLSession: @unchecked Sendable {
    private let session: Session
    /// Every access to `session` happens here, including the blocking decode.
    private let queue: DispatchQueue
    /// The active streaming run, if any.
    ///
    /// It lives here rather than on the live session for the same reason
    /// `Session` does: `Stream` is not `Sendable`, it drives the session's
    /// state, and the C contract is one thread. Keeping it behind the same
    /// queue is what makes the `@unchecked Sendable` on this class true for
    /// streaming as well as for batch.
    /// Qualified: Foundation has a `Stream` of its own.
    private var stream: TranscribeCpp.Stream?

    private init(session: Session, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
    }

    /// Load a model and open its session, both on the owning queue.
    ///
    /// The load belongs here as much as the decode does, and for the same
    /// reason: `Model(path:)` maps a two-gigabyte GGUF and allocates its Metal
    /// buffers synchronously, which on a 2 GB row is the *longer* of the two
    /// blocking operations. Doing it on the actor - which is what a plain
    /// `Task { }` inside an actor method does, since that task inherits the
    /// actor's isolation - parked a cooperative thread for the whole load.
    ///
    /// `Model` is `@unchecked Sendable` by the wrapper's own declaration, so
    /// handing it back across the boundary is allowed; `Session` is not, which
    /// is why it never leaves this class.
    static func load(
        path: String, backend: Backend, label: String
    ) async throws -> (model: Model, session: GGMLSession) {
        let queue = DispatchQueue(label: "com.abracode.speech.ggml.\(label)")
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                cont.resume(with: Result {
                    let model = try Model(path: path, options: ModelOptions(backend: backend))
                    return (model, GGMLSession(session: try model.session(), queue: queue))
                })
            }
        }
    }

    /// Transcribe one piece of audio, off the caller's thread.
    ///
    /// The cancellation token is installed per run rather than once, so a
    /// canceled run cannot leave a tripped flag behind that aborts the next
    /// one. Installing it inside the queue block is also what makes the
    /// `onCancel` race benign: if cancellation arrives first the token is
    /// already tripped when it is installed, and the native abort callback -
    /// polled between decode steps - sees it on the first poll.
    func run(_ pcm: [Float], options: RunOptions) async throws -> Transcript {
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Transcript, Error>) in
                queue.async {
                    self.session.setCancellationToken(token)
                    let result = Result { () -> Transcript in
                        // Symmetric with `beginStream`. Without it a batch call
                        // during a live session meets the library's own
                        // "a stream is active on this model" string, which the
                        // doc on `beginStream` promises the caller never sees.
                        guard self.stream == nil else {
                            throw SpeechError.runtime(
                                "a live stream is running on this model;"
                                + " stop it before transcribing a file")
                        }
                        return try self.session.run(pcm, options: options)
                    }
                    self.session.clearCancellationToken()
                    cont.resume(with: result)
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    // MARK: - Streaming

    /// One feed's worth of change: what moved, and the text after it moved.
    struct StreamStep: Sendable {
        var update: StreamUpdate
        var text: StreamText
    }

    /// Begin a streaming run, claiming the model's compute lease.
    ///
    /// The lease is why this cannot overlap with `run`: transcribe.cpp refuses
    /// a second stream, or any offline run, on *any* session of the same model
    /// until this one finalizes or resets. One engine instance therefore does
    /// live or batch, not both at once, and the caller is told so rather than
    /// meeting `.busy` from inside the library.
    func beginStream(run: RunOptions, options: StreamOptions) async throws {
        try await onQueue {
            guard self.stream == nil else {
                throw SpeechError.runtime("a live stream is already running on this model")
            }
            self.stream = try self.session.stream(run, options)
        }
    }

    /// Feed 16 kHz mono Float32 and read back what changed.
    func feedStream(_ pcm: [Float]) async throws -> StreamStep {
        try await onQueue {
            guard let stream = self.stream else {
                throw SpeechError.runtime("no live stream is running")
            }
            let update = try stream.feed(pcm)
            return StreamStep(update: update, text: stream.text)
        }
    }

    /// Flush what is buffered and end the stream, releasing the compute lease.
    func finalizeStream() async throws -> StreamStep {
        try await onQueue {
            guard let stream = self.stream else {
                throw SpeechError.runtime("no live stream is running")
            }
            let update = try stream.finalize()
            let text = stream.text
            self.stream = nil
            return StreamStep(update: update, text: text)
        }
    }

    /// Abandon the stream. Idempotent, and never throws: it is the cleanup path.
    ///
    /// Explicit rather than left to `Stream.deinit`. Deinit does reset, but on
    /// whatever thread ARC happens to be on, which is the one place this class
    /// otherwise cannot promise queue discipline. Doing it here means the
    /// common case is orderly and deinit is only the backstop.
    func resetStream() async {
        try? await onQueue(cancellable: false) {
            guard let stream = self.stream else { return }
            _ = stream.reset()
            self.stream = nil
        }
    }

    /// Run `body` on the owning queue and bridge it back to async, with the
    /// same cancellation wiring `run` uses.
    ///
    /// Every streaming call has the same shape, and writing the continuation
    /// dance four times is four chances to forget the queue.
    ///
    /// The cancellation token is not decoration. `transcribe_stream_finalize`
    /// flushes the whole buffered tail, and a `feed` can trigger a decode; both
    /// are native calls that ignore Swift task cancellation entirely. Without
    /// the token a Stop button in Speech.app cannot interrupt either one, which
    /// is exactly what `run` installs it for. Installed per call rather than
    /// once, so a cancelled call cannot leave a tripped flag behind that aborts
    /// the next one.
    private func onQueue<T: Sendable>(
        cancellable: Bool = true, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let token = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                queue.async {
                    if cancellable { self.session.setCancellationToken(token) }
                    let result = Result { try body() }
                    if cancellable { self.session.clearCancellationToken() }
                    cont.resume(with: result)
                }
            }
        } onCancel: {
            if cancellable { token.cancel() }
        }
    }
}
