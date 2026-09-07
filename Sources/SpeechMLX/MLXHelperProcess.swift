// MLXHelperProcess.swift - spawning speech-mlx, and stopping it on purpose.
//
// WHY posix_spawn AND NOT Foundation.Process. The plan asks for a kill that
// verifies the pid before it signals, and the reason is pid reuse: a child that
// has exited AND been reaped leaves a number the kernel is free to hand to
// somebody else, so a stale pid plus a SIGKILL is a way to end a stranger's
// process. Foundation.Process reaps on its own, on its own thread, at a moment
// this code does not choose - so with it the window is real and unclosable.
// Reaping this child here instead makes the guarantee structural: between
// posix_spawn and our own waitpid the child is either running or a zombie, and
// in both states the pid is ours and nobody else's. `reaped` is the flag that
// says which side of that line we are on, and every signal is sent under the
// lock that owns it.
//
// The identity check on top of that is not redundancy for its own sake. It
// catches the one case the structure cannot: some other code in this process
// calling wait() with no pid of its own, reaping our child behind our back and
// clearing the number for reuse while `reaped` is still false. A mismatch means
// no signal at all - the helper is stopped by closing its stdin instead, which
// the protocol already defines as "exit", and which needs no pid to be right.
//
// WHAT THE IDENTITY IS, AND WHAT IT IS NOT. The plan calls this an argv check,
// and argv is the wrong thing to read twice over: a process may set argv[0] to
// whatever it likes, so it is forgeable by the very thing being checked. The
// executable path from the kernel is not forgeable, but it is not stable
// either - a process may exec, and one does so here on the way to being tested:
// spawning a shell script gives a pid running /bin/sh that a moment later is
// running /bin/bash. A check on the image would therefore refuse to kill a
// perfectly ordinary process, and refusing to kill is this gate's dangerous
// direction, because what it leaves behind is a helper holding a model in GPU
// memory. So the identity is the pair the kernel guarantees instead: the
// process start time, which survives an exec and cannot be shared by a later
// process on the same number, because that number is only free once the process
// that had it has ended. Nothing else is compared: a parent-pid check was here
// too and was removed, because no test can distinguish a version that makes it
// from one that does not - a process with our child's start time to the
// microsecond and a different parent cannot be constructed - and a rule whose
// absence nothing can notice is not a rule, it is decoration on one.

import Foundation
import SpeechMLXProtocol

public final class MLXHelperProcess: @unchecked Sendable {
    /// How the helper stopped.
    public enum Termination: Equatable, Sendable {
        case exited(Int32)
        case signaled(Int32)

        public var description: String {
            switch self {
            case .exited(let code): return "exit \(code)"
            case .signaled(let signal): return "signal \(signal)"
            }
        }
    }

    /// The environment variable that overrides where the helper is looked for,
    /// named after SPEECH_BIN, which is how the applet points at a `speech`
    /// that is not the one beside it.
    public static let pathVariable = "SPEECH_MLX_BIN"

    /// The name the build scripts produce.
    public static let executableName = "speech-mlx"

    public let executable: URL
    public let processIdentifier: pid_t
    public let connection: MLXHelperConnection

    /// The image the pid was running the moment it was spawned, as the kernel
    /// reported it. Read once rather than assumed from `executable`, because
    /// the two are not always the same file: a script is spawned by path and
    /// runs its interpreter, and the question worth asking later is "is this
    /// pid still running what it was running", not "is it running the name I
    /// typed". Falls back to the resolved path when the kernel will not say.
    /// When the kernel says this pid started. Internal rather than private so
    /// a test can assert what was captured: a wrong value here disables the
    /// kill silently.
    let startTime: timeval
    private let lock = NSLock()
    private var reaped = false
    private var termination: Termination?
    /// Reaped by something else, so its exit status is gone. Distinct from
    /// "still running", which is what a bare nil termination would say.
    private var endedWithoutAStatus = false

    // MARK: - Finding it

    /// Where the helper is, or why there is none.
    ///
    /// An explicit `SPEECH_MLX_BIN` that does not point at an executable is an
    /// error rather than a reason to look elsewhere: someone who set it wants
    /// that binary, and silently running a different one is how a measurement
    /// gets attributed to the wrong build.
    public static func locate(
        nextTo directory: URL? = defaultSearchDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<URL, MLXHelperError> {
        if let override = environment[pathVariable], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                return .failure(.notFound(
                    "\(pathVariable) is set to \(override), which is not an executable file"))
            }
            return .success(url)
        }
        guard let directory else {
            return .failure(.notFound(
                "no \(executableName): there is nowhere to look, and \(pathVariable) is not set"))
        }
        let candidate = directory.appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return .failure(.notFound(
                "no \(executableName) beside \(directory.path)."
                    + " Build it with ./build-speech-mlx.sh, or set \(pathVariable)"))
        }
        return .success(candidate)
    }

    /// The directory holding the running binary. The helper travels with
    /// `speech`, so this is where it belongs and where the build scripts put it.
    public static func defaultSearchDirectory() -> URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    // MARK: - Starting it

    public init(
        executable: URL,
        arguments: [String] = [],
        timeouts: MLXHelperConnection.Timeouts = MLXHelperConnection.Timeouts(),
        tailLimit: Int = 16 << 10
    ) throws {
        self.executable = executable

        // Socket pairs rather than pipes for the two channels this process
        // writes to or reads from, so that SO_NOSIGPIPE can be set on our ends.
        // A pipe would leave writing to a dead helper raising SIGPIPE, whose
        // default action is to kill US - and the fix for that is to change the
        // signal disposition for the whole process, which is not a library's to
        // change. stderr is a plain pipe: nothing here ever writes to it.
        let requests = try Self.makeSocketPair()
        let responses = try Self.makeSocketPair(closing: [requests.0, requests.1])
        let diagnostics = try Self.makePipe(closing: [requests.0, requests.1, responses.0, responses.1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, requests.1, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, responses.1, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, diagnostics.1, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // Everything except the three descriptors dup'd above is closed in the
        // child. Without it the helper inherits whatever this process happens to
        // have open - model files, sockets, the terminal - and holds them for as
        // long as it lives.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argv.append(nil)

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)

        for pointer in argv where pointer != nil { free(pointer) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(requests.1)
        close(responses.1)
        close(diagnostics.1)

        guard status == 0 else {
            close(requests.0)
            close(responses.0)
            close(diagnostics.0)
            throw MLXHelperError.spawnFailed(
                "\(executable.path): \(String(cString: strerror(status)))")
        }

        self.processIdentifier = pid
        // Read before anything else is done with the child: this is the value
        // every later signal is gated on, and a zero here would gate on
        // nothing.
        self.startTime = Self.startTime(of: pid) ?? timeval(tv_sec: 0, tv_usec: 0)
        self.connection = MLXHelperConnection(
            readFD: responses.0, writeFD: requests.0, errorFD: diagnostics.0,
            timeouts: timeouts, tailLimit: tailLimit)
    }

    deinit {
        // A helper that outlives the object that owns it would hold a model in
        // GPU memory with nothing left to talk to it.
        stop(within: 0.5)
    }

    // MARK: - Stopping it

    /// Ends the session the way the protocol says to: close stdin, wait, and
    /// only then signal.
    ///
    /// UNLIKE `kill`, THIS IS NOT SAFE FROM ANY THREAD. It closes the
    /// connection's descriptors, and closing a descriptor another thread is
    /// sitting in `poll` on is a race whose good outcome is an error and whose
    /// bad one is that the number gets reused underneath the reader. Call it
    /// from whatever owns the connection - `MLXHelperRunner` does it on the
    /// same queue as every other connection call - and use `kill` from
    /// anywhere else.
    ///
    /// The close is the part that does the work. `bye` or the end of stdin is
    /// the helper's documented stop, it needs no pid to be correct, and it lets
    /// the helper put down the model rather than being torn away from it. The
    /// signal is for a helper that is not reading its stdin any more - wedged
    /// inside a Metal fault, say - and it comes last for that reason.
    public func stop(within seconds: Double) {
        connection.closeRequests()
        if waitForExit(timeout: seconds) != nil {
            connection.close()
            return
        }
        kill()
        _ = waitForExit(timeout: 2)
        connection.close()
    }

    /// Kills the helper now, for a run the caller has given up on.
    ///
    /// This is what cancellation does: MLX generation is a synchronous call
    /// that does not return early, so there is no message that would stop it in
    /// time, and the protocol says so.
    public func kill() {
        lock.lock()
        defer { lock.unlock() }
        guard canSignalLocked() else { return }
        _ = Darwin.kill(processIdentifier, SIGKILL)
    }

    /// Whether a signal would be delivered right now. Internal so that a test
    /// can assert the gate opens and closes, which is the one thing about it
    /// that cannot be observed from the outside: its failure is silence.
    var wouldSignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return canSignalLocked()
    }

    private func canSignalLocked() -> Bool {
        guard !reaped, processIdentifier > 0 else { return false }
        return identityMatches(processIdentifier)
    }

    /// Has it stopped, and how. nil while it is still running.
    public var exitTermination: Termination? {
        _ = reapIfPossible()
        lock.lock()
        defer { lock.unlock() }
        return termination
    }

    public var isRunning: Bool { exitTermination == nil && !hasBeenReaped }

    private var hasBeenReaped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reaped
    }

    private var hasEndedWithoutAStatus: Bool {
        lock.lock()
        defer { lock.unlock() }
        return endedWithoutAStatus
    }

    /// Waits for the helper to exit, and reaps it. Returns nil on timeout,
    /// which means it is still running.
    @discardableResult
    public func waitForExit(timeout: Double) -> Termination? {
        let deadline = Deadline(seconds: timeout)
        while true {
            if let termination = reapIfPossible() { return termination }
            // Gone, with its status taken by whoever reaped it. Waiting longer
            // cannot produce one.
            if hasEndedWithoutAStatus { return nil }
            if deadline.hasPassed { return reapIfPossible() }
            // Polled rather than blocked in waitpid, so that a kill from
            // another thread is never waiting on a lock this one is holding.
            usleep(2000)
        }
    }

    @discardableResult
    private func reapIfPossible() -> Termination? {
        lock.lock()
        defer { lock.unlock() }
        if reaped { return termination }
        var status: Int32 = 0
        let rc = waitpid(processIdentifier, &status, WNOHANG)
        if rc == processIdentifier {
            reaped = true
            termination = Self.termination(from: status)
            return termination
        }
        if rc < 0, errno == ECHILD {
            // Somebody else reaped it. The number is no longer ours to signal,
            // which is exactly what this flag stops - and no status will ever
            // arrive for it, which is what `endedWithoutAStatus` stops: without
            // that, `waitForExit` polls its whole timeout waiting for a value
            // that cannot come, and `stop` does it twice.
            reaped = true
            endedWithoutAStatus = true
            return nil
        }
        return nil
    }

    private static func termination(from status: Int32) -> Termination {
        // The WIFEXITED/WEXITSTATUS macros are not imported into Swift, so the
        // wait status is decoded here. Low seven bits are the signal that ended
        // it, zero when it exited normally; the next eight are the exit code.
        let signal = status & 0x7F
        if signal == 0 { return .exited((status >> 8) & 0xFF) }
        return .signaled(signal)
    }

    // MARK: - Identity

    /// Is the process behind this pid the one we spawned?
    ///
    /// Internal so a test can ask it about a pid that is emphatically not ours:
    /// this gate fails silently in both directions, and the only way to see
    /// which way it is failing is to ask it about a process whose answer is
    /// known.
    ///
    /// A captured start time of zero means the kernel would not answer when the
    /// child was spawned. That needs no guard of its own: no running process
    /// started at time zero, so the comparison below already fails and the gate
    /// is already shut. A guard for it was here and was removed for being a
    /// branch no test could reach.
    func identityMatches(_ pid: pid_t) -> Bool {
        guard let started = Self.startTime(of: pid) else { return false }
        return started.tv_sec == startTime.tv_sec && started.tv_usec == startTime.tv_usec
    }

    /// When the kernel recorded this pid as starting. Microsecond resolution,
    /// and a pid cannot be reissued to a process that started at the same
    /// microsecond as the one that had it.
    static func startTime(of pid: pid_t) -> timeval? {
        processInfo(of: pid).map { $0.kp_proc.p_un.__p_starttime }
    }

    private static func processInfo(of pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        // A pid nobody is using answers with rc 0 and no bytes, which is why
        // the size is checked rather than only the return value.
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return info
    }

    // MARK: - What it cost

    /// The highest physical footprint the helper has reached, in bytes, or nil
    /// once it has exited.
    ///
    /// This is the number `speech` reports for an `mlx` row, and reading it
    /// here rather than in the parent is the whole point: the model is in the
    /// other process, so the parent's own footprint answers a question nobody
    /// asked. Measured on parakeet-tdt_ctc-110m, the parent peaked at 18 MB for
    /// a run whose model is 459 MB on disk.
    ///
    /// `ri_lifetime_max_phys_footprint` is the same ledger `TASK_VM_INFO`
    /// reports as `ledger_phys_footprint_peak` for this task, so an `mlx` row's
    /// figure and every other row's figure are the same measurement. There is
    /// no cross-process equivalent of the Neural Engine ledger the in-process
    /// instrument also sums, and none is needed: MLX is Metal, and nothing in
    /// the helper touches the ANE.
    ///
    /// Must be read while the helper is alive. The kernel keeps no record of a
    /// process that has gone, which is why `transcribe` samples it after every
    /// buffer rather than once at the end.
    public func peakFootprintBytes() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped, processIdentifier > 0, identityMatches(processIdentifier) else { return nil }
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0, info.ri_lifetime_max_phys_footprint > 0 else { return nil }
        return Int64(info.ri_lifetime_max_phys_footprint)
    }

    // MARK: - Descriptors

    /// `closing` is what has already been opened by the time this is called:
    /// an initializer that throws runs no `deinit`, so anything opened before
    /// the failure has to be closed here or it is leaked for the life of the
    /// process. The case that makes it real is an fd limit reached between the
    /// first pair and the second.
    private static func makeSocketPair(closing others: [Int32] = []) throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            for descriptor in others { close(descriptor) }
            throw MLXHelperError.spawnFailed("socketpair: \(String(cString: strerror(errno)))")
        }
        var on: Int32 = 1
        setsockopt(
            descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return (descriptors[0], descriptors[1])
    }

    private static func makePipe(closing others: [Int32]) throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            for descriptor in others { close(descriptor) }
            throw MLXHelperError.spawnFailed("pipe: \(String(cString: strerror(errno)))")
        }
        return (descriptors[0], descriptors[1])
    }
}
