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
import TranscribeCpp

/// Serialized owner of a `Session`, and the boundary the rest of the module
/// talks to.
final class GGMLSession: @unchecked Sendable {
    private let session: Session
    /// Every access to `session` happens here, including the blocking decode.
    private let queue: DispatchQueue

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
    /// cancelled run cannot leave a tripped flag behind that aborts the next
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
                    let result = Result { try self.session.run(pcm, options: options) }
                    self.session.clearCancellationToken()
                    cont.resume(with: result)
                }
            }
        } onCancel: {
            token.cancel()
        }
    }
}
