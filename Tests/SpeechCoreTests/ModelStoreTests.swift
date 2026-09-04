// ModelStoreTests.swift - the store decides what "installed" means, and every
// download, delete and transcribe in the product trusts that answer.
//
// The cases that matter are the dishonest ones: a directory that satisfies an
// engine's file check but was never finished, and a catalog id that tries to
// name a directory outside the store. Both are silent failures in production -
// one wastes a three-minute download and fails at transcribe time, the other
// hands `models delete` a path it does not own.

import Foundation
import Testing
@testable import SpeechCore

@Suite("Model store")
struct ModelStoreTests {
    /// A stand-in for an engine's file check: the row is usable when its
    /// marker file is present, which is what a real `modelsExist(at:)` reduces
    /// to from the store's point of view.
    private static let looksComplete: ModelCompletenessCheck = { directory in
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("weights.mlmodelc").path)
    }

    private func makeStore() throws -> (ModelStore, URL) {
        let root = try Fixtures.makeDirectory()
        return (ModelStore(root: root), root)
    }

    private func spec(_ id: String, _ root: URL) throws -> EngineSpec {
        try EngineSpec.parse(catalogID: id, modelsDirectory: root)
    }

    private func writeWeights(in directory: URL, bytes: Int = 2048) throws {
        try Data(repeating: 0x41, count: bytes)
            .write(to: directory.appendingPathComponent("weights.mlmodelc"))
    }

    @Test("a row nobody has downloaded is missing, not empty")
    func missingRow() throws {
        let (store, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }

        let entry = try store.entry(for: try spec("fluid.parakeet-v3@int8", root),
                                    isComplete: Self.looksComplete)
        #expect(entry.state == .missing)
        #expect(entry.bytes == 0)
        #expect(entry.modified == nil)
        #expect(entry.directory.lastPathComponent == "parakeet-v3@int8")
    }

    @Test("an interrupted download reports partial even when the file check passes")
    func partialOutranksFileCheck() throws {
        let (store, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }
        let spec = try spec("fluid.parakeet-v3@int8", root)

        // The exact shape of a download killed after the last model file
        // landed: every file an engine looks for is present, but the install
        // never completed. Trusting the file check here is what turns a
        // resumable download into a runtime failure much later.
        let directory = try store.beginInstall(spec)
        try writeWeights(in: directory)
        #expect(Self.looksComplete(directory))
        #expect(try store.state(of: spec, isComplete: Self.looksComplete) == .partial)

        // Bytes are still reported while partial, so a UI can show progress
        // against the expected download size.
        let entry = try store.entry(for: spec, isComplete: Self.looksComplete)
        #expect(entry.bytes == 2048)
        #expect(entry.modified != nil)

        try store.finishInstall(spec, isComplete: Self.looksComplete)
        #expect(try store.state(of: spec, isComplete: Self.looksComplete) == .installed)
    }

    @Test("finishing an incomplete download fails and keeps the row marked partial")
    func finishRefusesIncomplete() throws {
        let (store, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }
        let spec = try spec("fluid.canary-1b-v2@int4", root)

        let directory = try store.beginInstall(spec)
        try Data(repeating: 0x42, count: 16)
            .write(to: directory.appendingPathComponent("half-a-tokenizer.json"))

        #expect(throws: SpeechError.self) {
            try store.finishInstall(spec, isComplete: Self.looksComplete)
        }
        // Still partial, so the next run resumes rather than trusting the
        // directory.
        #expect(try store.state(of: spec, isComplete: Self.looksComplete) == .partial)
    }

    @Test("a directory with the wrong files is missing, not installed")
    func incompleteWithoutMarkerIsMissing() throws {
        let (store, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }
        let spec = try spec("fluid.parakeet-v3@int4", root)

        let directory = try store.beginInstall(spec)
        try FileManager.default.removeItem(at: store.marker(in: directory))
        try Data(repeating: 0x43, count: 8)
            .write(to: directory.appendingPathComponent("stray.txt"))

        #expect(try store.state(of: spec, isComplete: Self.looksComplete) == .missing)
    }

    @Test("delete removes the row and reports whether there was anything to remove")
    func deleteRow() throws {
        let (store, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }
        let spec = try spec("fluid.parakeet-v3@int8", root)

        #expect(try store.delete(spec) == false)

        let directory = try store.beginInstall(spec)
        try writeWeights(in: directory)
        try store.finishInstall(spec, isComplete: Self.looksComplete)

        #expect(try store.delete(spec) == true)
        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
        // The engine directory above it survives, so a second row of the same
        // family is untouched.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("fluid").path))
    }

    @Test("a catalog id cannot name a directory outside the store")
    func rejectsPathTraversal() throws {
        let (_, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }

        // Each of these parses into a syntactically valid <engine>.<model>
        // whose model part would escape the models directory once it became a
        // path component. `models delete` runs rm -rf on that path.
        for id in ["fluid.../../../Documents", "fluid...", "../evil.model", "fluid./etc/passwd"] {
            #expect(throws: SpeechError.self, "'\(id)' should be rejected") {
                _ = try EngineSpec.parse(catalogID: id, modelsDirectory: root)
            }
        }

        // A dot inside a name is legitimate and must keep working - the
        // catalog has rows like ggml.nemotron-3.5-asr.
        let ok = try EngineSpec.parse(catalogID: "ggml.nemotron-3.5-asr@q8_0", modelsDirectory: root)
        #expect(ok.model == "nemotron-3.5-asr")
        #expect(ok.variant == "q8_0")
    }

    @Test("a symlinked models directory is not mistaken for an escape")
    func symlinkedRootIsAllowed() throws {
        let base = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Pointing --models-dir at a symlink is ordinary - an external volume
        // for half-gigabyte rows, or anything under /tmp, which is
        // /private/tmp. Canonicalizing the root but not an absent row made
        // every subcommand fail here with "resolves outside the models
        // directory", which was both wrong and a lie about the path.
        let store = ModelStore(root: link)
        let spec = try spec("fluid.parakeet-v3@int8", link)
        #expect(try store.state(of: spec, isComplete: Self.looksComplete) == .missing)
        #expect(try store.delete(spec) == false)

        let directory = try store.beginInstall(spec)
        try writeWeights(in: directory)
        try store.finishInstall(spec, isComplete: Self.looksComplete)
        #expect(try store.delete(spec) == true)
    }

    @Test("a symlink out of the store is refused before anything is created")
    func symlinkedRowIsRefused() throws {
        let base = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(base) }
        let root = base.appendingPathComponent("store", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // The engine directory is a symlink pointing out of the store.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("fluid"), withDestinationURL: outside)

        let store = ModelStore(root: root)
        let spec = try spec("fluid.parakeet-v3@int8", root)

        // The row does not exist yet, which is the case that matters: checking
        // only already-existing paths let `beginInstall` follow the symlink and
        // write half a gigabyte outside the store, where `delete` - now that
        // the path did resolve out - refused to touch it ever again.
        #expect(throws: SpeechError.self) { _ = try store.beginInstall(spec) }
        #expect(throws: SpeechError.self) { _ = try store.delete(spec) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("an unreadable subdirectory makes the size a lower bound, not a lie")
    func unreadableSubdirectory() throws {
        let (store, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }
        let spec = try spec("fluid.parakeet-v3@int8", root)

        let directory = try store.beginInstall(spec)
        try writeWeights(in: directory, bytes: 1000)
        let hidden = directory.appendingPathComponent("hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data(repeating: 0x45, count: 50_000).write(to: hidden.appendingPathComponent("big.bin"))
        try store.finishInstall(spec, isComplete: Self.looksComplete)

        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hidden.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hidden.path)

        // Silently returning 1000 here is worse than saying "at least 1000":
        // this is the number a user is shown when deciding whether deleting the
        // row is worth it.
        let entry = try store.entry(for: spec, isComplete: Self.looksComplete)
        #expect(entry.bytes == 1000)
        #expect(entry.bytesAreLowerBound == true)

        // The same signal has to survive the path that has no engine to ask,
        // which is where it was being dropped.
        let measured = store.measure(directory)
        #expect(measured.bytes == 1000)
        #expect(measured.isLowerBound == true)
    }

    @Test("deleting by walked directory removes the row that was found")
    func deleteUsesTheWalkedDirectory() throws {
        let (store, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }

        // Two directories that produce the same catalog id, because both an
        // engine name and a model name may contain dots. Re-deriving a path
        // from the id picks one of them arbitrarily; the walked directory does
        // not. This tool never creates such a layout, but surfacing rows it did
        // not create is exactly what `models list` is for.
        let a = root.appendingPathComponent("my.engine/row", isDirectory: true)
        let b = root.appendingPathComponent("my/engine.row", isDirectory: true)
        for directory in [a, b] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x41, count: 5000).write(to: a.appendingPathComponent("a.bin"))
        try Data(repeating: 0x42, count: 70).write(to: b.appendingPathComponent("b.bin"))

        let rows = store.installedRows()
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.id == "my.engine.row" })
        // Each row reports its own size rather than one of them twice.
        #expect(Set(rows.map { store.measure($0.directory).bytes }) == [5000, 70])

        #expect(try store.delete(at: a, describedAs: "my.engine.row") == true)
        #expect(FileManager.default.fileExists(atPath: a.path) == false)
        #expect(FileManager.default.fileExists(atPath: b.path) == true)
    }

    @Test("installed rows are listed back as catalog ids")
    func enumerateInstalled() throws {
        let (store, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }

        for id in ["fluid.parakeet-v3@int8", "fluid.canary-1b-v2@int4", "ggml.qwen3-asr-1.7b@q4_k_m"] {
            let spec = try spec(id, root)
            let directory = try store.beginInstall(spec)
            try writeWeights(in: directory, bytes: 32)
            try store.finishInstall(spec, isComplete: Self.looksComplete)
        }

        #expect(store.installedRows().map(\.id) == [
            "fluid.canary-1b-v2@int4",
            "fluid.parakeet-v3@int8",
            "ggml.qwen3-asr-1.7b@q4_k_m",
        ])
        // The directory comes from the walk, so a dotted model name survives -
        // rebuilding it by splitting the id on every dot does not.
        let dotted = try spec("ggml.nemotron-3.5-asr@q8_0", root)
        let directory = try store.beginInstall(dotted)
        try writeWeights(in: directory, bytes: 64)
        try store.finishInstall(dotted, isComplete: Self.looksComplete)
        let found = store.installedRows().first { $0.id == "ggml.nemotron-3.5-asr@q8_0" }
        #expect(found?.directory.lastPathComponent == "nemotron-3.5-asr@q8_0")
    }

    @Test("size walks the row and does not follow symlinks out of it")
    func sizeIgnoresSymlinks() throws {
        let (store, root) = try makeStore()
        defer { Fixtures.cleanUp(root) }
        let spec = try spec("fluid.parakeet-v3@int8", root)

        let outside = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(outside) }
        let big = outside.appendingPathComponent("elsewhere.bin")
        try Data(repeating: 0x44, count: 100_000).write(to: big)

        let directory = try store.beginInstall(spec)
        try writeWeights(in: directory, bytes: 1000)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.bin"), withDestinationURL: big)
        try store.finishInstall(spec, isComplete: Self.looksComplete)

        // 1000, not 101000: the store reports the bytes it owns and would
        // delete, not bytes reachable through a link.
        let entry = try store.entry(for: spec, isComplete: Self.looksComplete)
        #expect(entry.bytes == 1000)
    }

    @Test("byte counts read the way a model card reports them")
    func byteFormatting() {
        #expect(formatBytes(0) == "0 B")
        #expect(formatBytes(999) == "999 B")
        #expect(formatBytes(1000) == "1.0 kB")
        #expect(formatBytes(2_400_000_000) == "2.4 GB")
        #expect(formatBytes(15_000_000) == "15 MB")
    }
}
