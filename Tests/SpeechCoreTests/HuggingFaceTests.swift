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

    /// A person adding a model sees these words in Speech.app. None of the
    /// statuses Hugging Face actually sends may reach them as a bare number.
    @Test("a refused request is described in plain words, not as a status code")
    func refusalWording() {
        #expect(HuggingFace.refusal(status: 401, repo: "someone/model")
            == "Hugging Face has no public repository named 'someone/model'."
            + " Check the spelling of the owner and the name; speech does not sign in to Hugging Face,"
            + " so private repositories and ones that ask you to accept terms first cannot be used.")
        #expect(HuggingFace.refusal(status: 404, repo: "someone/model")
            == HuggingFace.refusal(status: 401, repo: "someone/model"),
            "a missing and a hidden repository mean the same to someone who cannot sign in")
        #expect(HuggingFace.refusal(status: 404, repo: "someone/model", file: "m-Q8_0.gguf")
            .hasPrefix("Hugging Face has no file 'm-Q8_0.gguf' in a public repository named 'someone/model'."))
        // A gated repository lists its files and then refuses the download
        // with the same 401 as a missing one; only the header tells them apart.
        #expect(HuggingFace.refusal(status: 401, repo: "org/gated", file: "m.gguf", errorCode: "GatedRepo")
            == "'org/gated' on Hugging Face asks people to accept its terms on the Hugging Face website"
            + " before downloading; speech does not sign in to Hugging Face, so it cannot download this model.")
        #expect(HuggingFace.refusal(status: 404, repo: "org/repo", file: "m.gguf", errorCode: "EntryNotFound")
            == "'org/repo' on Hugging Face has no file 'm.gguf'.")
        #expect(HuggingFace.refusal(status: 401, repo: "someone/model", errorCode: "EntryNotFound")
            == HuggingFace.refusal(status: 401, repo: "someone/model"),
            "without a file name the code adds nothing")
        #expect(HuggingFace.refusal(status: 429, repo: "someone/model")
            == "Hugging Face is receiving too many requests from this network. Wait a few minutes and try again.")
        #expect(HuggingFace.refusal(status: 503, repo: "someone/model", file: "m.gguf")
            == "Hugging Face is having trouble right now and could not send 'm.gguf'. Try again later.")
        for status in [401, 403, 404, 429, 500, 502, 503] {
            let text = HuggingFace.refusal(status: status, repo: "someone/model")
            #expect(!text.contains("HTTP") && !text.contains(String(status)), "\(status): \(text)")
        }
        #expect(HuggingFace.refusal(status: 418, repo: "someone/model")
            == "Hugging Face refused to send the list of files in 'someone/model' (HTTP status 418).")
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
