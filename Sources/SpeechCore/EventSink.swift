// EventSink.swift - the one place anything is written to stdout or stderr.
//
// Two modes over one call site. Under --json every event becomes a line of
// JSONL on stdout and nothing else is ever printed there, so a consumer can
// parse the stream without filtering. Without --json the tool behaves like a
// unix filter: the transcript goes to stdout and everything else - progress,
// warnings, errors - goes to stderr, so `speech transcribe x.wav > out.txt`
// gives a clean file and a live status line in the terminal.
//
// Thread-safe by a lock rather than an actor: engines emit from whatever
// context they finish on, and making every emit an await would force `async`
// through the synchronous progress callbacks that FluidAudio and AVFoundation
// hand us.

import Foundation

public final class EventSink: @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        case jsonl
        case human
    }

    private let mode: Mode
    private let out: FileHandle
    private let err: FileHandle
    /// --log: every event, as JSONL, whatever the mode. The applet runs the
    /// tool in human mode for the transcript and reads this file when something
    /// went wrong, so the log must not depend on the output mode.
    private let log: FileHandle?
    private let start: ContinuousClock.Instant
    private let clock = ContinuousClock()
    private let lock = NSLock()
    private let encoder: JSONEncoder
    /// True when stderr is a terminal: partial results overwrite one line with
    /// a carriage return instead of scrolling hundreds of lines past. --verbose
    /// forces it on so a redirected run still records what happened.
    private let showsStatus: Bool
    private var statusLineActive = false

    public init(
        mode: Mode,
        out: FileHandle = .standardOutput,
        err: FileHandle = .standardError,
        logURL: URL? = nil,
        verbose: Bool = false
    ) {
        self.mode = mode
        self.out = out
        self.err = err
        self.start = ContinuousClock().now
        self.encoder = JSONEncoder()
        // Never .prettyPrinted: one object per line is the format. But do sort
        // the keys. JSONEncoder's unsorted order comes out of a dictionary and
        // varies between runs of the same build, which makes two log files
        // impossible to diff and a golden-file test impossible to write. The
        // cost is that `type` no longer leads the line; a reader parses JSON
        // anyway.
        self.encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let isTTY = isatty(err.fileDescriptor) == 1
        self.showsStatus = isTTY || verbose

        if let logURL {
            let manager = FileManager.default
            if !manager.fileExists(atPath: logURL.path) {
                try? manager.createDirectory(
                    at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                manager.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try? FileHandle(forWritingTo: logURL)
            _ = try? handle?.seekToEnd()
            self.log = handle
            if handle == nil {
                // Say so. The applet reads this file to find out why a run
                // failed, and a silently absent log turns one problem into two.
                try? err.write(contentsOf: Data(
                    "warning: cannot write the log at \(logURL.path); continuing without it\n".utf8))
            }
        } else {
            self.log = nil
        }
    }

    deinit {
        try? log?.close()
    }

    /// Seconds since this sink was created, which is close enough to process
    /// start that the plan's "seconds since process start" holds - the sink is
    /// built before any work in every command.
    public var elapsed: Double {
        Double((clock.now - start) / .milliseconds(1)) / 1000.0
    }

    public func emit(_ payload: SpeechEvent.Payload) {
        let event = SpeechEvent(t: elapsed, payload: payload)
        let line: Data?
        if mode == .jsonl || log != nil {
            line = (try? encoder.encode(event)).map { $0 + Data([0x0A]) }
        } else {
            line = nil
        }
        lock.lock()
        defer { lock.unlock() }
        if let log, let line { write(line, to: log) }
        switch mode {
        case .jsonl:
            if let line { write(line, to: out) }
        case .human:
            writeHuman(payload)
        }
    }

    // MARK: - Convenience emitters

    public func warning(_ message: String, code: String = "warning") {
        emit(.warning(.init(message: message, code: code)))
    }

    public func error(_ error: SpeechError) {
        emit(.error(.init(error)))
    }

    public func modelProgress(model: String, _ progress: LoadProgress) {
        emit(.modelProgress(.init(model: model, progress: progress)))
    }

    /// Plain text that belongs on stdout in human mode and nowhere at all in
    /// JSONL mode - a transcript line, a table row from `models list`. Anything
    /// a machine should see must be an event instead.
    public func text(_ string: String) {
        lock.lock()
        defer { lock.unlock() }
        guard mode == .human else { return }
        clearStatusLineLocked()
        write(Data((string + "\n").utf8), to: out)
    }

    /// Machine-readable payload that is not an event: the JSON body of
    /// `speech catalog` or `speech info --json`. Written to stdout in both
    /// modes, because these commands are a request for exactly that document.
    public func document(_ string: String) {
        lock.lock()
        defer { lock.unlock() }
        clearStatusLineLocked()
        write(Data((string + "\n").utf8), to: out)
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        clearStatusLineLocked()
    }

    // MARK: - Human formatting

    private func writeHuman(_ payload: SpeechEvent.Payload) {
        switch payload {
        case .engineReady(let e):
            status("Engine \(e.model) ready in \(fmt(e.loadSeconds))s")
        case .modelEntry:
            // Nothing. `models list` and `models status` print their own
            // aligned table through `text()`; rendering the event too would
            // duplicate every row.
            break
        case .modelProgress(let p):
            switch p.phase {
            case .downloading:
                if let done = p.bytesDone, let total = p.bytesTotal, total > 0 {
                    status("Downloading \(SystemInfo.formatBytes(done)) of \(SystemInfo.formatBytes(total))"
                        + " (\(percent(p.fraction)))...")
                } else {
                    status("Downloading \(p.file ?? p.model)...")
                }
            case .listing:
                status("Checking \(p.model)...")
            case .compiling:
                status("Preparing \(p.file ?? p.model)...")
            case .installing:
                status("Installing \(p.file ?? p.model) \(percent(p.fraction))...")
            }
        case .modelInstalled(let m):
            if let bytes = m.bytes {
                statusDone("Installed \(m.model) - \(SystemInfo.formatBytes(bytes))")
            } else {
                statusDone("Installed \(m.model)")
            }
        case .progress(let p):
            status("Transcribing \(fmt(p.audioSecondsDone))s of \(fmt(p.audioSecondsTotal))s"
                + " (\(percent(p.fraction)))...")
        case .segmentPartial(let s):
            // Volatile by definition: it belongs on the status line, never in
            // the transcript on stdout, or a pipe would collect every revision.
            status(s.text)
        case .segmentFinal(let s):
            clearStatusLineLocked()
            write(Data((s.text + "\n").utf8), to: out)
        case .segmentRefined(let r):
            clearStatusLineLocked()
            write(Data(("[refined] " + r.segment.text + "\n").utf8), to: out)
        case .warning(let w):
            statusDone("warning: \(w.message)")
        case .error(let e):
            statusDone("error: \(e.message)")
        case .done(let d):
            statusDone("Done: \(d.segments) segments, \(fmt(d.audioSeconds))s audio in"
                + " \(fmt(d.wallSeconds))s (\(fmt(d.rtfx))x real time),"
                + " peak memory \(SystemInfo.formatBytes(d.peakMemoryBytes))")
        case .evalRow(let r):
            statusDone(String(format: "[%d] WER %.2f%%  CER %.2f%%  %@",
                              r.index, r.wer * 100, r.cer * 100,
                              (r.path as NSString).lastPathComponent))
        case .evalSummary(let s):
            statusDone(String(
                format: "%@ %@: %d rows, WER %.2f%%, CER %.2f%%, %.1fx real time, peak memory %@",
                s.model, s.language ?? "-", s.rows, s.wer * 100, s.cer * 100, s.rtfx,
                SystemInfo.formatBytes(s.peakMemoryBytes)))
        }
    }

    /// A transient line on stderr. On a terminal it overwrites the previous
    /// one; when redirected it is dropped entirely, because a log file full of
    /// half-second progress updates is noise, not a record.
    private func status(_ message: String) {
        guard showsStatus else { return }
        let trimmed = message.replacingOccurrences(of: "\n", with: " ")
        write(Data(("\u{1B}[2K\r" + trimmed).utf8), to: err)
        statusLineActive = true
    }

    /// A line that stays: warnings, errors, summaries. Always written, terminal
    /// or not, after clearing any status line in progress.
    private func statusDone(_ message: String) {
        clearStatusLineLocked()
        write(Data((message + "\n").utf8), to: err)
    }

    private func clearStatusLineLocked() {
        guard statusLineActive else { return }
        write(Data("\u{1B}[2K\r".utf8), to: err)
        statusLineActive = false
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "?" }
        return String(format: "%.0f%%", fraction * 100)
    }

    /// Writes are best-effort. A closed stdout (`speech ... | head -1`) must not
    /// crash the tool, so EPIPE is swallowed here; main() ignores SIGPIPE so the
    /// signal does not kill the process before this code runs.
    private func write(_ data: Data, to handle: FileHandle) {
        try? handle.write(contentsOf: data)
    }
}
