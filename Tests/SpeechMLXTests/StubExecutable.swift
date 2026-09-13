// StubExecutable.swift - shell-script helpers that start without a wait.
//
// macOS assesses an executable the first time it is run, and it assesses one
// file at a time: a freshly written script costs about 0.3 s to start on its
// own, and 30 written and started at once took 8.3 s on an M5. These suites
// write a new stub for nearly every test and run the tests in parallel, so the
// last stubs in that queue missed their 3 and 5 second handshake deadlines, and
// the suites failed with "nothing arrived during the handshake" on a loaded
// machine and passed on an idle one.
//
// So a stub's `speech-mlx` is a symlink to one dispatcher, written and run once
// per test process, and the dispatcher hands the stub's own script to /bin/sh.
// A script read by a shell is not an executable being started, and is not
// assessed. The dispatcher sees the symlink's path as `$0`, so the script it
// runs sits beside the stub's other files, and `exec` keeps the pid the
// supervisor spawned.

import Foundation
@testable import SpeechMLX

enum StubExecutable {
    /// Writes `script` into `directory` and returns the path to spawn it by,
    /// named as the supervisor expects the helper to be named.
    static func install(script: String, in directory: URL) throws -> URL {
        let dispatcher = try sharedDispatcher.get()
        try Data(script.utf8).write(to: directory.appendingPathComponent(scriptName))
        let executable = directory.appendingPathComponent(MLXHelperProcess.executableName)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: dispatcher)
        return executable
    }

    private static let scriptName = "script.sh"

    /// Created once, and run once before anything is timed, so that the one
    /// assessment this file needs is paid outside every test's deadline.
    private static let sharedDispatcher: Result<URL, any Error> = Result(catching: {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("speech-mlx-stub-dispatcher-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dispatcher = directory.appendingPathComponent("dispatch")
        try Data("#!/bin/sh\nexec /bin/sh \"$(dirname \"$0\")/\(scriptName)\" \"$@\"\n".utf8)
            .write(to: dispatcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dispatcher.path)

        try Data("exit 0\n".utf8).write(to: directory.appendingPathComponent(scriptName))
        let warm = Process()
        warm.executableURL = dispatcher
        try warm.run()
        warm.waitUntilExit()
        return dispatcher
    })
}
