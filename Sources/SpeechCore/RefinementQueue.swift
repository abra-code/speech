// RefinementQueue.swift - `--refine`: a second, slower, better engine that
// re-transcribes each finished utterance while the fast one keeps up with the
// microphone.
//
// The product claim behind it is that a person should see words appear as they
// speak *and* end up with a transcript as good as the best model on the
// machine. Those two want opposite models - Parakeet at 100x real time and
// Qwen3-ASR at 12x - so live mode runs both and lets the second overwrite the
// first. That is what `segment.refined` reusing the final's id is for.
//
// Three properties this type exists to guarantee:
//
// Serial. One refinement at a time, in its own task. A refine engine is a
// gigabyte of weights doing Metal work; two at once contend with the draft
// engine for the same GPU and the live path is the one that visibly suffers.
//
// Never blocking capture. `submit` returns immediately, always. The audio
// thread is several hops away by then, but the live session is not, and an
// await here would put model inference on the path that feeds it.
//
// Bounded. If the refine engine cannot keep up - and at 12x against a speaker
// who does not pause, it cannot - the backlog is dropped oldest-first with a
// warning rather than grown. A queue that keeps every utterance of a
// forty-minute meeting is a memory leak wearing a feature's clothes.

import Foundation

public actor RefinementQueue {
    /// What the caller gets back, in submission order for the items that
    /// survive: the original segment with better text.
    public typealias Handler = @Sendable (Segment) -> Void
    public typealias WarningHandler = @Sendable (String, String) -> Void

    private let engine: any TranscriptionEngine
    private let engineID: String
    private let options: TranscribeOptions
    private let onRefined: Handler
    private let onWarning: WarningHandler
    /// Total audio allowed to sit in the backlog. Two minutes is generous for
    /// a refine engine that is keeping up and a firm stop for one that is not.
    private let backlogSecondsCap: Double

    private var pending: [(segment: Segment, samples: [Float])] = []
    private var pendingSeconds: Double = 0
    private var worker: Task<Void, Never>?
    /// True while an item is out at the engine. Tracked rather than inferred
    /// from `worker != nil`, because `submit` returns before its task has been
    /// scheduled and `drain` would then report a queue of one as two.
    private var inFlight = false
    /// Set by `drain` and `cancel`: the queue is finished and takes no more work.
    ///
    /// A queue is single-use on purpose, and the alternative is worse than it
    /// looks. Ending a run cancels the worker without waiting for it, because
    /// the inference inside is not interruptible - so if a later `submit` could
    /// start a second worker, that worker would run *concurrently* with the
    /// abandoned one. Two inferences at once is exactly what the serial rule at
    /// the top of this file exists to prevent, and the caller would have no way
    /// to know it had happened. One queue per live session; a second session
    /// builds a second queue, which costs nothing.
    private var closed = false
    private var dropped = 0

    public init(
        engine: any TranscriptionEngine,
        options: TranscribeOptions,
        backlogSecondsCap: Double = 120,
        onRefined: @escaping Handler,
        onWarning: @escaping WarningHandler
    ) {
        self.engine = engine
        self.engineID = engine.id
        self.options = options
        self.backlogSecondsCap = backlogSecondsCap
        self.onRefined = onRefined
        self.onWarning = onWarning
    }

    /// Queue one finalized utterance. Returns at once.
    public func submit(_ segment: Segment, samples: [Float]) {
        guard !closed else {
            onWarning(
                "refinement was already stopped; utterance \(segment.id) was not refined",
                "refine_closed")
            return
        }
        guard !samples.isEmpty else { return }
        let seconds = Double(samples.count) / AudioDecoder.sampleRate
        pending.append((segment, samples))
        pendingSeconds += seconds

        while pendingSeconds > backlogSecondsCap, pending.count > 1 {
            // Never drop the item currently at the head if it is the only one:
            // dropping the single queued utterance to stay under a cap it alone
            // exceeds would mean a long utterance is never refined at all.
            let removed = pending.removeFirst()
            pendingSeconds -= Double(removed.samples.count) / AudioDecoder.sampleRate
            dropped += 1
        }
        if dropped > 0 {
            onWarning(
                "'\(engineID)' cannot keep up; \(dropped) utterance(s) were left unrefined",
                "refine_backlog")
            dropped = 0
        }

        startWorker()
    }

    /// Wait for the backlog to clear, up to `timeout`.
    ///
    /// Returns the number of items abandoned, which is zero on a clean flush.
    /// The caller reports a non-zero count rather than hiding it: a transcript
    /// missing three refinements is a different artifact from a complete one,
    /// and the person who has to trust it should be told.
    ///
    /// **What this does not bound is the engine.** Cancelling the worker stops
    /// it taking new work; it does not stop an inference already inside
    /// `transcribe`, and every engine here is an actor, so the caller's next
    /// `unload()` will queue behind that inference however long it takes. The
    /// caller's job is to say out loud that it is waiting, and the process must
    /// stay killable while it does - which is why `StopController` restores the
    /// default signal disposition as soon as the first stop is recorded.
    ///
    /// Draining closes the queue. See `closed`.
    public func drain(timeout: Duration) async -> Int {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while worker != nil || !pending.isEmpty {
            // Cancellation first, and not only for tidiness: once this task is
            // canceled `Task.sleep` throws instantly, `try?` swallows it, and
            // the loop becomes a pegged core for the rest of the timeout.
            if Task.isCancelled { break }
            if ContinuousClock().now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard worker != nil || !pending.isEmpty else { return 0 }
        let abandoned = pending.count + (inFlight ? 1 : 0)
        cancel()
        return abandoned
    }

    /// Abandon everything and close the queue. For the cancel path, where
    /// nobody is waiting.
    public func cancel() {
        closed = true
        worker?.cancel()
        worker = nil
        pending.removeAll()
        pendingSeconds = 0
    }

    private func startWorker() {
        guard worker == nil, !closed else { return }
        worker = Task { await self.run() }
    }

    private func run() async {
        // The cancellation test is the loop condition, not the first statement
        // in the body. Inside the body it is already too late: `take` has
        // popped an utterance, and returning there would drop it on the floor
        // without refining it and without telling anyone. Belt and braces
        // today, since `cancel()` also empties `pending` so there is nothing
        // left to pop - and untested for that reason, which is why it is said
        // here rather than implied by a test that would pass either way.
        while !Task.isCancelled, let item = take() {
            do {
                let segments = try await engine.transcribe(samples: item.samples, options: options)
                let text = segments.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // An empty refinement is discarded rather than published. The
                // draft engine heard something; a refine engine that returns
                // nothing for the same audio is far more likely to have hit a
                // bad chunk than to have correctly heard silence, and
                // overwriting real text with "" is the one failure a user
                // cannot undo.
                // Cancelled between the submit and here: `drain` has already
                // counted this utterance as abandoned and the caller may
                // already have emitted `done`. Publishing now would put a
                // `segment.refined` after the terminal event, which the
                // applet's poller treats as impossible.
                guard !text.isEmpty, !Task.isCancelled else { continue }
                var refined = item.segment
                refined.text = text
                // Word timings come from the draft engine's clock and describe
                // different text now. Keeping them would put the new words at
                // the old words' times, which reads as correct and is not.
                refined.words = nil
                refined.confidence = segments.first?.confidence
                onRefined(refined)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? SpeechError)?.message ?? error.localizedDescription
                onWarning("refinement failed: \(message)", "refine_failed")
            }
        }
    }

    /// Pops the next item, or clears `worker` when the queue is empty.
    ///
    /// Synchronous on purpose: it is the one operation that must be atomic with
    /// respect to `submit`, and only a non-async actor method is. An async
    /// version would let a `submit` land between "the queue is empty" and
    /// "there is no worker", and that item would sit there until the next one
    /// arrived - or forever, if it was the last thing said.
    private func take() -> (segment: Segment, samples: [Float])? {
        guard !pending.isEmpty else {
            inFlight = false
            worker = nil
            return nil
        }
        let item = pending.removeFirst()
        pendingSeconds -= Double(item.samples.count) / AudioDecoder.sampleRate
        inFlight = true
        return item
    }
}
