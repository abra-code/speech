// ModelsAddVerb.swift - `speech models add <owner/repo>`: register a
// transcribe.cpp model the catalog does not describe, by downloading it and
// asking it.
//
// transcribe.cpp loads any GGUF whose architecture it knows, from a path alone,
// and reports its own languages, language identification, streaming and
// timestamps. So the catalog entry for a model nobody wrote one for can be
// written by the program: pick the file, download it into the store exactly as
// `models download` would, load it, and record what it said. A file whose
// architecture the library does not know fails to load with the library's own
// reason, and then nothing is kept - neither the download nor an entry.
//
// The entry goes to the user catalog as `<model>.json`, one file per model,
// which this verb owns and rewrites; a person's own files are never edited.
// Adding a quantization of a built-in model copies the built-in entry into that
// file with the new variant beside the old ones, because a user entry replaces
// a built-in one whole.

import Foundation
import SpeechCore
import SpeechGGML

func modelsAddUsage() -> String {
    """
    Usage: \(kProgram) models add <owner/repo> [--quant <q>] [--file <name.gguf>]
                                   [--model <name>] [--label <text>]

    Registers a transcribe.cpp model from a Hugging Face repository: downloads
    one GGUF into the model store, loads it to read what it can do, and writes a
    catalog entry for it to the user catalog directory, so it becomes
    ggml.<model>@<quant> in every other verb.

    Options:
      --quant <q>       Which quantization to take, e.g. q8_0 or q4_k_m. With
                        neither this nor --file: the only .gguf in the
                        repository, else its Q8_0.
      --file <name>     The exact file to take, as the repository lists it.
      --model <name>    The <model> part of the id. Default: the file name
                        without its quantization, lowercased.
      --label <text>    The display name. Default: file stem and quantization.

    A model transcribe.cpp cannot load is refused with the library's reason, and
    its download is removed. Running it again for a model already added only
    finishes the download.
    """
}

func modelsAdd(_ globals: GlobalOptions, _ sink: EventSink, _ arguments: [String]) async throws {
    var scanner = ArgScanner(verb: "models add", arguments)
    var quant: String?
    var file: String?
    var modelOption: String?
    var label: String?
    while let token = scanner.nextToken() {
        switch token {
        case "--help", "-h":
            CLIHelpers.printUsage(modelsAddUsage())
            return
        case "--quant": quant = try scanner.value(token).lowercased()
        case "--file": file = try scanner.value(token)
        case "--model": modelOption = try scanner.value(token)
        case "--label": label = try scanner.value(token)
        case "--": scanner.endOptions()
        default: try scanner.addPositional(token)
        }
    }
    let repo = try scanner.requirePositional("owner/repo")
    let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw SpeechError.usage("'\(repo)' is not a Hugging Face repository (want owner/name)")
    }

    // Which file, and what to call it.
    let listing = try await HuggingFace.tree(repo: repo)
    let chosen = try GGMLAddition.chooseFile(
        from: listing.map(\.path), quant: quant, file: file, repo: repo)
    let parsed = GGMLAddition.split(chosen)
    // --quant names the variant of a file whose name carries none
    // (`--file model.gguf --quant f16`). Given with a file whose name says
    // otherwise, it would record a Q4_K_M file as q8_0.
    if file != nil, let quant, let own = parsed.quant, own.lowercased() != quant {
        throw SpeechError.usage(
            "'\(chosen)' is \(own), not \(quant.uppercased()); drop --quant or pick another --file")
    }
    guard let variantName = GGMLAddition.idName(quant ?? parsed.quant ?? "") else {
        throw SpeechError.usage(
            "cannot tell the quantization of '\(chosen)' from its name; pass --quant <name>")
    }
    guard let model = try modelOption.map(validModelName) ?? GGMLAddition.modelName(
        stem: parsed.stem, repo: repo)
    else {
        throw SpeechError.usage("cannot make a model name out of '\(chosen)'; pass --model <name>")
    }
    let id = "ggml.\(model)@\(variantName)"
    let key = "ggml.\(model)"
    let size = listing.first { $0.path == chosen }?.size
    let variant = GGMLAddition.variant(
        name: variantName, file: chosen, sizeBytes: size,
        label: label ?? "\(parsed.stem) (\(parsed.quant ?? variantName.uppercased()))")

    // Where the entry will live, and whether this is a new model or another
    // variant of one the catalog already has.
    let catalog = Catalog.current
    let userDirectory = catalog.userDirectory ?? Catalog.userDirectory()
    let target = userDirectory.appendingPathComponent("\(model).json")
    let existing = catalog.models.first { $0.key == key }
    if let existing {
        guard existing.source == repo else {
            throw SpeechError.usage(
                "'\(key)' already comes from \(existing.source ?? "another source");"
                + " give this one another name with --model")
        }
        if let known = existing.variant(named: variantName) {
            guard (known.file ?? existing.file) == chosen else {
                throw SpeechError.usage(
                    "'\(id)' is already in the catalog as '\(known.file ?? existing.file ?? "-")';"
                    + " use another --model or --quant")
            }
            sink.text("\(id) is already in the catalog; downloading it if needed")
            try await downloadIfNeeded(id, globals, sink)
            return
        }
        if let origin = catalog.origins[key],
           let user = catalog.userDirectory,
           origin.deletingLastPathComponent().standardizedFileURL.path == user.standardizedFileURL.path,
           origin.lastPathComponent != target.lastPathComponent {
            throw SpeechError.usage(
                "'\(key)' is defined in \(origin.path), a file this command does not edit;"
                + " add the '\(variantName)' variant there by hand")
        }
    }
    // The file is rewritten whole, so it may only be one this command wrote
    // for this model: the origin of exactly this key and of no other. A
    // person's own `gsx.json` describing some other model, or holding this one
    // beside others, would otherwise be replaced by a single entry. Judged from
    // the load rather than by re-reading the file, so a file whose entries were
    // all dropped with a warning counts as somebody else's too.
    if FileManager.default.fileExists(atPath: target.path) {
        let resolved = target.resolvingSymlinksInPath().path
        let holders = catalog.origins.filter { $0.value.resolvingSymlinksInPath().path == resolved }
        guard holders.keys.elementsEqual([key]) else {
            throw SpeechError.usage(
                "\(target.path) already exists and is not the file this command wrote for '\(key)';"
                + " move it aside, or pick another --model")
        }
    }

    // A provisional entry, so the engine can build the row and the store can
    // download it like any other. The capability fields are filled in from the
    // loaded model below, before anything is written.
    var provisional = existing ?? CatalogModel(
        engine: "ggml", model: model, family: CatalogFamily(rawValue: "unknown"), source: repo)
    provisional.variants = (provisional.variants ?? []) + [variant]
    // Checked before the download, not only after the probe: a --label of ""
    // or a control character in a name would otherwise fetch the whole file
    // and then refuse the entry, leaving the download behind with nothing
    // pointing at it.
    if let problem = catalogProblem(provisional) {
        throw SpeechError.usage("the entry for \(id) would not load back: \(problem)")
    }
    Catalog.install(catalog.replacing(provisional, from: target))

    let spec = try EngineSpec.parse(catalogID: id, modelsDirectory: globals.modelsDirectory)
    let store = ModelStore(root: globals.modelsDirectory)
    let wasInstalled: Bool
    do {
        wasInstalled = try await downloadIfNeeded(id, globals, sink, quietWhenPresent: true)
    } catch {
        Catalog.install(catalog)
        throw error
    }

    let probe: GGMLProbe
    do {
        probe = try await GGMLEngineFactory.probe(spec)
    } catch {
        // Nothing is kept for a model the library cannot run: not the entry,
        // and not a download this run made. A directory that was already there
        // belongs to whoever put it there.
        Catalog.install(catalog)
        var removed = ""
        if !wasInstalled, (try? store.delete(spec)) == true { removed = "; the download was removed" }
        let reason = (error as? SpeechError)?.message ?? error.localizedDescription
        throw SpeechError.runtime(
            "transcribe.cpp cannot use \(chosen) from \(repo): \(reason)\(removed)")
    }

    var entry: CatalogModel
    if var extended = existing {
        extended.variants = extended.declaredVariants + [variant]
        entry = extended
    } else {
        entry = GGMLAddition.entry(model: model, repo: repo, variant: variant, probe: probe)
    }
    if let problem = catalogProblem(entry) {
        Catalog.install(catalog)
        throw SpeechError.runtime("the entry for \(id) would not load back: \(problem)")
    }

    let data = try LoadedCatalog.documentData(models: [entry])
    do {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    } catch {
        Catalog.install(catalog)
        throw SpeechError.runtime("cannot write \(target.path): \(error.localizedDescription)")
    }
    Catalog.install(catalog.replacing(entry, from: target))

    if globals.json {
        let payload: [String: Any] = [
            "id": id,
            "catalog_file": target.path,
            "family": entry.family.rawValue,
            "architecture": probe.architecture,
            "languages": probe.languages,
            "language_id": probe.languageID,
            "streaming": probe.streaming,
            "word_timestamps": probe.wordTimestamps,
            "segment_timestamps": probe.segmentTimestamps,
        ]
        sink.document(try CLIHelpers.jsonString(["added": payload], compact: true))
        return
    }
    let count = probe.languages.count
    let languages = count == 0
        ? "no language list"
        : "\(count) language\(count == 1 ? "" : "s") (\(probe.languages.joined(separator: " ")))"
    sink.text("Added \(id): architecture \(probe.architecture), \(languages)"
        + (probe.languageID ? ", detects the language" : ", needs --language")
        + (probe.streaming ? ", streams" : ""))
    if existing != nil, catalog.origins[key].map({ $0.path != target.path }) ?? false {
        sink.text("Copied the built-in entry for \(key) there with the new variant;"
            + " it now replaces the built-in one.")
    }
    sink.text("Catalog entry: \(target.path)")
}

/// A `--model` value as given, if it is a usable id component.
private func validModelName(_ name: String) throws -> String {
    guard CatalogModel.isName(name) else {
        throw SpeechError.usage(
            "--model '\(name)' must be lowercase letters, digits, '.', '_' and '-'")
    }
    return name
}

/// What a freshly built entry would be refused for when it is read back, so
/// nothing is written that the next run would drop with a warning.
private func catalogProblem(_ entry: CatalogModel) -> String? {
    do {
        let data = try LoadedCatalog.documentData(models: [entry])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-add-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("entry.json"))
        let loaded = try LoadedCatalog.load(builtin: directory)
        return loaded.problems.first
    } catch let error as SpeechError {
        return error.message
    } catch {
        return error.localizedDescription
    }
}

/// Downloads a row unless it is installed. Returns whether it already was.
@discardableResult
private func downloadIfNeeded(
    _ id: String, _ globals: GlobalOptions, _ sink: EventSink, quietWhenPresent: Bool = false
) async throws -> Bool {
    let spec = try EngineSpec.parse(catalogID: id, modelsDirectory: globals.modelsDirectory)
    let store = ModelStore(root: globals.modelsDirectory)
    let engine = try makeRegistry().make(spec)
    guard let check = engine.completenessCheck else {
        throw SpeechError.runtime("'\(id)' has no weights of its own to download")
    }
    if try store.state(of: spec, isComplete: check) == .installed {
        if !quietWhenPresent { sink.text("\(id) is already installed") }
        return true
    }
    try await engine.install { progress in sink.modelProgress(model: id, progress) }
    let entry = try store.entry(for: spec, isComplete: check)
    sink.emit(.modelInstalled(.init(model: id, path: entry.directory.path, bytes: entry.bytes)))
    sink.text("Installed \(id) (\(formatBytes(entry.bytes))) in \(entry.directory.path)")
    return false
}
