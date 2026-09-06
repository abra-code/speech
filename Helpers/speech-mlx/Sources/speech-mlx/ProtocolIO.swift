// ProtocolIO.swift - keeping the response stream free of everything else.
//
// This is the one implementation rule the protocol imposes, and it is not a
// style preference. MLX Audio writes to stdout with plain `print`, 71 times
// across the two modules this helper links, and one of those is on a path this
// helper actually takes: `Qwen3ASRModel.fromModelDirectory` synthesizes a
// tokenizer.json when the repository ships none - which the mlx-community
// Qwen3-ASR repositories do not - and prints "Generated tokenizer.json at:
// ..." unconditionally while doing it. That line would land in the middle of
// the JSONL response stream and corrupt it, on a successful load rather than on
// an error path, so a test that never loads a model would never see it.
//
// The rescue is written for the class rather than for that one call. Several
// other prints on nearby paths are gated on a `verbose` flag this helper sets
// to false, and the ones in the library's model resolver belong to a download
// path this helper never takes - but all of that is one upstream edit away from
// being untrue, and the cost of not depending on it is four lines.
//
// So fd 1 is taken away from the libraries at startup: it is duplicated to a
// private descriptor, and then stderr is dup'd over it. Everything that prints
// goes to stderr along with every other diagnostic, and the protocol writes to
// the descriptor it kept.

import Foundation
import SpeechMLXProtocol

/// The response stream: the real stdout, hidden from anything that might print.
final class ProtocolOutput: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    /// Take fd 1 for the protocol and point the number 1 at stderr.
    ///
    /// Order matters: the duplicate is made before stderr is put in its place,
    /// or the private descriptor would be a second handle on stderr and every
    /// response would be written into the diagnostics.
    static func claimStdout() -> ProtocolOutput {
        // A closed read end must arrive as a write error rather than as a
        // signal. Without this the default SIGPIPE disposition kills the
        // process before the `catch` below can run, and that catch would be
        // dead code claiming to handle a case it never sees.
        signal(SIGPIPE, SIG_IGN)
        let saved = dup(STDOUT_FILENO)
        precondition(saved >= 0, "could not duplicate stdout: \(String(cString: strerror(errno)))")
        precondition(dup2(STDERR_FILENO, STDOUT_FILENO) >= 0,
                     "could not redirect stdout: \(String(cString: strerror(errno)))")
        // Line buffering on what is now stderr, so a library's diagnostics
        // appear while they are still relevant rather than in a block at exit.
        // It is not what protects the response stream: after the dup2 above,
        // fd 1 is stderr's target, so a flush of C stdio's buffer goes there
        // and cannot reach the descriptor this function returns.
        setvbuf(stdout, nil, _IOLBF, 0)
        return ProtocolOutput(handle: FileHandle(fileDescriptor: saved, closeOnDealloc: false))
    }

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// One response, whole.
    ///
    /// The lock is not load-bearing today: every call comes from the single
    /// sequential task in Helper.swift, and the model libraries never call it.
    /// It is here because a partially written line is indistinguishable from a
    /// corrupt one on the other side, and that is a bad thing to discover after
    /// the first caller that answers from somewhere else.
    func send(_ response: MLXResponse) {
        guard let bytes = try? MLXFrameWriter.frame(response) else {
            // Encoding a response cannot fail for any value this program
            // constructs; if it ever does, saying so on stderr is better than
            // a silently missing reply.
            FileHandle.standardError.write(Data("speech-mlx: could not encode a response\n".utf8))
            return
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            // Two different endings share this catch and must not share an
            // exit code. A closed read end - the parent went away - is not a
            // failure: there is nowhere left to report anything, and
            // continuing to transcribe for a reader that stopped listening
            // only burns the machine. Anything else is a real write failure,
            // and this stream is not always a pipe: `build-speech-mlx.sh` and
            // `test.sh` both redirect it to a file, where a full disk would
            // otherwise produce a truncated transcript and an exit code that
            // says everything went fine.
            if Self.isBrokenPipe(error) { exit(0) }
            note("could not write a response: \(error)")
            exit(1)
        }
    }
}

extension ProtocolOutput {
    /// Whether a write failed because the reader went away.
    ///
    /// Foundation wraps the POSIX error rather than throwing it, and how deeply
    /// it wraps it has changed between releases, so this unwraps rather than
    /// testing one shape. Anything it cannot recognize is treated as a real
    /// failure, which is the safe direction: the cost of being wrong that way
    /// is a non-zero exit on a run that was ending anyway, and the cost of the
    /// other way is a truncated transcript reported as success.
    static func isBrokenPipe(_ error: any Error) -> Bool {
        if let posix = error as? POSIXError { return posix.code == .EPIPE }
        let wrapped = error as NSError
        if wrapped.domain == NSPOSIXErrorDomain, wrapped.code == Int(EPIPE) { return true }
        if let underlying = wrapped.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isBrokenPipe(underlying)
        }
        return false
    }
}

/// Diagnostics. Everything here is for a person reading a log, never for the
/// parent to parse.
///
/// It goes to stderr, which after `claimStdout` is also where fd 1 points, so
/// it can never land in the response stream however it is reached.
func note(_ message: String) {
    FileHandle.standardError.write(Data("speech-mlx: \(message)\n".utf8))
}
