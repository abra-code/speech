import Foundation
import Testing

@testable import SpeechCore

@Suite("Hugging Face client")
struct HuggingFaceTests {
    @Test("tree and resolve URLs are built the way the API expects")
    func urls() {
        #expect(
            HuggingFace.treeURL(repo: "handy-computer/parakeet-tdt-0.6b-v3-gguf").absoluteString
                == "https://huggingface.co/api/models/handy-computer/parakeet-tdt-0.6b-v3-gguf/tree/main")
        #expect(
            HuggingFace.resolveURL(
                repo: "handy-computer/canary-1b-v2-gguf", file: "canary-1b-v2-Q8_0.gguf"
            ).absoluteString
                == "https://huggingface.co/handy-computer/canary-1b-v2-gguf/resolve/main/canary-1b-v2-Q8_0.gguf")
    }

    /// The whole point of `parseTree`. `size` on an LFS entry is the pointer
    /// file; the object's real length is `lfs.size`. Reading the wrong one
    /// reports a 740 MB model as 135 bytes, and the download then rejects
    /// itself for being the wrong length.
    @Test("an LFS entry reports the object size, not the pointer size")
    func lfsSizeWins() throws {
        let json = """
        [
          {"type": "file", "path": "README.md", "size": 26245},
          {"type": "file", "path": "model-Q8_0.gguf", "size": 135,
           "lfs": {"size": 739508576, "oid": "abc"}},
          {"type": "directory", "path": "subdir", "size": 0}
        ]
        """
        let files = try HuggingFace.parseTree(Data(json.utf8), describedAs: "test")
        #expect(files.count == 2, "directories are not files")
        #expect(files.first { $0.path == "README.md" }?.size == 26245)
        #expect(files.first { $0.path == "model-Q8_0.gguf" }?.size == 739508576)
    }

    @Test("a response that is not a JSON array is an error, not an empty list")
    func badJSON() {
        #expect(throws: SpeechError.self) {
            _ = try HuggingFace.parseTree(Data("{\"error\":\"nope\"}".utf8), describedAs: "test")
        }
    }

    @Test("Content-Range is parsed, including an unknown total")
    func contentRange() throws {
        let parsed = try #require(ResumableDownload.parseContentRange("bytes 200-999/1000"))
        #expect(parsed.start == 200)
        #expect(parsed.total == 1000)

        let unknown = try #require(ResumableDownload.parseContentRange("bytes 200-999/*"))
        #expect(unknown.start == 200)
        #expect(unknown.total == nil)

        #expect(ResumableDownload.parseContentRange("items 1-2/3") == nil)
        #expect(ResumableDownload.parseContentRange("nonsense") == nil)
    }

    /// `attributesOfItem` hands back `Any`, and the value is an `NSNumber`.
    /// Reaching for `as? Int64` through a `try?` yields a doubly-optional that
    /// collapses to "no bytes yet", which silently restarts every resume from
    /// zero instead of continuing.
    @Test("file size reads back as a number, and a missing file is zero")
    func fileSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("part")
        try Data(repeating: 7, count: 1234).write(to: file)
        #expect(ResumableDownload.fileSize(file) == 1234)
        #expect(ResumableDownload.fileSize(directory.appendingPathComponent("absent")) == 0)
    }
}
