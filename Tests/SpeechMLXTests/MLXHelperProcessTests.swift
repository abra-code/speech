// MLXHelperProcessTests.swift - spawning a helper, and stopping one that does
// not want to stop.
//
// The stubs here are shell scripts rather than the real binary, so the process
// half is tested on a machine with no MLX, no Metal and no GPU. The one test
// that does use `build/speech-mlx` skips itself when it is not built, and
// recognizes the failure a process with no GPU access produces - the same
// carve-out test.sh and build-speech-mlx.sh make, for the same reason: that
// failure is a property of where the test is running, not of what it is testing.

import Foundation
import Testing
@testable import SpeechMLX
import SpeechMLXProtocol

/// A throwaway directory holding a stub helper and the line it answers with.
private final class StubBinary {
    let directory: URL
    let executable: URL

    init(script: String, ready: MLXResponse? = nil) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speech-mlx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let ready {
            try MLXFrameWriter.frame(ready).write(to: directory.appendingPathComponent("ready.jsonl"))
        }
        executable = try StubExecutable.install(script: script, in: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// A box two threads can share, which is all this file needs of one.
private final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private let ready = MLXResponse.ready(
    .init(helper: "0.1.0", mlxAudio: "0.1.3", mlxSwift: "0.31.6", types: ["parakeet"],
          cacheMegabytes: 512))

private let quickTimeouts = MLXHelperConnection.Timeouts(
    handshake: 5, load: 5, control: 5, transcribeBase: 5, transcribeRealTimeFactor: 1)

@Suite("Running speech-mlx")
struct MLXHelperProcessTests {
    // MARK: - Finding it

    @Test("an explicit path is used as given")
    func locateUsesTheOverride() throws {
        let stub = try StubBinary(script: "#!/bin/sh\nexit 0\n")
        let found = MLXHelperProcess.locate(
            nextTo: nil, environment: [MLXHelperProcess.pathVariable: stub.executable.path])
        #expect(try found.get().path == stub.executable.path)
    }

    @Test("an explicit path that is not an executable is an error, not a fallback")
    func locateRejectsABadOverride() throws {
        // Falling back silently would run a different binary than the one the
        // variable names, and a measurement would then be attributed to a build
        // nobody chose.
        let stub = try StubBinary(script: "#!/bin/sh\nexit 0\n")
        let text = stub.directory.appendingPathComponent("notes.txt")
        try Data("not a binary".utf8).write(to: text)

        let found = MLXHelperProcess.locate(
            nextTo: stub.directory, environment: [MLXHelperProcess.pathVariable: text.path])
        guard case .failure(let error) = found else {
            Issue.record("a text file should not be accepted as the helper")
            return
        }
        #expect("\(error)".contains(MLXHelperProcess.pathVariable))
    }

    @Test("with no helper anywhere, the reason says where it looked")
    func locateSaysWhereItLooked() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speech-mlx-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let found = MLXHelperProcess.locate(nextTo: empty, environment: [:])
        guard case .failure(let error) = found else {
            Issue.record("an empty directory should not yield a helper")
            return
        }
        let message = "\(error)"
        #expect(message.contains(empty.path))
        #expect(message.contains("build-speech-mlx.sh"))
    }

    // MARK: - Starting and stopping

    @Test("a spawned helper handshakes, and closing its stdin is what stops it")
    func aSpawnedHelperStopsOnEndOfStdin() throws {
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                cat "$(dirname "$0")/ready.jsonl"
                cat > /dev/null
                exit 0
                """,
            ready: ready)
        let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)

        let hello = try helper.connection.handshake()
        #expect(hello.helper == "0.1.0")
        #expect(helper.isRunning)

        helper.stop(within: 5)
        #expect(helper.exitTermination == .exited(0))
    }

    @Test("a helper that will not read its stdin is killed")
    func aWedgedHelperIsKilled() throws {
        // No `cat`: this one never reads a byte, which is what a helper wedged
        // inside a Metal fault looks like from here. TERM is trapped as well,
        // so nothing but SIGKILL ends it.
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                trap '' TERM
                cat "$(dirname "$0")/ready.jsonl"
                while : ; do sleep 1 ; done
                """,
            ready: ready)
        let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)
        _ = try helper.connection.handshake()

        helper.stop(within: 0.3)
        #expect(helper.exitTermination == .signaled(SIGKILL))
    }

    @Test("the helper inherits no descriptors but its own three")
    func theHelperInheritsNothingElse() throws {
        // Anything left open travels with the helper for as long as it lives -
        // a model file, a socket, the terminal - and a helper is expected to
        // outlive a great many of those during an evaluation run.
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                # The check on fd 1 is what keeps this from passing vacuously:
                # if /dev/fd is not readable here, "not inherited" would be true
                # of every descriptor including the ones that ARE inherited.
                if [ ! -e /dev/fd/1 ] ; then echo NODEVFD >&2
                elif [ -e "/dev/fd/$1" ] ; then echo INHERITED >&2
                else echo CLEAN >&2 ; fi
                cat "$(dirname "$0")/ready.jsonl"
                cat > /dev/null
                """,
            ready: ready)

        let marker = stub.directory.appendingPathComponent("open-me.txt")
        try Data("x".utf8).write(to: marker)
        let opened = open(marker.path, O_RDONLY)
        try #require(opened >= 0)
        // Moved to a high number with F_DUPFD rather than dup2'd onto a chosen
        // one. Tests here run in parallel, and dup2 onto a fixed number closes
        // whatever that number already was - which in this suite is somebody
        // else's socket to a running helper.
        let descriptor = fcntl(opened, F_DUPFD, 200)
        close(opened)
        try #require(descriptor >= 200)
        defer { close(descriptor) }

        let helper = try MLXHelperProcess(
            executable: stub.executable, arguments: ["\(descriptor)"], timeouts: quickTimeouts)
        _ = try helper.connection.handshake()
        helper.stop(within: 5)
        #expect(helper.connection.standardErrorTail.contains("CLEAN"))
        #expect(!helper.connection.standardErrorTail.contains("INHERITED"))
    }

    @Test("a file that is not executable cannot be spawned, and says so")
    func aNonExecutableFails() throws {
        let stub = try StubBinary(script: "#!/bin/sh\nexit 0\n")
        let text = stub.directory.appendingPathComponent("notes.txt")
        try Data("not a binary".utf8).write(to: text)

        #expect(throws: MLXHelperError.self) {
            _ = try MLXHelperProcess(executable: text, timeouts: quickTimeouts)
        }
    }

    @Test("stopping twice is not an error, and does not change the answer")
    func stopIsIdempotent() throws {
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                cat "$(dirname "$0")/ready.jsonl"
                cat > /dev/null
                """,
            ready: ready)
        let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)
        _ = try helper.connection.handshake()

        helper.stop(within: 5)
        let first = helper.exitTermination
        helper.stop(within: 5)
        helper.kill()
        #expect(helper.exitTermination == first)
        #expect(first == .exited(0))
    }

    @Test("writing to a helper that has exited is an error, not a dead process")
    func writingToADeadHelperIsReported() throws {
        // A pipe would raise SIGPIPE here, whose default action would end this
        // test process rather than this test. The connection's sockets carry
        // SO_NOSIGPIPE so the write reports EPIPE instead, and a library gets
        // to do that without changing the signal disposition of whatever
        // program it was linked into.
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                cat "$(dirname "$0")/ready.jsonl"
                exit 0
                """,
            ready: ready)
        let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)
        _ = try helper.connection.handshake()
        #expect(helper.waitForExit(timeout: 5) == .exited(0))

        // Bigger than any socket buffer, so the write cannot quietly succeed
        // into a buffer the dead peer left behind.
        let audio = [Float](repeating: 0.5, count: 1 << 18)
        #expect(throws: MLXHelperError.self) {
            try helper.connection.transcribe(id: 1, samples: audio) { _ in }
        }
    }

    // MARK: - Identity

    @Test("the kill gate opens for a running helper and closes once it is gone")
    func theKillGateFollowsTheProcess() throws {
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                cat "$(dirname "$0")/ready.jsonl"
                cat > /dev/null
                """,
            ready: ready)
        let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)
        _ = try helper.connection.handshake()
        #expect(helper.wouldSignal)

        helper.stop(within: 5)
        // Reaped, so the number is anybody's now and nothing may be sent to it.
        #expect(!helper.wouldSignal)
    }

    @Test("the identity the kill gate uses tells two live helpers apart")
    func theIdentityTellsProcessesApart() throws {
        // The gate fails silently in both directions - it either signals a
        // stranger or leaves a helper holding a model in GPU memory - so the
        // only way to see which way it is failing is to ask it about processes
        // whose answers are known. These two are as alike as two processes get:
        // same executable, same parent, same everything the kernel records
        // except the pid and the microsecond they started.
        let script = """
            #!/bin/sh
            cat "$(dirname "$0")/ready.jsonl"
            cat > /dev/null
            """
        let first = try StubBinary(script: script, ready: ready)
        let second = try StubBinary(script: script, ready: ready)
        let one = try MLXHelperProcess(executable: first.executable, timeouts: quickTimeouts)
        let two = try MLXHelperProcess(executable: second.executable, timeouts: quickTimeouts)
        defer { one.stop(within: 5); two.stop(within: 5) }
        _ = try one.connection.handshake()
        _ = try two.connection.handshake()

        #expect(one.identityMatches(one.processIdentifier))
        #expect(two.identityMatches(two.processIdentifier))
        #expect(!one.identityMatches(two.processIdentifier))
        #expect(!two.identityMatches(one.processIdentifier))
        // And nothing at all for a pid that cannot exist.
        #expect(!one.identityMatches(-1))
    }

    @Test("the start time is read from the kernel, and survives the exec on the way in")
    func startTimeIsReadFromTheKernel() throws {
        let mine = try #require(MLXHelperProcess.startTime(of: getpid()))
        #expect(mine.tv_sec > 0)
        #expect(MLXHelperProcess.startTime(of: -1) == nil)

        // This is why the image path is not what is compared: /bin/sh becomes
        // /bin/bash on this system before the script runs a line, so a helper
        // identified by its image would be unkillable. Its start time does not
        // move.
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                cat "$(dirname "$0")/ready.jsonl"
                cat > /dev/null
                """,
            ready: ready)
        let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)
        defer { helper.stop(within: 5) }
        _ = try helper.connection.handshake()
        let running = try #require(MLXHelperProcess.startTime(of: helper.processIdentifier))
        #expect(running.tv_sec == helper.startTime.tv_sec)
        #expect(running.tv_usec == helper.startTime.tv_usec)
    }

    @Test("a child reaped behind this class's back is not signaled")
    func aChildReapedElsewhereIsNotSignaled() throws {
        // The one case the structure cannot cover: other code in this process
        // calling wait() with no pid of its own. The pid is then free for reuse
        // while nothing here knows it, which is what the identity check is for.
        let stub = try StubBinary(script: "#!/bin/sh\nexit 0\n")
        let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)
        let pid = helper.processIdentifier

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}

        #expect(!helper.wouldSignal)
        helper.kill()

        // And it returns at once rather than polling out its whole timeout for
        // a status that was taken by whoever reaped the child. The first
        // version of this waited the full second here and another two inside
        // `stop`, and nothing noticed because nothing timed it.
        let started = Date()
        #expect(helper.waitForExit(timeout: 5) == nil)
        helper.stop(within: 5)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("a helper can be killed from another thread while this one is blocked reading")
    func killFromAnotherThreadUnblocksTheReader() throws {
        // The property both file headers claim and no test covered: `kill` is
        // what cancellation does, and by definition it is called while some
        // other thread is inside a read that is not coming back.
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                trap '' TERM
                cat "$(dirname "$0")/ready.jsonl"
                while : ; do sleep 1 ; done
                """,
            ready: ready)
        let helper = try MLXHelperProcess(
            executable: stub.executable,
            timeouts: MLXHelperConnection.Timeouts(handshake: 30, load: 30, control: 30))
        _ = try helper.connection.handshake()

        // The reader blocks here: the stub says nothing more, and the deadline
        // is far enough out that a timeout cannot be what ends this.
        let finished = DispatchSemaphore(value: 0)
        let outcome = Locked<Result<Void, any Error>?>(nil)
        let reader = Thread {
            do {
                try helper.connection.unload()
                outcome.value = .success(())
            } catch {
                outcome.value = .failure(error)
            }
            finished.signal()
        }
        reader.start()

        // Long enough for the reader to be inside poll rather than still
        // starting up.
        Thread.sleep(forTimeInterval: 0.3)
        helper.kill()

        #expect(finished.wait(timeout: .now() + 10) == .success, "the reader never came back")
        guard case .failure(let error)? = outcome.value else {
            Issue.record("a killed helper should not have answered")
            return
        }
        #expect(error is MLXHelperError, "got \(error)")
        #expect(helper.waitForExit(timeout: 5) == .signaled(SIGKILL))
        helper.stop(within: 1)
    }

    @Test("the helper's own peak footprint is readable while it lives, and gone after")
    func peakFootprintFollowsTheProcess() throws {
        // The number `speech` reports for a row whose model is in another
        // process. Reading it in the parent instead answers a question nobody
        // asked: measured at 18 MB for a run holding a 459 MB model.
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                cat "$(dirname "$0")/ready.jsonl"
                cat > /dev/null
                """,
            ready: ready)
        let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)
        _ = try helper.connection.handshake()

        let footprint = try #require(helper.peakFootprintBytes())
        // A shell is small, but it is not nothing and it is not the parent:
        // this test process is far larger than any /bin/sh.
        #expect(footprint > 0)
        #expect(footprint < 100 << 20, "\(footprint) bytes is not a shell")

        helper.stop(within: 5)
        // The kernel keeps no ledger for a process that has gone, which is why
        // the engine samples this after every buffer rather than once at the
        // end.
        #expect(helper.peakFootprintBytes() == nil)
    }

    @Test("a helper does not outlive the object that owns it")
    func deinitStopsTheHelper() throws {
        // `deinit` calls `stop`, and a helper that outlived its owner would be
        // holding a model in GPU memory with nothing left to talk to it.
        let stub = try StubBinary(
            script: """
                #!/bin/sh
                cat "$(dirname "$0")/ready.jsonl"
                cat > /dev/null
                """,
            ready: ready)
        var pid: pid_t = 0
        do {
            let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)
            _ = try helper.connection.handshake()
            pid = helper.processIdentifier
            #expect(helper.isRunning)
        }
        // Reaped by the deinit, so the kernel has no record of it at all. A
        // still-running child would answer here.
        #expect(MLXHelperProcess.startTime(of: pid) == nil)
    }

    @Test("a helper that has already been reaped is not signaled again")
    func aReapedHelperIsNotSignaled() throws {
        let stub = try StubBinary(script: "#!/bin/sh\nexit 3\n")
        let helper = try MLXHelperProcess(executable: stub.executable, timeouts: quickTimeouts)
        #expect(helper.waitForExit(timeout: 5) == .exited(3))

        // The pid is now a number the kernel may hand to anybody. Nothing here
        // may send it a signal, and nothing here may crash for having been
        // asked to.
        helper.kill()
        helper.stop(within: 1)
        #expect(helper.exitTermination == .exited(3))
    }

    // MARK: - The real thing

    @Test("the built helper answers this supervisor")
    func theBuiltHelperAnswers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let binary = root.appendingPathComponent("build/speech-mlx")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            return  // Not built. ./build-speech-mlx.sh produces it.
        }

        let helper = try MLXHelperProcess(executable: binary, timeouts: quickTimeouts)
        do {
            let hello = try helper.connection.handshake()
            #expect(!hello.mlxAudio.isEmpty)
            #expect(!hello.types.isEmpty)
            try helper.connection.sayGoodbye()
            helper.stop(within: 10)
            #expect(helper.exitTermination == .exited(0))
        } catch {
            // A process with no GPU access dies inside MTLCopyAllDevices()
            // before it can say anything. That is where this is running, not
            // what was built, so it is not this test's to fail.
            let said = helper.connection.standardErrorTail
            let noGPU = said.contains("NSRangeException")
                && (said.contains("MTLCopyAllDevices") || said.contains("mlx4core5metal6Device"))
            if !noGPU {
                Issue.record("the built helper did not complete a handshake: \(error); it said: \(said)")
            }
            helper.stop(within: 5)
        }
    }
}
