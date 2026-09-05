// ModelsVerb.swift - `speech models <subcommand>`.
//
// Everything that touches model files on disk goes through here and through
// SpeechCore's ModelStore. In particular this is the only place in the program
// that downloads: `transcribe` and `eval` report `model_missing` and exit 3
// rather than pulling a gigabyte on their own, because an eval run pointed at a
// mistyped id would otherwise fetch the wrong model and measure it.
//
// `install-locale` stays separate from `download`. Apple's assets are installed
// system-wide by the OS, land nowhere this tool owns, and cannot be deleted
// from here - a different operation that happens to also fetch bytes.

import Foundation
import SpeechCore
import SpeechApple

func runModels(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    func usage() -> String {
        var text = "Usage: \(kProgram) models <subcommand>\n\n"
        text += "Subcommands:\n"
        text += "  list                    What is on disk, with sizes\n"
        text += "  status <id>             One row: state, path and size\n"
        text += "  download <id>           Fetch a row's weights\n"
        text += "  delete <id>             Remove a row's files\n"
        text += "  install-locale <bcp47>  Install Apple's speech assets for a locale (for example pl-PL)\n"
        text += "\nA catalog id is <engine>.<model>[@<variant>], for example fluid.parakeet-v3@int8.\n"
        return text
    }

    // A missing subcommand is a usage error like every other missing argument,
    // not a help request. Printing prose on stdout and exiting 0 would break
    // the --json contract and tell a script the command succeeded.
    guard let subcommand = arguments.first else {
        throw SpeechError.usage("missing subcommand\n\n" + usage())
    }
    if subcommand == "--help" || subcommand == "-h" {
        CLIHelpers.printUsage(usage())
        return
    }

    let rest = Array(arguments.dropFirst())
    switch subcommand {
    case "list": try await modelsList(globals, sink, rest, usage: usage)
    case "status": try await modelsStatus(globals, sink, rest, usage: usage)
    case "download": try await modelsDownload(globals, sink, rest, usage: usage)
    case "delete": try modelsDelete(globals, sink, rest, usage: usage)
    case "install-locale": try await modelsInstallLocale(globals, sink, rest, usage: usage)
    default:
        throw SpeechError.usage("unknown subcommand 'models \(subcommand)'\n\n" + usage())
    }
}

// MARK: - Shared

/// Builds the engine for an id purely to ask how to tell whether its files are
/// complete. nil means no engine here owns files for that id.
///
/// The two failure modes are deliberately not treated alike. A `usage` error
/// means the id itself is wrong - a misspelled variant - and must reach the
/// user, or `models status fluid.parakeet-v3@int9` cheerfully reports
/// "system_managed" and exits 0 on a typo. Anything else means this build has
/// no such engine, which is survivable: `models list` still has to report a row
/// left behind by an older build, which is exactly the row whose engine is gone.
///
/// This only holds for engines that actually inspect the variant. AppleEngineFactory
/// switches on `spec.model` and ignores `spec.variant`, so `apple.transcriber@bogus`
/// still resolves - harmless, since Apple owns no files, but it is why this
/// comment says "a misspelled variant" rather than "any misspelled id".
func completeness(for spec: EngineSpec) throws -> ModelCompletenessCheck? {
    do {
        return try makeRegistry().make(spec).completenessCheck
    } catch let error as SpeechError {
        if case .usage = error { throw error }
        return nil
    }
}

func entry(for spec: EngineSpec, store: ModelStore) throws -> ModelStoreEntry {
    guard let check = try completeness(for: spec) else {
        // No engine here owns files for this id. Two different situations, and
        // they must not be conflated: an engine whose weights the OS owns
        // (Apple) has no directory at all, while a row left behind by a build
        // that no longer has its engine has one full of bytes. Reporting the
        // second as `partial` told the user "a download was interrupted, run
        // models download to finish it" - advice that then fails with a usage
        // error. It is `installed` from the store's point of view: the files
        // are there, this build simply cannot judge or use them, and what the
        // user needs is the size and the path so they can delete it.
        let directory = try store.directory(for: spec)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return ModelStoreEntry(
                catalogID: spec.catalogID, directory: directory, state: .systemManaged)
        }
        let measured = store.measure(directory)
        return ModelStoreEntry(
            catalogID: spec.catalogID, directory: directory, state: .unknown,
            bytes: measured.bytes, bytesAreLowerBound: measured.isLowerBound)
    }
    return try store.entry(for: spec, isComplete: check)
}

private func emit(_ entry: ModelStoreEntry, to sink: EventSink) {
    // The path is reported even when nothing is installed - it is where the
    // download would land, which is what an applet offering the download needs.
    // Only a system-managed row has no path this tool owns. Bytes are omitted
    // rather than zero when there are no files, so "not downloaded" stays
    // distinguishable from "an empty download".
    let owned = entry.state != .systemManaged
    // Bytes whenever there are bytes. A `missing` row can still hold an entire
    // download that failed its completeness check, and omitting the size there
    // is how two gigabytes become invisible.
    let hasFiles = owned && (entry.state != .missing || entry.bytes > 0)
    sink.emit(.modelEntry(.init(
        model: entry.catalogID,
        state: entry.state,
        path: owned ? entry.directory.path : nil,
        bytes: hasFiles ? entry.bytes : nil,
        bytesAreLowerBound: hasFiles && entry.bytesAreLowerBound)))
}

/// The single positional catalog id these subcommands take. Returns nil when
/// `--help` was asked for and printed, so the caller returns without running.
/// How a row reads to a person. `missing` with bytes on disk is the case worth
/// spelling out: the state is honest (the files cannot be used) but printing
/// "missing" next to 3.0 kB reads as a bug in the tool rather than a broken
/// download the user can delete.
private func humanState(_ entry: ModelStoreEntry) -> String? {
    switch entry.state {
    case .installed: return nil
    case .partial: return "partial download"
    case .systemManaged: return "system_managed"
    case .unknown: return "unknown to this build"
    case .missing: return entry.bytes > 0 ? "incomplete, not usable" : "missing"
    }
}

/// "483 MB", or "at least 483 MB" when something under the row could not be
/// read and the walk therefore under-counted.
private func sizeText(_ entry: ModelStoreEntry) -> String {
    (entry.bytesAreLowerBound ? "at least " : "") + formatBytes(entry.bytes)
}

/// One row, resolved the same way for `list`, `status` and `delete`.
///
/// `walked` is the directory the store actually found, when there was one. It
/// wins over anything derived from the id, because that derivation is not
/// lossless: an id is `<engine>.<model>` and both halves may contain dots, so
/// `my.engine/row` and `my/engine.row` produce the same id and re-deriving a
/// path picks one of them arbitrarily. Round two fixed the crude version of
/// this and left the sibling path re-deriving anyway; this is where the two
/// finally agree.
///
/// Nothing here throws for an id this build cannot construct. That is the whole
/// point: `list` has to be able to show a stale row, and `delete` has to be able
/// to remove the row `list` just showed.
private func resolveRow(
    id: String, walked: URL?, globals: GlobalOptions, store: ModelStore
) throws -> ModelStoreEntry {
    do {
        let spec = try EngineSpec.parse(catalogID: id, modelsDirectory: globals.modelsDirectory)
        let resolved = try entry(for: spec, store: store)
        // Trust the engine-derived answer only when the path it derived is the
        // path that was actually walked.
        guard let walked,
              walked.standardizedFileURL != resolved.directory.standardizedFileURL
        else { return resolved }
        return unknownRow(id: id, directory: walked, store: store)
    } catch {
        // Leniency is earned by existing on disk, and only then. A directory is
        // a fact this build cannot argue with, so it gets reported and can be
        // deleted. Without one there is nothing to describe and the id is
        // simply wrong - `models status fluid.parakeet-v3@int9` must stay a
        // usage error rather than inventing a row for a typo.
        guard let walked else { throw error }
        return unknownRow(id: id, directory: walked, store: store)
    }
}

private func unknownRow(id: String, directory: URL, store: ModelStore) -> ModelStoreEntry {
    let measured = store.measure(directory)
    return ModelStoreEntry(
        catalogID: id, directory: directory, state: .unknown,
        bytes: measured.bytes, bytesAreLowerBound: measured.isLowerBound)
}

private func requireID(_ arguments: [String], usage: () -> String, verb: String) throws -> String? {
    var scanner = ArgScanner(verb: "models \(verb)", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage(usage())
            return nil
        case "--":
            scanner.endOptions()
        default:
            try scanner.addPositional(token)
        }
    }
    return try scanner.requirePositional("id")
}

// MARK: - list

private func modelsList(
    _ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String], usage: () -> String
) async throws {
    var scanner = ArgScanner(verb: "models list", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage(usage())
            return
        case "--": scanner.endOptions()
        default: try scanner.addPositional(token)
        }
    }
    try scanner.requireNoPositionals()

    let store = ModelStore(root: globals.modelsDirectory)
    let ids = store.installedRows()

    guard !ids.isEmpty else {
        sink.text("No models are installed in \(globals.modelsDirectory.path).")
        sink.text("Download one with: \(kProgram) models download fluid.parakeet-v3@int8")
        return
    }

    // Every row is reported, including ones this build cannot make sense of.
    // Listing is the command that exists to surface a stale download, so the
    // row whose engine or variant is unknown - a directory left behind by a
    // pin bump, exactly what plan 1.4 predicts when `int8-v2` comes and goes -
    // is the row it must not choke on. Letting the usage error escape aborted
    // the whole listing with exit 2 and printed none of the healthy rows,
    // leaving the user with gigabytes the tool refused to name.
    var rows: [(String, ModelStoreEntry)] = []
    for row in ids {
        // The directory comes from the walk, never from re-splitting the id: a
        // model name may contain dots (ggml.nemotron-3.5-asr@q8_0), so
        // reconstructing lands on a path that does not exist and reports 0 B.
        // `walked` is never nil here, so this cannot throw.
        let resolved = try resolveRow(
            id: row.id, walked: row.directory, globals: globals, store: store)
        emit(resolved, to: sink)
        rows.append((row.id, resolved))
    }

    let width = rows.map(\.0.count).max() ?? 0
    var total: Int64 = 0
    for (id, entry) in rows {
        total += entry.bytes
        let note = humanState(entry).map { "  [\($0)]" } ?? ""
        sink.text("\(id.padding(toLength: width, withPad: " ", startingAt: 0))"
            + "  \(sizeText(entry))\(note)")
    }
    // The total inherits the marker from any row that carries it, or it claims
    // a precision none of its parts have.
    let totalIsLowerBound = rows.contains { $0.1.bytesAreLowerBound }
    sink.text("\(rows.count) model\(rows.count == 1 ? "" : "s"),"
        + " \(totalIsLowerBound ? "at least " : "")\(formatBytes(total))"
        + " in \(globals.modelsDirectory.path)")
}

// MARK: - status

private func modelsStatus(
    _ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String], usage: () -> String
) async throws {
    guard let id = try requireID(arguments, usage: usage, verb: "status") else { return }
    let store = ModelStore(root: globals.modelsDirectory)
    // Resolved leniently, so that every row `list` prints can also be asked
    // about by name. A row whose id does not parse still exists on disk.
    let walked = store.installedRows().first { $0.id == id }?.directory
    let entry = try resolveRow(id: id, walked: walked, globals: globals, store: store)
    emit(entry, to: sink)

    sink.text("\(id): \(humanState(entry) ?? "installed")")
    if entry.state != .systemManaged {
        sink.text("  path:  \(entry.directory.path)")
        // Size whenever there is one, including for a row that failed its
        // completeness check: those bytes are on the user's disk either way.
        if entry.bytes > 0 || entry.state == .installed {
            sink.text("  size:  \(sizeText(entry))")
        }
    }
    switch entry.state {
    case .unknown:
        sink.text("  No engine in this build can use these files."
            + " Run '\(kProgram) models delete \(id)' to reclaim the space.")
    case .partial:
        sink.text("  A download was interrupted. Run"
            + " '\(kProgram) models download \(id)' to finish it,"
            + " or '\(kProgram) models delete \(id)' to discard it.")
    case .missing where entry.bytes > 0:
        sink.text("  Files are present but do not make a usable model. Run"
            + " '\(kProgram) models delete \(id)' and download it again.")
    default:
        break
    }
}

// MARK: - download

private func modelsDownload(
    _ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String], usage: () -> String
) async throws {
    // No --language here yet. Nemotron and Canary select a prompt at download
    // time and will want one, but accepting a flag that is parsed and thrown
    // away is worse than not having it: the user gets silence instead of an
    // error, and believes they downloaded a Polish model.
    var scanner = ArgScanner(verb: "models download", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage(usage())
            return
        case "--": scanner.endOptions()
        default: try scanner.addPositional(token)
        }
    }
    let id = try scanner.requirePositional("id")

    let store = ModelStore(root: globals.modelsDirectory)
    let spec = try EngineSpec.parse(catalogID: id, modelsDirectory: globals.modelsDirectory)
    let engine = try makeRegistry().make(spec)

    guard let check = engine.completenessCheck else {
        throw SpeechError.usage(
            "'\(id)' has no weights of its own to download."
            + (spec.engine == "apple"
                ? " Apple's assets install with '\(kProgram) models install-locale <bcp47>'."
                : ""))
    }

    // Already there is a success, not an error: a script that downloads before
    // every run should be a no-op the second time.
    if try store.state(of: spec, isComplete: check) == .installed {
        let entry = try store.entry(for: spec, isComplete: check)
        emit(entry, to: sink)
        sink.text("\(id) is already installed (\(formatBytes(entry.bytes)))")
        return
    }

    try await engine.install { progress in
        sink.modelProgress(model: id, progress)
    }

    let entry = try store.entry(for: spec, isComplete: check)
    sink.emit(.modelInstalled(.init(
        model: id, path: entry.directory.path, bytes: entry.bytes)))
    sink.text("Installed \(id) (\(formatBytes(entry.bytes))) in \(entry.directory.path)")
}

// MARK: - delete

private func modelsDelete(
    _ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String], usage: () -> String
) throws {
    guard let id = try requireID(arguments, usage: usage, verb: "delete") else { return }
    let store = ModelStore(root: globals.modelsDirectory)
    let known = store.installedRows()

    // Report the size before removing it, so the human output can say what was
    // reclaimed rather than just "done".
    //
    // Resolved through the same lenient path as `list` and `status`: the row
    // whose engine or variant this build cannot construct is precisely the row
    // a user has been told to delete, so letting a factory or parse error
    // escape here made `list` advertise a stale row that `delete` refused to
    // remove. A wrong id is still caught, by the exact-name check below.
    let walked = known.first { $0.id == id }?.directory
    let before = try resolveRow(id: id, walked: walked, globals: globals, store: store)

    guard before.state != .systemManaged else {
        throw SpeechError.usage(
            "'\(id)' has no files this tool owns; nothing to delete")
    }
    // Anything on disk must be named exactly as `list` prints it, whether or not
    // this build understands the row. The default volume is case-insensitive, so
    // `FLUID.parakeet-v3@int8` otherwise finds and removes the real `fluid/...`
    // row while reporting a catalog id that never existed, which an applet
    // cannot match to anything. Checking whenever the directory exists - rather
    // than only when the row is unknown - keeps this from depending on every
    // engine factory happening to be case-sensitive.
    if FileManager.default.fileExists(atPath: before.directory.path),
       !known.contains(where: { $0.id == id }) {
        let hint = known.map(\.id).first { $0.lowercased() == id.lowercased() }
        throw SpeechError.usage(
            "no model row named '\(id)'"
            + (hint.map { " (did you mean '\($0)'?)" } ?? ""))
    }
    // Deletes the directory that was found, not one re-derived from the id.
    guard try store.delete(at: before.directory, describedAs: id) else {
        sink.text("\(id) is not installed; nothing to delete")
        return
    }
    emit(ModelStoreEntry(catalogID: id, directory: before.directory, state: .missing), to: sink)
    sink.text("Deleted \(id) (\(formatBytes(before.bytes)) reclaimed)")
}

// MARK: - install-locale

private func modelsInstallLocale(
    _ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String], usage: () -> String
) async throws {
    var scanner = ArgScanner(verb: "models install-locale", arguments)
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage(usage())
            return
        case "--":
            scanner.endOptions()
        default:
            try scanner.addPositional(token)
        }
    }
    let tag = try scanner.requirePositional("bcp47")

    let installed = try await AppleSpeech.installLocale(tag) { progress in
        sink.modelProgress(model: "apple.\(Language.canonical(tag))", progress)
    }
    // One line per module that took the locale, and no stdout output: this
    // command's product is a side effect, like mkdir. Apple installs the asset
    // system-wide and publishes neither a path nor a size, so the event omits
    // both rather than inventing "system" and 0 bytes.
    for entry in installed {
        sink.emit(.modelInstalled(.init(model: "\(entry.engine)@\(entry.locale)")))
    }
}
