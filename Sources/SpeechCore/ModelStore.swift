// ModelStore.swift - where model weights live on disk, and the only code in
// the program that creates, measures or removes those directories.
//
// Two rules shape this file.
//
// First, the store owns *placement* and the engine owns *completeness*. The
// store cannot know that a Parakeet row needs `JointDecisionv3.mlmodelc` while
// a Nemotron row needs `metadata.json`; the engine cannot know that the user
// pointed `--models-dir` somewhere else. So `state(of:)` asks the store whether
// a download was interrupted and asks the engine whether the files that did
// land are usable, and neither grows a table of the other's facts.
//
// Second, a half-downloaded model must never look installed. FluidAudio's
// `modelsExist(at:)` checks for file presence, and a download killed after the
// last mlmodelc but before the tokenizer would satisfy it. So the store writes
// a `.partial` marker before the first byte and removes it only after the
// engine confirms completeness - the marker outranks any file check, which
// makes "interrupted" a state the applet can report and offer to resume rather
// than a crash three minutes into the first transcribe.

import Foundation

/// Whether a row's weights are on disk and usable.
public enum ModelInstallState: String, Codable, Sendable, Equatable {
    /// Present and complete.
    case installed
    /// A download started and did not finish. The directory may hold files.
    case partial
    /// Nothing on disk.
    case missing
    /// The OS owns these weights and neither downloads nor deletes them here -
    /// Apple's locale assets. Reported so the applet can hide the delete
    /// button rather than offering an operation that cannot work.
    case systemManaged = "system_managed"
    /// Files are present but no engine in this build can judge or use them - a
    /// row left behind by an older build or by a pin bump. Deletable, and that
    /// is the only thing a caller should offer for it. Reporting these as
    /// `installed` told an applet reading `models list --json` that the row was
    /// ready to transcribe with, which then exits 2.
    case unknown
}

/// One row's presence on disk, as `models list` and `models status` report it.
public struct ModelStoreEntry: Sendable, Equatable {
    public var catalogID: String
    public var directory: URL
    public var state: ModelInstallState
    /// Logical bytes of every regular file under `directory`. Zero when
    /// missing, and meaningful (partial progress) when `state == .partial`.
    public var bytes: Int64
    /// Newest modification time under `directory`, for "downloaded when".
    public var modified: Date?
    /// Something under the directory could not be read, so `bytes` is a lower
    /// bound. Reported rather than swallowed: a size that is quietly short is
    /// worse than one that says it is incomplete.
    public var bytesAreLowerBound = false

    public init(
        catalogID: String,
        directory: URL,
        state: ModelInstallState,
        bytes: Int64 = 0,
        modified: Date? = nil,
        bytesAreLowerBound: Bool = false
    ) {
        self.catalogID = catalogID
        self.directory = directory
        self.state = state
        self.bytes = bytes
        self.modified = modified
        self.bytesAreLowerBound = bytesAreLowerBound
    }
}

/// Answers "are the files in this directory a usable model?". Supplied by the
/// engine that owns the row, because only it knows the file list. Returning
/// false for an empty directory is the contract - the store never calls this
/// for a directory that does not exist.
public typealias ModelCompletenessCheck = @Sendable (URL) -> Bool

public struct ModelStore: Sendable {
    /// The `--models-dir` root. Every path this type touches is under it.
    public let root: URL

    /// Written before the first byte of a download and removed only after the
    /// completeness check passes. A dotfile inside the row directory, so
    /// deleting the row deletes the marker and no orphan can outlive it.
    public static let partialMarkerName = ".partial"

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: - Placement

    /// The directory for a row. Fails closed: a spec whose components would
    /// escape the root is rejected rather than resolved, so no catalog id -
    /// which in stage 3 comes from a TSV file, not only from argv - can point
    /// `delete` at a directory outside the store.
    public func directory(for spec: EngineSpec) throws -> URL {
        let url = spec.directory.standardizedFileURL
        guard isContained(url) else {
            throw SpeechError.usage(
                "catalog id '\(spec.catalogID)' resolves outside the models directory")
        }
        return url
    }

    /// True when `url` is `root` or sits under it.
    ///
    /// Compares whole path components, so `/models-evil` is not mistaken for a
    /// child of `/models`, and compares them after canonicalizing symlinks -
    /// which `standardizedFileURL` does not do, since it collapses `.` and `..`
    /// textually and never consults the filesystem. Without that, a symlinked
    /// component inside the store is a way out of it: with `<models>/fluid`
    /// pointing at /tmp/outside, `models delete` removed /tmp/outside and
    /// reported success. `delete` is an `rm -rf`, so this check is the only
    /// thing standing between a catalog id and the file system.
    ///
    /// Canonicalization has to be done by hand, because
    /// `resolvingSymlinksInPath()` is a no-op on a path that does not exist -
    /// it will not even resolve existing ancestors. Calling it directly on both
    /// sides therefore canonicalized the root while leaving an absent row
    /// literal, which broke both directions at once: every command failed on a
    /// legitimately symlinked models directory (including any path under /tmp,
    /// which is /private/tmp), and a row that did not exist yet still passed,
    /// so `beginInstall` followed the symlink and wrote half a gigabyte
    /// outside the store - where `delete` then refused to touch it forever.
    ///
    /// So: walk up to the deepest ancestor that exists, resolve that, and
    /// re-append the literal tail. Both sides get the same treatment because
    /// the root is often a symlink itself.
    func isContained(_ url: URL) -> Bool {
        let rootParts = Self.canonicalComponents(root)
        let parts = Self.canonicalComponents(url)
        guard parts.count >= rootParts.count else { return false }
        return Array(parts.prefix(rootParts.count)) == rootParts
    }

    /// Path components with every *existing* symlink resolved and any
    /// not-yet-created tail preserved literally.
    static func canonicalComponents(_ url: URL) -> [String] {
        var tail: [String] = []
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            tail.insert(probe.lastPathComponent, at: 0)
            probe = probe.deletingLastPathComponent()
        }
        return probe.resolvingSymlinksInPath().pathComponents + tail
    }

    // MARK: - State

    /// Whether the row is installed, partial or missing.
    ///
    /// The `.partial` marker is checked first and deliberately outranks
    /// `isComplete`: a download interrupted after the last model file but
    /// before its metadata can satisfy a file-presence check, and reporting
    /// that as installed turns a resumable download into a runtime failure.
    public func state(of spec: EngineSpec, isComplete: ModelCompletenessCheck) throws -> ModelInstallState {
        let dir = try directory(for: spec)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .missing
        }
        if FileManager.default.fileExists(atPath: marker(in: dir).path) {
            return .partial
        }
        return isComplete(dir) ? .installed : .missing
    }

    public func entry(for spec: EngineSpec, isComplete: ModelCompletenessCheck) throws -> ModelStoreEntry {
        let dir = try directory(for: spec)
        let state = try state(of: spec, isComplete: isComplete)
        // Always measure. Bytes are a fact about the directory, not about the
        // state, and the two come apart: a row whose files are present but do
        // not satisfy the engine's check - a truncated download, a partial
        // external deletion, or FluidAudio purging a corrupt cache - is
        // `missing` while holding the entire download. Skipping the walk for
        // `missing` reported two gigabytes as 0 B, which is exactly the
        // invisible occupancy this store exists to prevent, and made
        // `delete` claim it had reclaimed nothing.
        let usage = usage(of: dir)
        return ModelStoreEntry(
            catalogID: spec.catalogID, directory: dir, state: state,
            bytes: usage.bytes, modified: usage.modified,
            bytesAreLowerBound: usage.incomplete)
    }

    // MARK: - Install lifecycle

    /// Creates the row directory and marks it partial. Call before handing the
    /// directory to a downloader.
    public func beginInstall(_ spec: EngineSpec) throws -> URL {
        let dir = try directory(for: spec)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: marker(in: dir), options: .atomic)
        } catch {
            throw SpeechError.runtime(
                "cannot prepare \(dir.path): \(error.localizedDescription)")
        }
        return dir
    }

    /// Verifies what landed and clears the partial marker. Throws with the
    /// directory left marked partial when the check fails, so a retry resumes
    /// instead of the next run trusting a broken install.
    public func finishInstall(_ spec: EngineSpec, isComplete: ModelCompletenessCheck) throws {
        let dir = try directory(for: spec)
        guard isComplete(dir) else {
            throw SpeechError.runtime(
                "download of '\(spec.catalogID)' finished but the model files are incomplete;"
                + " the partial download is kept at \(dir.path) - retry, or delete it")
        }
        let marker = marker(in: dir)
        if FileManager.default.fileExists(atPath: marker.path) {
            do {
                try FileManager.default.removeItem(at: marker)
            } catch {
                throw SpeechError.runtime(
                    "cannot clear the partial marker at \(marker.path): \(error.localizedDescription)")
            }
        }
    }

    /// Removes a row's directory. Returns false when there was nothing to
    /// remove, so `models delete` can say "not installed" rather than claiming
    /// a deletion that did not happen.
    @discardableResult
    public func delete(_ spec: EngineSpec) throws -> Bool {
        try delete(at: try directory(for: spec), describedAs: spec.catalogID)
    }

    /// Removes a directory by path rather than by spec, for a row whose id does
    /// not round-trip into the path it was found at. Containment is re-checked
    /// here and not inherited from the caller: this is the `rm -rf`.
    @discardableResult
    public func delete(at directory: URL, describedAs catalogID: String) throws -> Bool {
        let dir = directory.standardizedFileURL
        guard isContained(dir) else {
            throw SpeechError.usage(
                "'\(catalogID)' resolves outside the models directory")
        }
        // Refuse to delete the root itself. Reachable only through a spec whose
        // components are empty, which parse rejects - belt and braces, because
        // the blast radius is every model the user has downloaded.
        guard dir.standardizedFileURL != root else {
            throw SpeechError.usage("refusing to delete the models directory itself")
        }
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            throw SpeechError.runtime("cannot delete \(dir.path): \(error.localizedDescription)")
        }
        return true
    }

    // MARK: - Enumeration

    /// Every row directory present under the store: its catalog id and the
    /// directory it was actually found in. Used by `models list` to report rows
    /// the catalog no longer knows about, which is how a stale download becomes
    /// visible instead of occupying two gigabytes in silence.
    ///
    /// The directory is returned rather than left to be rebuilt from the id,
    /// because that round trip is not lossless. An id is `<engine>.<model>` and
    /// the model may itself contain dots (`ggml.nemotron-3.5-asr@q8_0`), so a
    /// caller splitting on every dot lands on `fluid/nemotron-3/5-asr@q8_0` -
    /// a directory that does not exist, reported at 0 bytes. That is exactly
    /// the invisible occupancy this function exists to prevent.
    ///
    /// State is not resolved here: that needs the owning engine's completeness
    /// check, and this call deliberately does not reach into the registry.
    public func installedRows() -> [(id: String, directory: URL)] {
        let fm = FileManager.default
        guard let engines = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else {
            return []
        }
        var rows: [(id: String, directory: URL)] = []
        for engineDir in engines where isDirectory(engineDir) {
            let engine = engineDir.lastPathComponent
            guard let leaves = try? fm.contentsOfDirectory(
                at: engineDir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for rowDir in leaves where isDirectory(rowDir) {
                rows.append((id: "\(engine).\(rowDir.lastPathComponent)", directory: rowDir))
            }
        }
        return rows.sorted { $0.id < $1.id }
    }

    // MARK: - Measurement

    /// Bytes under a row directory, plus whether the walk had to skip anything
    /// unreadable, for callers that have a directory but no engine to ask for a
    /// completeness check - `models list` reporting a row left behind by a build
    /// that no longer has its engine, which is exactly the row a user needs to
    /// find and delete.
    ///
    /// The lower-bound flag is returned rather than dropped because these are
    /// precisely the rows a user is told to delete *to reclaim space*: reporting
    /// a quietly short size there inverts the whole point.
    public func measure(_ directory: URL) -> (bytes: Int64, isLowerBound: Bool) {
        let usage = usage(of: directory)
        return (usage.bytes, usage.incomplete)
    }

    struct DirectoryUsage: Equatable {
        var bytes: Int64 = 0
        var modified: Date?
        /// Something under the directory could not be read, so `bytes` is a
        /// lower bound rather than a total.
        var incomplete = false
    }

    /// Logical size and newest mtime under `directory`.
    ///
    /// Symlinks are not followed and their targets are not counted. A model
    /// directory should contain only regular files, and a store that followed
    /// links would report - and `delete` would remove - bytes it does not own.
    ///
    /// An unreadable subdirectory sets `incomplete` on the result rather than
    /// being skipped silently, so a caller can say "at least N bytes" instead
    /// of publishing a total it cannot stand behind.
    func usage(of directory: URL) -> DirectoryUsage {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var unreadable = false
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .producesRelativePathURLs],
            errorHandler: { _, _ in unreadable = true; return true })
        else {
            return DirectoryUsage()
        }
        var usage = DirectoryUsage()
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            usage.bytes += Int64(values.fileSize ?? 0)
            if let date = values.contentModificationDate {
                usage.modified = max(usage.modified ?? date, date)
            }
        }
        usage.incomplete = unreadable
        return usage
    }

    // MARK: - Helpers

    func marker(in directory: URL) -> URL {
        directory.appendingPathComponent(Self.partialMarkerName, isDirectory: false)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

/// Human-readable byte count for status lines: "1.4 GB", "812 MB", "0 B".
/// Deliberately decimal (1000-based) to match what Hugging Face and Finder
/// report, so a user comparing a download against the model card sees the same
/// number rather than a 7% smaller one.
public func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "kB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1000, unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    if unit == 0 { return "\(bytes) B" }
    return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
}
