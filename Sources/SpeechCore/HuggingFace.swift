// HuggingFace.swift - the only code in the program that talks to huggingface.co.
//
// FluidAudio brought its own downloader; the `ggml` rows are a single GGUF file
// fetched over plain HTTP, so this is ours to write. Two things make it more
// than a one-line `URLSession.download`.
//
// A row is between half a gigabyte and three gigabytes, and a download that
// dies at 90% must resume rather than start again. So the bytes land in a
// sibling `.download` file that survives the failure, and the next attempt
// sends `Range: bytes=<what we have>-`. The model store's `.partial` marker
// still owns the question of whether the *row* is installed - this file only
// owns whether the *transfer* is finished.
//
// And a truncated model must never be presented as a working one. ggml will
// happily map a short GGUF and fail deep inside a load with a message about
// tensor shapes, so every transfer here is checked against a byte count the
// server and the tree API agree on, and the temp file is renamed into place
// only after that check passes.

import Foundation

/// One file in a repository, as the tree API reports it.
public struct HFRepoFile: Sendable, Equatable {
    public let path: String
    /// Bytes, or nil when the API did not say. Optional rather than zero
    /// because the two mean opposite things to a downloader: zero is a claim
    /// worth enforcing, and "unknown" is a reason to trust the server instead.
    /// Collapsing them produced "the catalog expects 0 B but the server offers
    /// 2 GB; the repository has changed", which is wrong and unactionable.
    public let size: Int64?
    /// The LFS object id - the content hash of the *object*, not of the pointer
    /// file. This is what makes a resumed download safe: it identifies the
    /// revision the bytes on disk came from.
    public let oid: String?

    public init(path: String, size: Int64?, oid: String? = nil) {
        self.path = path
        self.size = size
        self.oid = oid
    }
}

public enum HuggingFace {
    /// Overridable so a test can point at a local server and so a mirror is a
    /// configuration change rather than a code change.
    ///
    /// Restricted to TLS, with plain HTTP allowed only against loopback (which
    /// is all a test seam needs). A 2 GB weights download has no signature over
    /// it beyond the length and object-id checks below, so letting an
    /// environment variable drop it to cleartext would hand anyone on the path
    /// the ability to substitute the model.
    public static var endpoint: URL {
        if let raw = ProcessInfo.processInfo.environment["HF_ENDPOINT"],
           let url = URL(string: raw), isAcceptableEndpoint(url) {
            return url
        }
        return URL(string: "https://huggingface.co")!
    }

    static func isAcceptableEndpoint(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return url.host != nil
        case "http":
            let host = url.host?.lowercased()
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default:
            return false
        }
    }

    /// Rejects a repository or file name that would not survive being pasted
    /// into a URL path.
    ///
    /// Not reachable today - every repo and file name comes from the hardcoded
    /// catalog - but `appendingPathComponent` neither resolves nor rejects
    /// `..`, so `resolve/main/../../evil` reaches the server as written. Stage 3
    /// takes ids from a TSV, which is exactly the change that would arm it.
    static func validate(pathPart: String, label: String) throws {
        let bad: String?
        if pathPart.isEmpty {
            bad = "is empty"
        } else if pathPart.hasPrefix("/") {
            bad = "starts with '/'"
        } else if pathPart.contains("\0") {
            bad = "contains a null byte"
        } else if pathPart.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) {
            bad = "contains a path traversal component"
        } else {
            bad = nil
        }
        if let bad {
            throw SpeechError.usage("the \(label) '\(pathPart)' \(bad)")
        }
    }

    /// `https://huggingface.co/api/models/<repo>/tree/main`
    public static func treeURL(repo: String) -> URL {
        endpoint
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("tree", isDirectory: true)
            .appendingPathComponent("main", isDirectory: false)
    }

    /// `https://huggingface.co/<repo>/resolve/main/<file>`
    public static func resolveURL(repo: String, file: String) -> URL {
        endpoint
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent("resolve", isDirectory: true)
            .appendingPathComponent("main", isDirectory: true)
            .appendingPathComponent(file, isDirectory: false)
    }

    // MARK: - Listing

    /// The repository's files and their sizes.
    ///
    /// Used for the catalog's size column and to know a download's total before
    /// it starts. The API answers with a mix of regular files and LFS pointers;
    /// for an LFS entry the useful number is `lfs.size` (the real object), not
    /// `size` (the ~130-byte pointer), and every GGUF in these repos is LFS - so
    /// reading the wrong field reports a 2 GB model as 130 bytes and would make
    /// every download fail its length check.
    public static func tree(repo: String, session: URLSession = .shared) async throws -> [HFRepoFile] {
        try validate(pathPart: repo, label: "repository")
        let url = treeURL(repo: repo)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                throw CancellationError()
            }
            throw SpeechError.runtime(
                "cannot reach \(url.absoluteString): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SpeechError.runtime("\(url.absoluteString) did not answer over HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SpeechError.runtime(refusal(status: http.statusCode, repo: repo))
        }
        return try parseTree(data, describedAs: url.absoluteString)
    }

    /// What a refused request means, in words a person can act on without
    /// knowing HTTP status codes. Shown as it is by Speech.app.
    ///
    /// Hugging Face answers 401, not 404, for a repository that does not
    /// exist, so that a private one's existence is not given away. A gated
    /// repository whose terms have not been accepted lists its files (the tree
    /// API answers 200) and then answers 401 to the download itself, so that
    /// case arrives here with `file` set. A file missing from a repository that
    /// exists is a 404 on the download. The download's `X-Error-Code` header
    /// tells those two apart (`GatedRepo`, `EntryNotFound`); without it this
    /// program, which never signs in, cannot, and says so.
    public static func refusal(
        status: Int, repo: String, file: String? = nil, errorCode: String? = nil
    ) -> String {
        let signIn = "speech does not sign in to Hugging Face, so private repositories"
            + " and ones that ask you to accept terms first cannot be used"
        switch errorCode {
        case "GatedRepo":
            return "'\(repo)' on Hugging Face asks people to accept its terms on the Hugging Face"
                + " website before downloading; speech does not sign in to Hugging Face, so it"
                + " cannot download this model."
        case "EntryNotFound":
            if let file {
                return "'\(repo)' on Hugging Face has no file '\(file)'."
            }
        default:
            break
        }
        switch status {
        case 401, 404:
            if let file {
                return "Hugging Face has no file '\(file)' in a public repository named '\(repo)'."
                    + " Check the names; \(signIn)."
            }
            return "Hugging Face has no public repository named '\(repo)'."
                + " Check the spelling of the owner and the name; \(signIn)."
        case 403:
            return "Hugging Face would not give access to '\(repo)'; \(signIn)."
        case 429:
            return "Hugging Face is receiving too many requests from this network."
                + " Wait a few minutes and try again."
        case 500..<600:
            return "Hugging Face is having trouble right now and could not send "
                + (file.map { "'\($0)'" } ?? "the list of files in '\(repo)'")
                + ". Try again later."
        default:
            return "Hugging Face refused to send "
                + (file.map { "'\($0)' from '\(repo)'" } ?? "the list of files in '\(repo)'")
                + " (HTTP status \(status))."
        }
    }

    /// The tree API's JSON to file entries. Split out from `tree` so the size
    /// rule can be tested without a server, because the size rule is the part
    /// with a wrong answer available.
    public static func parseTree(_ data: Data, describedAs source: String) throws -> [HFRepoFile] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SpeechError.runtime("\(source) did not return a JSON array")
        }
        return entries.compactMap { entry in
            guard (entry["type"] as? String) == "file",
                  let path = entry["path"] as? String
            else { return nil }
            // For an LFS entry `size` is the pointer file - about 130 bytes -
            // and `lfs.size` is the object. Every GGUF in these repositories is
            // LFS, so reading the wrong one reports a 2 GB model as 130 bytes
            // and every download then fails its own length check.
            let lfs = entry["lfs"] as? [String: Any]
            let lfsSize = (lfs?["size"] as? NSNumber)?.int64Value
            let plainSize = (entry["size"] as? NSNumber)?.int64Value
            // The object id, which is what makes a resume safe. `oid` on the
            // entry itself is the git blob id and changes for reasons the
            // content does not, so only the LFS one is used.
            let oid = lfs?["oid"] as? String
            return HFRepoFile(path: path, size: lfsSize ?? plainSize, oid: oid)
        }
    }

    // MARK: - Download

    /// Fetch one repository file to `destination`, resuming a previous attempt.
    ///
    /// `expectedSize` is the tree API's figure when the caller has it. It is
    /// checked against what the server actually serves, so a repository that
    /// moved on between the catalog probe and the download fails loudly instead
    /// of leaving a file that will not load.
    public static func download(
        repo: String,
        file: String,
        to destination: URL,
        expectedSize: Int64? = nil,
        oid: String? = nil,
        configuration: URLSessionConfiguration? = nil,
        progress: @escaping LoadProgressHandler
    ) async throws {
        try validate(pathPart: repo, label: "repository")
        try validate(pathPart: file, label: "file name")
        try await ResumableDownload(
            url: resolveURL(repo: repo, file: file),
            repo: repo,
            destination: destination,
            expectedSize: expectedSize,
            oid: oid,
            label: file,
            configuration: configuration
        ).run(progress: progress)
    }
}

/// A single resumable HTTP transfer to a file.
///
/// `URLSessionDataTask` plus a `FileHandle` rather than `URLSessionDownloadTask`
/// on purpose: the download task's resume story is `resumeData`, an opaque blob
/// with no documented lifetime across a process exit, and these transfers have
/// to resume after the user quits the applet mid-download. A byte offset in a
/// file on disk always survives.
final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    /// The repository `url` points into, for the words of a refusal.
    private let repo: String
    private let destination: URL
    private let temporary: URL
    /// Records which revision the bytes in `temporary` came from. Without it a
    /// resume is a guess - see `run`.
    private let validator: URL
    private let expectedSize: Int64?
    private let oid: String?
    private let label: String
    private let configuration: URLSessionConfiguration

    /// Everything the delegate callbacks touch. They arrive on the session's
    /// serial delegate queue, but `run`'s continuation and the cancellation
    /// handler run on other threads, so the state is lock-guarded rather than
    /// merely serialized.
    private let lock = NSLock()
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var startOffset: Int64 = 0
    private var total: Int64?
    private var failure: Error?
    private var finished = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: LoadProgressHandler = { _ in }
    private var lastReport = Date.distantPast

    init(
        url: URL, repo: String, destination: URL, expectedSize: Int64?, oid: String?, label: String,
        configuration: URLSessionConfiguration?
    ) {
        self.url = url
        self.repo = repo
        self.destination = destination
        self.temporary = destination.appendingPathExtension("download")
        self.validator = destination.appendingPathExtension("download.oid")
        self.expectedSize = expectedSize
        self.oid = oid
        self.label = label
        // Copied, not adopted: `URLSessionConfiguration` is a class, so setting
        // the timeouts below on a caller's object would write through to it.
        let config = (configuration?.copy() as? URLSessionConfiguration)
            ?? URLSessionConfiguration.default
        // A stalled connection must not hang forever; 60 s with no bytes at all
        // is a dead transfer, and a retry costs nothing because it resumes into
        // the same temp file. The resource timeout stays unbounded: a 3 GB model
        // on a slow link is slow, not broken.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .greatestFiniteMagnitude
        self.configuration = config
    }

    /// Size of a file, or 0 when it is absent or unreadable. `attributesOfItem`
    /// hands back `Any`, and the value is an `NSNumber`; going straight to
    /// `as? Int64` through a `try?` yields a doubly-optional that silently reads
    /// as "no bytes yet" and restarts every resume from zero.
    static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber
        else { return 0 }
        return number.int64Value
    }

    func run(progress: @escaping LoadProgressHandler) async throws {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // What a previous attempt left behind, and whether it can be trusted.
        //
        // Length alone cannot answer that. Nothing ties bytes already on disk
        // to the object being served now: `main` is a mutable ref and these
        // repositories are requantized in place. If a 700 MB object is replaced
        // by a 900 MB one between two attempts, a resume from 400 MB asks for
        // `bytes=400000000-`, the server answers 206 from exactly that offset,
        // the total matches the new size, the final length matches, and the
        // GGUF magic - read from the *old* revision's header - checks out. The
        // row installs as a file that is 400 MB of one model followed by
        // 500 MB of another, whose tensor offsets index into the wrong data.
        //
        // So the LFS object id of the revision being fetched is written beside
        // the temp file, and a resume happens only when it still matches.
        var resumeFrom = Self.fileSize(temporary)
        if resumeFrom > 0 {
            let recorded = try? String(contentsOf: validator, encoding: .utf8)
            let sameRevision = oid != nil && recorded == oid
            // A temp file at or past the known total is a leftover rather than
            // a resume point, and asking for `bytes=<total>-` earns a 416
            // instead of a diagnosis.
            let overrun = expectedSize.map { resumeFrom >= $0 } ?? false
            if !sameRevision || overrun {
                try? fm.removeItem(at: temporary)
                try? fm.removeItem(at: validator)
                resumeFrom = 0
            }
        }
        if let oid {
            try? Data(oid.utf8).write(to: validator, options: .atomic)
        } else {
            // Nothing to pin the bytes to, so never resume onto them.
            try? fm.removeItem(at: validator)
        }

        if !fm.fileExists(atPath: temporary.path) {
            guard fm.createFile(atPath: temporary.path, contents: nil) else {
                throw SpeechError.runtime("cannot create \(temporary.path)")
            }
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: temporary)
            try handle.seekToEnd()
        } catch {
            throw SpeechError.runtime(
                "cannot open \(temporary.path) for writing: \(error.localizedDescription)")
        }

        lock.withLock {
            self.handle = handle
            self.startOffset = resumeFrom
            self.received = resumeFrom
            self.progress = progress
        }

        var request = URLRequest(url: url)
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        // The session holds a strong reference to its delegate - this object -
        // until it is invalidated, so this is what breaks the cycle.
        defer {
            session.finishTasksAndInvalidate()
            try? handle.close()
        }

        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // The task can already be finished if the caller's Task was
                // cancelled before we got here; resume with what the delegate
                // stored rather than parking on a continuation nobody resumes.
                let alreadyDone: Bool = lock.withLock {
                    if finished { return true }
                    continuation = cont
                    return false
                }
                if alreadyDone {
                    let error = lock.withLock { failure }
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }

        // Flush before measuring: the length check below reads the file, and an
        // unflushed tail would make a complete download look short.
        try? handle.synchronize()
        try moveIntoPlace()
    }

    /// Move the completed temp file into place, after checking its length.
    private func moveIntoPlace() throws {
        let fm = FileManager.default
        let size = Self.fileSize(temporary)
        lock.lock()
        let expected = total ?? expectedSize
        lock.unlock()
        guard let expected else {
            throw SpeechError.runtime(
                "\(label): neither the server nor the catalog reported a size, so this"
                + " download cannot be verified; the file is kept at \(temporary.path)")
        }
        guard size == expected else {
            throw SpeechError.runtime(
                "\(label): downloaded \(formatBytes(size)) but expected \(formatBytes(expected));"
                + " the partial file is kept at \(temporary.path)")
        }
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            throw SpeechError.runtime(
                "cannot move \(temporary.path) into place: \(error.localizedDescription)")
        }
        // The transfer is over, so the revision marker has nothing left to
        // guard. Left behind it would be the only file in the row directory
        // that is not the model.
        try? fm.removeItem(at: validator)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // Anything that is not HTTP has no status, no Content-Range and no
        // length, so every check below would be skipped on a body this code
        // cannot vouch for. Refuse it rather than write it to disk.
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            complete(with: SpeechError.runtime(
                "\(label): \(url.absoluteString) did not answer over HTTP"))
            return
        }
        lock.lock()
        let resumeFrom = startOffset
        lock.unlock()

        // 416 means the server would not serve the offset asked for, which
        // after the revision check in `run` can only mean the partial file is
        // stale in a way that check did not catch. Clear it so the next attempt
        // starts clean instead of asking the same impossible question again.
        if http.statusCode == 416 {
            completionHandler(.cancel)
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: validator)
            complete(with: SpeechError.runtime(
                "\(label): the server rejected the resume offset \(resumeFrom);"
                + " the stale partial download has been discarded, so download the"
                + " model again to start over"))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            complete(with: SpeechError.runtime(
                HuggingFace.refusal(
                    status: http.statusCode, repo: repo, file: label,
                    errorCode: http.value(forHTTPHeaderField: "X-Error-Code"))))
            return
        }

        let contentLength = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        if http.statusCode == 206 {
            // Trust the server's own account of where this body starts. A proxy
            // that answered a different range than we asked for would otherwise
            // splice bytes into the middle of the file and produce a GGUF of
            // exactly the right length that is wrong everywhere.
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let parsed = Self.parseContentRange(range)
            else {
                completionHandler(.cancel)
                complete(with: SpeechError.runtime(
                    "\(label): the server sent a partial response with no usable Content-Range"))
                return
            }
            guard parsed.start == resumeFrom else {
                completionHandler(.cancel)
                complete(with: SpeechError.runtime(
                    "\(label): asked to resume at \(resumeFrom) but the server sent"
                    + " bytes from \(parsed.start)"))
                return
            }
            lock.lock()
            total = parsed.total ?? contentLength.map { resumeFrom + $0 }
            lock.unlock()
        } else {
            // 200 to a ranged request means the server ignored `Range`: this
            // body is the whole file, so everything already on disk is stale and
            // must go. Appending here is how a resumed download ends up exactly
            // `resumeFrom` bytes too long.
            if resumeFrom > 0 {
                lock.lock()
                let handle = self.handle
                lock.unlock()
                do {
                    try handle?.truncate(atOffset: 0)
                } catch {
                    completionHandler(.cancel)
                    complete(with: SpeechError.runtime(
                        "\(label): cannot restart the download: \(error.localizedDescription)"))
                    return
                }
                lock.lock()
                startOffset = 0
                received = 0
                lock.unlock()
            }
            lock.lock()
            total = contentLength
            lock.unlock()
        }

        lock.lock()
        let declared = total
        lock.unlock()
        if let declared, let expectedSize, declared != expectedSize {
            completionHandler(.cancel)
            complete(with: SpeechError.runtime(
                "\(label): the catalog expects \(formatBytes(expectedSize)) but the server"
                + " offers \(formatBytes(declared)); the repository has changed"))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let handle = self.handle
        let stop = finished || failure != nil
        lock.unlock()
        guard let handle, !stop else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            complete(with: SpeechError.runtime(
                "\(label): cannot write to \(temporary.path): \(error.localizedDescription)"))
            return
        }
        lock.lock()
        received += Int64(data.count)
        let done = received
        let declared = total
        // Throttled: a 2 GB file arrives in tens of thousands of chunks, and an
        // event per chunk would cost more than the transfer.
        let now = Date()
        let due = now.timeIntervalSince(lastReport) >= 0.2
        if due { lastReport = now }
        let report = due ? progress : nil
        lock.unlock()
        report?(LoadProgress(
            phase: .downloading,
            fraction: declared.map { $0 > 0 ? Double(done) / Double($0) : 0 },
            bytesDone: done, bytesTotal: declared, file: label))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            complete(with: nil)
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            // Either our own cancel after an outcome was decided - in which case
            // `complete` already ran and this is a no-op - or the caller's task
            // cancellation, which is what this reports.
            complete(with: CancellationError())
            return
        }
        complete(with: SpeechError.runtime(
            "\(label): download failed: \(error.localizedDescription)"))
    }

    /// Resume the waiting caller exactly once, whichever callback gets here first.
    private func complete(with error: Error?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        failure = error
        let waiting = continuation
        continuation = nil
        let done = received
        let declared = total
        let report = progress
        lock.unlock()

        if error == nil {
            report(LoadProgress(
                phase: .downloading, fraction: 1,
                bytesDone: done, bytesTotal: declared ?? done, file: label))
        }
        if let waiting {
            if let error { waiting.resume(throwing: error) } else { waiting.resume() }
        }
    }

    /// `bytes 100-199/1234` -> (start: 100, total: 1234). A `*` total is legal
    /// and means the server will not say, which is survivable: the caller falls
    /// back to the catalog's figure.
    static func parseContentRange(_ header: String) -> (start: Int64, total: Int64?)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rangePart = parts.first else { return nil }
        let bounds = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let startText = bounds.first, let start = Int64(startText) else { return nil }
        let total = parts.count == 2 ? Int64(parts[1]) : nil
        return (start: start, total: total)
    }
}
