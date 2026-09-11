// CatalogVerb.swift - `speech catalog`. The whole inventory in one place.
//
// `speech engines` says what this binary can construct and `speech models`
// says what is on disk. Neither says how big a row is, where its weights come
// from, or that two rows are the same model at different precisions. This verb
// joins SpeechCore's inventory with the two things only this target can see -
// the live capability record each engine reports, and the model store - and
// reports the result without ranking it.
//
// It does not choose. Which row to use depends on the language, the recording
// and the machine, and on measurements this program cannot take on a machine it
// is not running on. Speech.app decides that; see docs/catalog.md.

import Foundation
import SpeechCore
import SpeechApple
import SpeechFluid
import SpeechGGML
import SpeechMLX

/// What the join found wrong. A row and an engine can disagree in three ways,
/// and all three are build-time mistakes in this repository rather than
/// anything a user did.
struct CatalogJoinProblem {
    var id: String
    var message: String
}

/// One inventory entry: what the row is, what its engine says it can do,
/// whether that engine can run here, and what is on disk.
struct CatalogEntry {
    var row: CatalogRow
    var capabilities: EngineCapabilities
    var available: Bool
    var unavailableReason: String?
    var state: ModelInstallState
    /// Bytes on disk, when anything is there.
    var installedBytes: Int64?

}

/// The catalog rows paired with the capabilities their engines report.
///
/// Every direction is checked. A catalog row with no engine is a row nobody can
/// run; an engine with no catalog row is a model that never gets reported; and
/// a row whose repository or file name disagrees with the engine that will do
/// the download is a 404 halfway through a progress bar. All three are silent
/// unless something looks, and this is where something looks.
func catalogJoin() -> (entries: [CatalogFileRow], engines: [String: KnownEngine],
                       problems: [CatalogJoinProblem]) {
    var engines: [String: KnownEngine] = [:]
    for engine in knownEngines() { engines[engine.id] = engine }

    // Entries that loaded but that their engine cannot use - a ggml model with
    // no file, an mlx model with no type. Reported once, with the reason,
    // instead of as "has no engine" for each of their rows.
    let unusable = GGMLEngineFactory.catalogProblems + MLXEngineFactory.catalogProblems
    let unusableKeys = Set(unusable.map(\.key))

    var entries: [CatalogFileRow] = []
    var problems: [CatalogJoinProblem] = unusable.map {
        CatalogJoinProblem(id: $0.key, message: $0.message)
    }
    var joined: Set<String> = []
    for row in Catalog.rows {
        let key = String(row.id.prefix(while: { $0 != "@" }))
        if unusableKeys.contains(key) { continue }
        guard let engine = engines[row.id] else {
            problems.append(CatalogJoinProblem(
                id: row.id, message: "catalog row '\(row.id)' has no engine in this build"))
            continue
        }
        joined.insert(row.id)
        if let problem = provenanceProblem(row) {
            problems.append(problem)
            continue
        }
        entries.append(CatalogFileRow(row: row, capabilities: engine.capabilities))
    }
    for orphan in engines.keys.sorted() where !joined.contains(orphan) {
        problems.append(CatalogJoinProblem(
            id: orphan,
            message: "engine '\(orphan)' has no catalog row; add one to the catalog"))
    }
    return (entries, engines, problems)
}

/// The inventory states where a row's weights come from, and so does the engine
/// that would fetch them. Two copies of a repository name that nothing compares
/// is how a rename becomes a download failure instead of a build failure, so
/// they are compared here, where both are visible.
func provenanceProblem(_ row: CatalogRow) -> CatalogJoinProblem? {
    guard let spec = try? EngineSpec.parse(
        catalogID: row.id, modelsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    else {
        return CatalogJoinProblem(id: row.id, message: "catalog id '\(row.id)' does not parse")
    }
    func mismatch(_ what: String, _ ours: String?, _ theirs: String) -> CatalogJoinProblem {
        CatalogJoinProblem(
            id: row.id,
            message: "catalog row '\(row.id)' says \(what) \(ours ?? "-")"
                + " but the engine would use \(theirs)")
    }
    switch row.engine {
    case "ggml":
        // A ggml row is one named file in one repository, and both halves are
        // derived from the same stem, so both are checked.
        guard let weights = GGMLEngineFactory.weights(for: spec.model, variant: spec.variant)
        else {
            return CatalogJoinProblem(
                id: row.id, message: "the ggml engine has no weights for '\(row.id)'")
        }
        if weights.repo != row.source { return mismatch("repository", row.source, weights.repo) }
        if weights.file != row.file { return mismatch("file", row.file, weights.file) }
    case "fluid":
        // A fluid row downloads a directory, so there is a repository to check
        // and no single file name.
        guard let source = FluidEngineFactory.source(for: spec.model, variant: spec.variant)
        else {
            return CatalogJoinProblem(
                id: row.id, message: "the fluid engine has no repository for '\(row.id)'")
        }
        if source != row.source { return mismatch("repository", row.source, source) }
    default:
        // Apple's assets are installed by the OS; there is nothing to compare.
        break
    }
    return nil
}

/// The inventory with the machine-dependent facts filled in.
func catalogEntries(
    _ globals: GlobalOptions, _ rows: [CatalogFileRow], _ engines: [String: KnownEngine]
) throws -> [CatalogEntry] {
    let store = ModelStore(root: globals.modelsDirectory)
    var out: [CatalogEntry] = []
    for fileRow in rows {
        // Every row here came out of the join, which already refused any row
        // without an engine, so this cannot fail - but a silent `continue`
        // would make a future change drop a model from the listing without
        // saying so, which is the failure this file exists to prevent.
        guard let engine = engines[fileRow.row.id] else {
            throw SpeechError.runtime("no engine for '\(fileRow.row.id)' after the join")
        }
        // A store read per row: two dozen directory walks against a models
        // directory that is usually empty or nearly so. Cheap enough to do
        // eagerly, and the alternative - reporting every row as "not installed"
        // until asked - is exactly the wrong default for a caller building a
        // model list.
        let spec = try EngineSpec.parse(
            catalogID: fileRow.row.id, modelsDirectory: globals.modelsDirectory)
        let stored = try? entry(for: spec, store: store)
        out.append(CatalogEntry(
            row: fileRow.row, capabilities: engine.capabilities,
            available: engine.available, unavailableReason: engine.reason,
            state: stored?.state ?? .unknown,
            installedBytes: (stored?.bytes).flatMap { $0 > 0 ? $0 : nil }))
    }
    return out
}

func catalogJSON(_ entry: CatalogEntry) -> [String: Any] {
    var out: [String: Any] = [
        "id": entry.row.id,
        "family": entry.row.family.rawValue,
        "engine": entry.row.engine,
        "role": entry.row.role.rawValue,
        "label": entry.row.label,
        "precision": entry.row.precision,
        "state": entry.state.rawValue,
        "installed": entry.state == .installed || entry.state == .systemManaged,
        "available": entry.available,
        "capabilities": entry.capabilities.featureFlags,
        "modes": entry.capabilities.modeFlags,
        "languages": entry.capabilities.languages,
        "minimum_macos": entry.capabilities.minimumMacOS,
    ]
    if let source = entry.row.source { out["source"] = source }
    if let file = entry.row.file { out["file"] = file }
    if let parameters = entry.row.parametersM { out["params_m"] = parameters }
    if let size = entry.row.sizeBytes { out["size_bytes"] = size }
    if let bytes = entry.installedBytes { out["installed_bytes"] = bytes }
    if let reason = entry.unavailableReason { out["reason"] = reason }
    return out
}

func catalogSourcesJSON() -> [String: Any] {
    let catalog = Catalog.current
    var out: [String: Any] = [:]
    if let builtin = catalog.builtinDirectory { out["builtin"] = builtin.path }
    if let user = catalog.userDirectory {
        out["user"] = user.path
        out["user_exists"] = FileManager.default.fileExists(atPath: user.path)
    }
    return out
}

func runCatalog(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    var scanner = ArgScanner(verb: "catalog", arguments)
    var wantTSV = false
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage("""
                Usage: \(kProgram) catalog [--tsv]

                Lists every way this build can run speech recognition: each row's
                model family, where its weights come from, how big they are, what
                the loaded model says it can do, and whether it is installed.

                This is an inventory, not a recommendation. It does not rank rows
                or score them - which model to use depends on the language, the
                machine and the recording, and deciding that is Speech.app's job.

                Options:
                  --tsv   Write the inventory as models.catalog.tsv instead. The
                          checked-in copy at docs/models.catalog.tsv is this
                          output; test.sh regenerates it and fails on a change.

                The rows are JSON documents: the built-in ones in speech-catalog/
                beside this binary, then any *.json in the user catalog directory
                ($SPEECH_CATALOG_DIR, default ~/Library/Application Support/
                Speech/Catalog). A user entry with the same engine and model as a
                built-in one replaces it, "hidden": true unlists one, and a new
                engine and model adds one. The format is in docs/catalog.md.
                """)
            return
        case "--tsv":
            wantTSV = true
        case "--":
            scanner.endOptions()
        default:
            try scanner.addPositional(token)
        }
    }
    try scanner.requireNoPositionals()

    // Refused before any work: --json promises stdout carries nothing but JSON,
    // and the applet's scripts rely on that. Checked here rather than after the
    // join so the answer is the same usage error whatever else is wrong.
    if wantTSV, globals.json {
        throw SpeechError.usage(
            "catalog: --tsv writes a TSV file and cannot be combined with --json")
    }

    let join = catalogJoin()

    if wantTSV {
        // The TSV is checked in and diffed by test.sh, so it must be the whole
        // inventory or nothing. Everywhere else a partial answer beats no
        // answer; here a partial file would be committed and become the truth.
        if let problem = join.problems.first {
            throw SpeechError.runtime(problem.message)
        }
        sink.document(try CatalogFile.text(
            join.entries, generator: "\(kProgram) catalog --tsv",
            environment: SpeechEnvironment.facts()))
        return
    }

    // Listing degrades instead: a build mistake in one row must not cost a
    // caller the other twenty-three, and the message that helps them is "this
    // row is missing", not "add one to Catalog.swift".
    for problem in join.problems { sink.warning(problem.message, code: "catalog_join") }

    let entries = try catalogEntries(globals, join.entries, join.engines)

    if globals.json {
        let payload: [String: Any] = [
            "machine": [
                "chip": SystemInfo.chip,
                "memory_bytes": SystemInfo.physicalMemoryBytes,
                "macos": SystemInfo.operatingSystemVersion,
            ],
            // What produced the capability columns below, so two runs can be
            // told apart rather than looking like a contradiction.
            "environment": SpeechEnvironment.json(),
            "models_dir": globals.modelsDirectory.path,
            // Where the rows came from, so a caller can find the file to edit
            // and tell a user's addition from a built-in row.
            "catalog": catalogSourcesJSON(),
            "rows": entries.map(catalogJSON),
        ]
        sink.document(try CLIHelpers.jsonString(payload, compact: true))
        return
    }

    let width = entries.map { $0.row.id.count }.max() ?? 0
    var family: CatalogFamily?
    for entry in entries {
        if entry.row.family != family {
            if family != nil { sink.text("") }
            sink.text("\(entry.row.family.rawValue):")
            family = entry.row.family
        }
        let name = entry.row.id.padding(toLength: width, withPad: " ", startingAt: 0)
        // An Apple row has no size because it has no download, which is a
        // different statement from a size nobody has measured.
        let size = entry.row.sizeBytes.map { formatBytes($0) }
            ?? (entry.row.engine == "apple" ? "no download" : "size unknown")
        var notes: [String] = []
        switch entry.state {
        case .installed: notes.append("installed")
        case .systemManaged: notes.append("installed with macOS")
        case .partial: notes.append("partly downloaded")
        case .missing, .unknown: break
        }
        if entry.row.role == .helper { notes.append("helper") }
        if !entry.available { notes.append(entry.unavailableReason ?? "unavailable") }
        let suffix = notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"
        sink.text("  \(name)  \(size)\(suffix)")
        var facts: [String] = [entry.row.label]
        let flags = entry.capabilities.allFlags
        if !flags.isEmpty { facts.append(flags.joined(separator: ", ")) }
        let count = entry.capabilities.languages.count
        facts.append(count == 0 ? "any language" : (count == 1 ? "1 language" : "\(count) languages"))
        sink.text("  \(String(repeating: " ", count: width))  \(facts.joined(separator: "; "))")
    }
}
