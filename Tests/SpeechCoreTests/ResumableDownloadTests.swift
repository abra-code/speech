import Foundation
import Testing

@testable import SpeechCore

/// A stub origin server. `URLProtocol` is the seam that makes the transfer
/// itself testable without a socket, which matters because the resume path is
/// where the one genuinely dangerous bug in this file lived: a download that
/// resumed across a changed upstream object produced a file of exactly the
/// right length, with the right magic bytes, made of two different revisions.
final class StubOrigin: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var body: Data
        /// Serve `200` with the whole body even when a `Range` was asked for,
        /// which is what a server without range support does.
        var ignoreRange = false
        var status: Int?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = Response(body: Data())
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func serve(_ response: Response) {
        lock.withLock {
            self.response = response
            requests = []
        }
    }

    static var recorded: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (response, _) = Self.lock.withLock {
            Self.requests.append(self.request)
            return (Self.response, ())
        }
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        var start = 0
        if let rangeHeader, rangeHeader.hasPrefix("bytes="),
           let parsed = Int(rangeHeader.dropFirst("bytes=".count).dropLast()) {
            start = parsed
        }

        var status = response.status ?? 200
        var headers: [String: String] = [:]
        var body = response.body

        if let forced = response.status {
            status = forced
            body = Data()
        } else if start > 0, !response.ignoreRange {
            guard start < response.body.count else {
                send(status: 416, headers: [:], body: Data())
                return
            }
            body = response.body.suffix(from: start)
            status = 206
            headers["Content-Range"] =
                "bytes \(start)-\(response.body.count - 1)/\(response.body.count)"
        }
        headers["Content-Length"] = String(body.count)
        send(status: status, headers: headers, body: body)
    }

    private func send(status: Int, headers: [String: String], body: Data) {
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubOrigin.self]
        return config
    }
}

@Suite("Resumable download", .serialized)
struct ResumableDownloadTests {
    static func makeBody(_ marker: UInt8, count: Int) -> Data {
        var data = Data("GGUF".utf8)
        data.append(Data(repeating: marker, count: count - 4))
        return data
    }

    static func withScratch(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    @Test("a whole file downloads and lands at the destination")
    func plainDownload() async throws {
        try await Self.withScratch { directory in
            let body = Self.makeBody(0xAA, count: 4096)
            StubOrigin.serve(.init(body: body))
            let destination = directory.appendingPathComponent("model.gguf")
            try await HuggingFace.download(
                repo: "org/repo", file: "model-Q8_0.gguf", to: destination,
                expectedSize: Int64(body.count), oid: "sha256:one",
                configuration: StubOrigin.configuration()) { _ in }

            #expect(try Data(contentsOf: destination) == body)
            // Neither the temp file nor the revision marker outlives the
            // transfer; a stray one would be the only non-model file in the row.
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathExtension("download").path))
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathExtension("download.oid").path))
        }
    }

    @Test("an interrupted transfer resumes from where it stopped")
    func resumesSameRevision() async throws {
        try await Self.withScratch { directory in
            let body = Self.makeBody(0xBB, count: 8192)
            let destination = directory.appendingPathComponent("model.gguf")
            // What a killed attempt leaves: the first 3000 bytes plus the marker
            // naming the revision they came from.
            try body.prefix(3000).write(to: destination.appendingPathExtension("download"))
            try Data("sha256:same".utf8).write(
                to: destination.appendingPathExtension("download.oid"))

            StubOrigin.serve(.init(body: body))
            try await HuggingFace.download(
                repo: "org/repo", file: "model-Q8_0.gguf", to: destination,
                expectedSize: Int64(body.count), oid: "sha256:same",
                configuration: StubOrigin.configuration()) { _ in }

            #expect(try Data(contentsOf: destination) == body)
            let sent = StubOrigin.recorded.first?.value(forHTTPHeaderField: "Range")
            #expect(sent == "bytes=3000-", "should have asked to resume, not restarted")
        }
    }

    /// The bug this whole mechanism exists for. Length, `Content-Range`, the
    /// final size check and the GGUF magic all pass on a file spliced from two
    /// revisions, because the header comes from the old one and the tail from
    /// the new one. Only the object id catches it.
    @Test("a changed upstream object restarts instead of splicing")
    func changedRevisionRestarts() async throws {
        try await Self.withScratch { directory in
            let old = Self.makeBody(0x11, count: 6000)
            let new = Self.makeBody(0x22, count: 8192)
            let destination = directory.appendingPathComponent("model.gguf")
            try old.prefix(3000).write(to: destination.appendingPathExtension("download"))
            try Data("sha256:old".utf8).write(
                to: destination.appendingPathExtension("download.oid"))

            StubOrigin.serve(.init(body: new))
            try await HuggingFace.download(
                repo: "org/repo", file: "model-Q8_0.gguf", to: destination,
                expectedSize: Int64(new.count), oid: "sha256:new",
                configuration: StubOrigin.configuration()) { _ in }

            let landed = try Data(contentsOf: destination)
            #expect(landed == new, "must be the new revision end to end")
            #expect(!landed.contains(0x11), "no byte of the old revision may survive")
            #expect(StubOrigin.recorded.first?.value(forHTTPHeaderField: "Range") == nil,
                    "a changed object must be fetched from the start")
        }
    }

    /// Without the object id there is nothing to pin bytes to, so a leftover
    /// partial must never be resumed onto.
    @Test("an unknown object id restarts rather than trusting the partial")
    func noOidRestarts() async throws {
        try await Self.withScratch { directory in
            let body = Self.makeBody(0xCC, count: 5000)
            let destination = directory.appendingPathComponent("model.gguf")
            try body.prefix(2000).write(to: destination.appendingPathExtension("download"))

            StubOrigin.serve(.init(body: body))
            try await HuggingFace.download(
                repo: "org/repo", file: "model-Q8_0.gguf", to: destination,
                expectedSize: Int64(body.count), oid: nil,
                configuration: StubOrigin.configuration()) { _ in }

            #expect(try Data(contentsOf: destination) == body)
            #expect(StubOrigin.recorded.first?.value(forHTTPHeaderField: "Range") == nil)
        }
    }

    /// A `200` to a ranged request means the server ignored `Range` and this
    /// body is the whole file. Appending is how a resume ends up exactly
    /// `resumeFrom` bytes too long.
    @Test("a server that ignores Range makes the download start over")
    func ignoredRangeTruncates() async throws {
        try await Self.withScratch { directory in
            let body = Self.makeBody(0xDD, count: 7000)
            let destination = directory.appendingPathComponent("model.gguf")
            try body.prefix(2500).write(to: destination.appendingPathExtension("download"))
            try Data("sha256:same".utf8).write(
                to: destination.appendingPathExtension("download.oid"))

            StubOrigin.serve(.init(body: body, ignoreRange: true))
            try await HuggingFace.download(
                repo: "org/repo", file: "model-Q8_0.gguf", to: destination,
                expectedSize: Int64(body.count), oid: "sha256:same",
                configuration: StubOrigin.configuration()) { _ in }

            let landed = try Data(contentsOf: destination)
            #expect(landed.count == body.count, "not 2500 bytes too long")
            #expect(landed == body)
        }
    }

    @Test("a body of the wrong length is refused and kept for a retry")
    func lengthMismatchIsRefused() async throws {
        try await Self.withScratch { directory in
            let body = Self.makeBody(0xEE, count: 4000)
            StubOrigin.serve(.init(body: body))
            let destination = directory.appendingPathComponent("model.gguf")
            await #expect(throws: SpeechError.self) {
                try await HuggingFace.download(
                    repo: "org/repo", file: "model-Q8_0.gguf", to: destination,
                    expectedSize: 999_999, oid: "sha256:one",
                    configuration: StubOrigin.configuration()) { _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path),
                    "a rejected download must not be presented as the model")
        }
    }

    @Test("an HTTP error is reported and nothing is installed")
    func httpErrorIsReported() async throws {
        try await Self.withScratch { directory in
            StubOrigin.serve(.init(body: Data(), status: 404))
            let destination = directory.appendingPathComponent("model.gguf")
            await #expect(throws: SpeechError.self) {
                try await HuggingFace.download(
                    repo: "org/repo", file: "model-Q8_0.gguf", to: destination,
                    expectedSize: 100, oid: "sha256:one",
                    configuration: StubOrigin.configuration()) { _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("a traversal component in a repo or file name is refused")
    func rejectsTraversal() async throws {
        try await Self.withScratch { directory in
            let destination = directory.appendingPathComponent("model.gguf")
            for (repo, file) in [("org/../../evil", "m.gguf"), ("org/repo", "../../evil")] {
                await #expect(throws: SpeechError.self) {
                    try await HuggingFace.download(
                        repo: repo, file: file, to: destination,
                        configuration: StubOrigin.configuration()) { _ in }
                }
            }
        }
    }

    @Test("only TLS endpoints are accepted, with loopback the exception")
    func endpointScheme() {
        #expect(HuggingFace.isAcceptableEndpoint(URL(string: "https://huggingface.co")!))
        #expect(HuggingFace.isAcceptableEndpoint(URL(string: "http://localhost:8080")!))
        #expect(HuggingFace.isAcceptableEndpoint(URL(string: "http://127.0.0.1:8080")!))
        // A 2 GB weights fetch has no signature over it beyond length and object
        // id, so cleartext to an arbitrary host is not a supported mirror.
        #expect(!HuggingFace.isAcceptableEndpoint(URL(string: "http://example.com")!))
        #expect(!HuggingFace.isAcceptableEndpoint(URL(string: "file:///tmp")!))
        #expect(!HuggingFace.isAcceptableEndpoint(URL(string: "ftp://example.com")!))
    }
}
