// StopController.swift - the six ways a live run ends, behind one await.
//
// Live mode is the only command here that does not stop on its own, so
// "when does it end" becomes a design question rather than a return statement.
// The answers, in the order a user meets them:
//
//   Ctrl-C in a terminal            SIGINT
//   the applet closing the run      SIGTERM
//   the terminal window closing     SIGHUP
//   `q` on stdin                    the applet's normal, tidy path
//   stdin closing                   the applet died without saying goodbye
//   the parent process dying        --parent-pid, the last line of defense
//
// Every one of them has to reach the same shutdown: stop the tap, finalize the
// session, flush pending refinements, emit `done`. A signal handler cannot do
// any of that - it runs on a thread that must not allocate - so all six become
// a single value delivered to `wait()`, and the shutdown is ordinary code on an
// ordinary task.
//
// Recording the first stop also hands the signals back to the kernel, so a
// second Ctrl-C during a slow shutdown kills the process the way it would in
// any other unix tool. See `stop(_:)`.
//
// The `--parent-pid` watchdog exists because the other five can all be missed
// at once: a parent that is SIGKILLed sends nothing, closes nothing on a pty,
// and leaves a child holding the microphone with a recording light on. Polling
// `getppid()` catches exactly that, and costs one syscall a second.

import Dispatch
import Foundation
import SpeechCore

enum StopReason: Sendable, Equatable {
    case signal(Int32)
    case stdinQuit
    case stdinClosed
    case parentExited
    /// The capture path itself failed. Carries the message so the caller can
    /// report the real problem instead of "stopped".
    case failure(String)

    var label: String {
        switch self {
        case .signal(SIGINT): return "interrupt"
        case .signal(SIGTERM): return "terminate"
        case .signal(SIGHUP): return "hangup"
        case .signal(let number): return "signal \(number)"
        case .stdinQuit: return "q on stdin"
        case .stdinClosed: return "stdin closed"
        case .parentExited: return "parent process exited"
        case .failure(let message): return message
        }
    }

    /// Whether this ending is a failure the exit status should report. A
    /// deliberate stop is a success; a dead capture path is not.
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

final class StopController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.abracode.speech.stop")
    private let lock = NSLock()
    private var reason: StopReason?
    private var waiters: [CheckedContinuation<StopReason, Never>] = []
    private var sources: [DispatchSourceProtocol] = []
    private var restoreStdinFlags: Int32?
    private var started = false
    private var signalsRestored = false

    /// Signals turned into a stop. SIGPIPE is deliberately absent: it is
    /// ignored process-wide in `main` so a closed stdout cannot kill a run
    /// mid-transcript.
    static let handledSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    init() {}

    /// - Parameters:
    ///   - watchStdin: read stdin for `q` and for EOF. The applet wants this;
    ///     a script that runs with stdin closed does not, because EOF arrives
    ///     immediately and the run would stop before it started.
    ///   - parentPID: poll for this process still being our parent.
    func start(watchStdin: Bool, parentPID: pid_t?) {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }

        for number in Self.handledSignals {
            // The default disposition has to go first. A DispatchSource signal
            // source observes delivery; it does not prevent the default action,
            // so without this SIGTERM still kills the process and the handler
            // never runs.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.stop(.signal(number)) }
            source.resume()
            append(source)
        }

        if watchStdin { startStdinWatch() }

        if let parentPID {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                // getppid() rather than kill(pid, 0): a pid can be reused
                // between polls, and "my parent is no longer that process" is
                // the question being asked, not "does that process exist".
                if getppid() != parentPID { self?.stop(.parentExited) }
            }
            timer.resume()
            append(timer)
        }
    }

    private func startStdinWatch() {
        let fd = STDIN_FILENO
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 {
            // Under the lock: `shutdown` reads this from whatever task the run
            // ended on, while `start` runs it from the caller's.
            lock.lock()
            restoreStdinFlags = flags
            lock.unlock()
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 {
                self.stop(.stdinClosed)
                return
            }
            guard count > 0 else {
                // EAGAIN on a non-blocking fd that the source said was ready is
                // normal after a partial read; anything else means the fd is
                // gone, which is the same thing as closed.
                if errno != EAGAIN && errno != EINTR { self.stop(.stdinClosed) }
                return
            }
            if buffer[0..<count].contains(where: { $0 == UInt8(ascii: "q") || $0 == UInt8(ascii: "Q") }) {
                self.stop(.stdinQuit)
            }
        }
        source.resume()
        append(source)
    }

    /// Record a stop from anywhere, including a capture failure. First one wins:
    /// a SIGINT during shutdown must not re-enter and change the reported reason.
    ///
    /// Recording a stop also hands the signals back to the kernel, and that is
    /// load-bearing rather than tidy. Shutdown is not instant - it finalizes a
    /// session, drains refinements, and releases a gigabyte of weights - and an
    /// engine can take longer over any of that than the person waiting is
    /// willing to. If the handled signals stayed ignored for that whole window,
    /// a second Ctrl-C would do nothing, `kill` from another terminal would do
    /// nothing, and the only way out would be SIGKILL with the microphone still
    /// open and its indicator lit. From here on the first stop is graceful and
    /// the second one is fatal, which is the behavior every long-running unix
    /// tool has.
    ///
    /// This applies to *every* stop reason, not only to signals, and that is a
    /// deliberate choice with a cost: an applet that writes `q`, waits, and then
    /// sends SIGTERM as a fallback will kill the process outright rather than
    /// getting a `done` event. The alternative - keeping signals ignored after a
    /// tidy stop - means a `q` that runs into a stuck engine cannot be escaped
    /// at all, which is the worse failure. The contract for a controlling
    /// process is therefore: after `q`, wait for the process to exit; escalate
    /// to a signal only when you mean to abort. It is written down in
    /// docs/live.md.
    ///
    /// One consequence worth knowing: a second signal can land mid-write to the
    /// `--log` file, so its last line may be truncated. The log is append-only
    /// JSONL, so a reader loses at most that line.
    func stop(_ reason: StopReason) {
        lock.lock()
        guard self.reason == nil else {
            lock.unlock()
            return
        }
        self.reason = reason
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        restoreDefaultSignalHandling()
        for waiter in waiting { waiter.resume(returning: reason) }
    }

    /// Idempotent, and called from both `stop` and `shutdown`.
    private func restoreDefaultSignalHandling() {
        lock.lock()
        let already = signalsRestored
        signalsRestored = true
        lock.unlock()
        guard !already else { return }
        for number in Self.handledSignals { signal(number, SIG_DFL) }
    }

    var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reason != nil
    }

    func wait() async -> StopReason {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let reason {
                lock.unlock()
                continuation.resume(returning: reason)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Tear down the sources and give stdin back the flags it came with.
    ///
    /// Restoring O_NONBLOCK matters more than it looks: stdin is usually shared
    /// with the parent shell, and leaving it non-blocking makes the *shell*
    /// misbehave after the tool exits.
    func shutdown() {
        lock.lock()
        let toCancel = sources
        sources.removeAll()
        let flags = restoreStdinFlags
        restoreStdinFlags = nil
        lock.unlock()

        for source in toCancel { source.cancel() }
        if let flags { _ = fcntl(STDIN_FILENO, F_SETFL, flags) }
        restoreDefaultSignalHandling()
    }

    private func append(_ source: DispatchSourceProtocol) {
        lock.lock()
        sources.append(source)
        lock.unlock()
    }
}
