// FluidSupport.swift - the adapters between FluidAudio's vocabulary and ours.
//
// Everything FluidAudio-shaped that is not an engine lives here: how its
// download progress becomes a `model.progress` event, how a BCP-47 tag becomes
// its `Language`, and which files on disk mean a row is complete. Keeping these
// out of the engine classes means the four engine families share one answer
// each instead of drifting apart.

import Foundation
import FluidAudio
import SpeechCore

// MARK: - Progress

enum FluidProgress {
    /// Maps FluidAudio's `DownloadProgress` onto our `LoadProgress`.
    ///
    /// FluidAudio counts *files*, not bytes: `downloading` carries
    /// `(completedFiles, totalFiles)` and a `fractionCompleted`. Our event has
    /// byte fields, and filling them with file counts would put "3 of 11 bytes"
    /// in a status line, so they stay nil and the counts go into `file` where
    /// the renderer already prints free text.
    /// What the caller is doing, because FluidAudio does not distinguish.
    ///
    /// Its loading path re-runs the same cache-check machinery as its download
    /// path and reports `.downloading` while doing so. Passed through
    /// unchanged, `speech transcribe` on an installed model emits
    /// `phase: "downloading"` and the applet puts up a download bar for a model
    /// already on disk. During a load nothing can be fetched - `prepare`
    /// verified the row is installed and throws `modelMissing` otherwise - so
    /// every phase there is honestly "making it usable", which is `compiling`.
    enum Activity {
        case installing
        case loading
    }

    static func map(_ progress: DownloadProgress, during activity: Activity) -> LoadProgress {
        // An empty model name is FluidAudio's placeholder; nil means "no file"
        // in our protocol and an empty string would print as a blank filename.
        func named(_ raw: String) -> String? { raw.isEmpty ? nil : raw }

        switch progress.phase {
        case .listing:
            return LoadProgress(phase: .listing, fraction: progress.fractionCompleted)
        case .downloading(let completed, let total):
            guard activity == .installing else {
                return LoadProgress(phase: .compiling, fraction: progress.fractionCompleted)
            }
            return LoadProgress(
                phase: .downloading,
                fraction: progress.fractionCompleted,
                file: total > 0 ? "\(completed) of \(total) files" : nil)
        case .compiling(let modelName):
            // The first ANE compile of a CoreML package takes seconds with no
            // bytes moving and no file count changing. Naming the model is the
            // only thing that distinguishes it from a hang.
            return LoadProgress(
                phase: .compiling, fraction: progress.fractionCompleted, file: named(modelName))
        }
    }

    /// Wraps our handler as FluidAudio's. Returned as a value so each call site
    /// can pass it straight into a `progressHandler:` parameter.
    static func handler(
        _ activity: Activity, _ sink: @escaping LoadProgressHandler
    ) -> FluidProgressHandler {
        { progress in sink(map(progress, during: activity)) }
    }
}

// MARK: - Language

enum FluidLanguage {
    /// FluidAudio's `Language` from a BCP-47 tag or bare subtag.
    ///
    /// Parakeet v3 uses this as a *script and token filter* hint, not as a hard
    /// selector - the model is multilingual and will transcribe without it, so
    /// an unrecognized tag is a warning and a nil, never a failure. The 28
    /// cases here are the European set; anything outside it (Japanese, Chinese,
    /// Arabic) belongs to a different model family.
    static func parakeet(_ tag: String?) -> FluidASRLanguage? {
        guard let tag, !tag.isEmpty else { return nil }
        return FluidASRLanguage(rawValue: SpeechCore.Language.primarySubtag(tag))
    }

    /// Every primary subtag Parakeet v3 accepts, for `EngineCapabilities`.
    static var parakeetLanguages: [String] {
        FluidASRLanguage.allCases.map(\.rawValue).sorted()
    }
}

// MARK: - Completeness

/// Which files have to be present for a row to count as installed.
///
/// Where FluidAudio ships its own `modelsExist(at:)` we call that instead of
/// keeping a parallel file list, because the list is theirs to change: a pin
/// bump that renames an mlmodelc would otherwise leave us reporting a complete
/// model that cannot load. The explicit lists below are only for the families
/// that expose no such check.
///
/// Their `modelsExist` functions are NOT interchangeable, and this is a trap.
/// `AsrModels.modelsExist` rewrites the directory it is given through the
/// private `repoPath(from:)` (see `FluidPaths`), so it must be handed
/// `<row>/<folderName>`. `CanaryModels.modelsExist` does no such rewrite and
/// checks files directly under its argument, so it must be handed the row
/// directory itself. Passing either one the other's convention produces a
/// check that silently looks in the wrong place. Verify which convention a
/// family uses by reading its source before adding a row here.
enum FluidModelFiles {
    /// `AsrModels.modelsExist` for the given Parakeet flavor, applied to the
    /// repo subdirectory rather than the row directory - see
    /// `FluidPaths.parakeetRepo`, which explains why there is one.
    static func parakeet(
        version: AsrModelVersion, precision: ParakeetEncoderPrecision
    ) -> ModelCompletenessCheck {
        { directory in
            AsrModels.modelsExist(
                at: FluidPaths.parakeetRepo(in: directory, version: version),
                version: version, encoderPrecision: precision)
        }
    }

    /// `CanaryModels.modelsExist`, plus the check it is missing.
    ///
    /// Theirs is `fileExists` over five names, four of which are `.mlmodelc`
    /// *directories*. The downloader creates each bundle directory before it
    /// fetches a single file inside it, so for most of a 569 MB download all
    /// five paths exist and none of the weights are complete. Taking their
    /// answer alone made an interruption in that window - which is the normal
    /// place to be interrupted, not an edge case - report `installed` at 0 B,
    /// clear the partial marker, and fail later at `MLModel(contentsOf:)`
    /// instead of at exit 3.
    ///
    /// `isCompiledBundle` is the answer, and it is FluidAudio's own: their
    /// `ModelCache` calls a `.mlmodelc` loadable when it is a directory holding
    /// `coremldata.bin` with no `.partial` staging file left underneath. This
    /// check was written before that was found, requiring only the manifest;
    /// sharing the validator adds the staging-file half, which matters because
    /// a bundle can carry its manifest and still be missing the weights that
    /// were in flight.
    ///
    /// It still is not airtight - a truncated `weight.bin` that was fully
    /// renamed into place would pass - and nothing short of a checksum would.
    static func canary(precision: CanaryPrecision) -> ModelCompletenessCheck {
        { directory in
            CanaryModels.modelsExist(at: directory, precision: precision)
                && canaryBundles(precision: precision).allSatisfy {
                    isCompiledBundle(directory.appendingPathComponent("\($0).mlmodelc"))
                }
        }
    }

    /// The four compiled bundles a Canary row must carry.
    ///
    /// `CanaryPrecision.encoderName` and `.decoderName` say this already but
    /// are internal to FluidAudio, so the mapping is repeated here from their
    /// public `ModelNames.Canary` constants. Duplication is safe in this one
    /// direction: this list only ever *adds* a requirement on top of
    /// `CanaryModels.modelsExist`, so a name that drifted out of date makes a
    /// row read as permanently incomplete - loud and immediate - rather than as
    /// wrongly complete.
    static func canaryBundles(precision: CanaryPrecision) -> [String] {
        let encoder: String
        let decoder: String
        switch precision {
        case .int4:
            encoder = ModelNames.Canary.encoderInt4
            decoder = ModelNames.Canary.decoderInt4
        case .int8:
            encoder = ModelNames.Canary.encoderInt8
            decoder = ModelNames.Canary.decoderInt8
        case .fp16:
            encoder = ModelNames.Canary.encoder
            decoder = ModelNames.Canary.decoder
        @unknown default:
            encoder = ModelNames.Canary.encoderInt4
            decoder = ModelNames.Canary.decoderInt4
        }
        return [ModelNames.Canary.preprocessor, ModelNames.Canary.projection, encoder, decoder]
    }

    /// Every entry a Canary row owns: the four bundles, the vocabulary the
    /// tokenizer reads, and the repo's own metadata. This is what `adopt` takes
    /// out of the shared cache, so anything else there - another application's
    /// weights for a different precision, most obviously - is left alone rather
    /// than dragged into this row.
    static func canaryEntries(precision: CanaryPrecision) -> Set<String> {
        Set(canaryBundles(precision: precision).map { "\($0).mlmodelc" })
            .union([ModelNames.Canary.vocabularyFile, "metadata.json"])
    }

    /// Deletes the required entries that are present but unusable, so that
    /// FluidAudio's own existence-only `modelsExist` cannot mistake a truncated
    /// cache for a finished one and skip the fetch that would repair it.
    ///
    /// Without this, an interrupted download is unrepairable and the program
    /// cannot say so. `CanaryModels.download` early-returns on the same
    /// five-path test described above, so a cache holding four empty bundle
    /// directories makes every retry fetch nothing, forever, and the only
    /// repair is deleting a cache directory this program never names.
    ///
    /// Deliberately not `force: true`, which FluidAudio offers and which would
    /// be one line: that removes the whole repo directory, and the directory is
    /// shared per repository rather than per precision, so it would destroy
    /// another application's complete Canary while repairing ours. Only entries
    /// that are present *and* incomplete are removed, so a complete bundle is
    /// never touched no matter who downloaded it.
    static func evictIncompleteCanary(at directory: URL, precision: CanaryPrecision) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        for name in canaryBundles(precision: precision) {
            let bundle = directory.appendingPathComponent("\(name).mlmodelc")
            guard fm.fileExists(atPath: bundle.path),
                  !fm.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path)
            else { continue }
            try? fm.removeItem(at: bundle)
        }
        // An empty vocab.json satisfies their check and then throws inside the
        // tokenizer, which is the same failure one step later.
        let vocabulary = directory.appendingPathComponent(ModelNames.Canary.vocabularyFile)
        if let size = try? fm.attributesOfItem(atPath: vocabulary.path)[.size] as? Int, size == 0 {
            try? fm.removeItem(at: vocabulary)
        }
    }

    static var ctc: ModelCompletenessCheck {
        { directory in CtcModels.modelsExist(at: directory) }
    }

    /// Nemotron multilingual ships no `modelsExist`, so this list is ours - and
    /// it is deliberately *not* the file list in the plan's appendix, which was
    /// copied from the repo contents rather than from the loader.
    ///
    /// What `loadModels(from:)` and `process(samples:)` between them actually
    /// insist on is: `metadata.json` (it throws by name without it),
    /// `tokenizer.json`, an encoder, and *some* decode path. Three files in the
    /// appendix list are not requirements at all. `preprocessor.mlmodelc` is
    /// never opened - the mel front-end is native Swift (`NemotronMelExtractor`)
    /// and the CoreML preprocessor is vestigial. `decoder` and `joint` are
    /// loaded through `locateOptionalModelBundle` and may be absent entirely,
    /// because the "lean B1" ships replace the pair with a fused
    /// `decoder_joint`, `decoder_joint_noencproj` or `decoder_joint_argmax`.
    ///
    /// Requiring the appendix list would report `partial` for a download that
    /// loads and transcribes perfectly, and `finishInstall` would then refuse
    /// to clear the marker - an install that can never succeed. So the check
    /// below is a transcription of the loader's own guard, and every entry is
    /// accepted as either a compiled `.mlmodelc` or an uncompiled `.mlpackage`,
    /// which is the same pair `locateModelBundle` accepts.
    static func nemotronMultilingual(chunkMs: Int) -> ModelCompletenessCheck {
        { rowDirectory in
            let directory = FluidPaths.nemotronVariant(in: rowDirectory, chunkMs: chunkMs)
            let fm = FileManager.default
            func present(_ name: String) -> Bool {
                fm.fileExists(atPath: directory.appendingPathComponent(name).path)
            }
            // A compiled bundle counts only when its manifest is inside it.
            // `.mlmodelc` is a directory, and the downloader creates the
            // directory before it fetches the files within, so testing the
            // directory alone reports a half-written encoder as complete -
            // `finishInstall` then clears the partial marker, `models status`
            // says installed, and the failure surfaces later as a load error
            // rather than as exit 3 and a download instruction. Every compiled
            // bundle FluidAudio ships carries `coremldata.bin` at its root.
            //
            // An uncompiled `.mlpackage` is checked by existence only: this
            // program's downloads skip them entirely, so the case exists to
            // match what `locateModelBundle` will accept, not to validate a
            // download of ours.
            func bundle(_ base: String) -> Bool {
                present("\(base).mlmodelc/coremldata.bin") || present("\(base).mlpackage")
            }
            guard present("metadata.json"), present("tokenizer.json"), bundle("encoder") else {
                return false
            }
            return (bundle("decoder") && bundle("joint"))
                || bundle("decoder_joint")
                || bundle("decoder_joint_noencproj")
                || bundle("decoder_joint_argmax")
        }
    }

    /// Parakeet Unified.
    ///
    /// The file list is FluidAudio's own - the `requiredFiles` set their
    /// `loadModels(to:)` hands to `loadWithRecovery` - rather than a list read
    /// off the repository, so a pin bump that renames a bundle moves this with
    /// it. Note what is absent: the repo ships `parakeet_unified_preprocessor`
    /// and `parakeet_unified_mel_encoder`, and the loader opens neither,
    /// because the mel front end is computed in Swift.
    ///
    /// The bundle validation mirrors `ModelCache.validateCompiledModelLayout`,
    /// which is FluidAudio's own definition of a loadable `.mlmodelc`: a
    /// directory containing `coremldata.bin`. Their downloader applies it too,
    /// which is why this family needs none of the cache repair Canary does -
    /// but `prepare` never downloads, so the check still has to be able to tell
    /// a half-written bundle from a finished one on its own.
    static func unified(precision: UnifiedEncoderPrecision) -> ModelCompletenessCheck {
        { rowDirectory in
            let directory = FluidPaths.unifiedRepo(in: rowDirectory)
            let names = ModelNames.ParakeetUnified.self
            let required = [
                names.offlineEncoderFile(precision: precision),
                names.decoderFile,
                names.jointDecisionFile,
                names.vocab,
            ]
            return required.allSatisfy { name in
                let path = directory.appendingPathComponent(name)
                guard name.hasSuffix(".mlmodelc") else {
                    return FileManager.default.fileExists(atPath: path.path)
                }
                return isCompiledBundle(path)
            }
        }
    }

    /// A loadable compiled CoreML bundle: a directory with `coremldata.bin` in
    /// it and no `.partial` staging file left anywhere underneath.
    ///
    /// Both halves matter and both come from FluidAudio's own cache validator.
    /// The downloader creates a bundle directory before it fetches the files
    /// inside, so existence alone reports a half-written model as finished; and
    /// it stages each file as `<name>.partial`, so a bundle can hold
    /// `coremldata.bin` and still be missing the weights that were in flight.
    static func isCompiledBundle(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
        else { return false }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return true }
        for case let item as URL in walker where item.pathExtension == "partial" {
            return false
        }
        return true
    }

    /// A check that every named entry exists. Directory or file both count: a
    /// compiled CoreML model (`.mlmodelc`) is a directory, and a tokenizer is a
    /// file, and the caller should not have to say which is which.
    static func requiring(_ names: [String]) -> ModelCompletenessCheck {
        { directory in
            names.allSatisfy { name in
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(name).path)
            }
        }
    }
}

// MARK: - Paths

/// Where FluidAudio actually puts files, as opposed to where you ask it to.
///
/// Every `AsrModels` entry point that takes a directory runs it through a
/// private `repoPath(from:)`, which is
///
///     directory.deletingLastPathComponent().appendingPathComponent(repo.folderName)
///
/// So passing our row directory `<models>/fluid/parakeet-v3@int8` makes
/// FluidAudio download to, and look for, its *sibling*
/// `<models>/fluid/parakeet-tdt-0.6b-v3`. That is not hypothetical: the first
/// download did exactly that, and because `modelsExist` re-derives the same
/// way, the completeness check then passed against the sibling while the row
/// directory itself was empty - an install that reported success, measured zero
/// bytes, and would have failed to load.
///
/// Passing `<row>/<folderName>` makes the rewrite a no-op and puts the files
/// under the row we own. The folder name is read from FluidAudio's own default
/// cache path rather than hardcoded, so a pin bump that renames a repo moves
/// this with it instead of silently splitting the store in two.
enum FluidPaths {
    static func parakeetRepo(in rowDirectory: URL, version: AsrModelVersion) -> URL {
        rowDirectory.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
    }

    /// Where `UnifiedAsrManager.loadModels(to:)` puts its files.
    ///
    /// The same appending convention as Nemotron rather than the `AsrModels`
    /// rewrite: the argument is treated as a models root and the repo folder is
    /// appended, so handing it the row directory keeps everything inside the
    /// row and the loader's directory is one component below it.
    static func unifiedRepo(in rowDirectory: URL) -> URL {
        rowDirectory.appendingPathComponent(
            Repo.parakeetUnified.folderName, isDirectory: true)
    }

    /// The language code every Nemotron download in this program uses.
    ///
    /// Not the user's language, and that is the whole point. FluidAudio routes
    /// en/es/fr/it/pt/de to a vocab-pruned "latin" ship and everything else to
    /// the full multilingual one, so passing the caller's tag through would
    /// make one catalog id mean different weights on disk depending on who
    /// downloaded it first - and the second user would silently inherit the
    /// first user's model, with `models list` showing one row either way. The
    /// row id promises multilingual; "auto" is what delivers it.
    static let nemotronLanguageCode = "auto"

    /// Where `CanaryModels.download` puts its files, which is nowhere this
    /// program chose.
    ///
    /// This family's downloader takes no directory argument at all: it resolves
    /// to a private `modelsRootDirectory()` under `~/Library/Application
    /// Support/FluidAudio/Models`, and 0.15.6 exposes no repo-override hook.
    /// `load(from:)` and `modelsExist(at:)` do take a directory, so the route
    /// is download into their cache, move the tree into the row, then load the
    /// row - which is what `ModelStore.adopt` is for.
    ///
    /// Recomputed here rather than read back from `download`'s return value
    /// because `install` has to know whether the cache was already populated
    /// *before* it downloads: a cache some other application filled is not
    /// this program's to empty.
    static var canaryCache: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.canary1bV2.folderName, isDirectory: true)
    }

    /// Where `downloadVariant` puts a Nemotron multilingual ship.
    ///
    /// This family does not use the `AsrModels` rewrite. Its `to:` argument is
    /// treated as a models *root* and the files land at
    /// `<to>/<repo folderName>/<language directory>/<chunkMs>ms`, by appending
    /// rather than by replacing the last component. Handing it the row
    /// directory therefore keeps everything inside the row - there is no
    /// sibling to escape to here - but the directory that `loadModels(from:)`
    /// and the completeness check need is three components below the row, not
    /// the row itself.
    ///
    /// Both components are read from FluidAudio rather than spelled out, so a
    /// pin bump that renames the repo or re-routes "auto" moves this with it.
    static func nemotronVariant(in rowDirectory: URL, chunkMs: Int) -> URL {
        rowDirectory
            .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
            .appendingPathComponent(
                StreamingNemotronMultilingualAsrManager.languageDirectory(
                    for: nemotronLanguageCode),
                isDirectory: true)
            .appendingPathComponent("\(chunkMs)ms", isDirectory: true)
    }
}

// MARK: - Network policy

/// FluidAudio reaches for the network from code paths that look like pure
/// loads, so this program denies it by default and opens it only for an
/// explicit install.
///
/// `AsrModels.load` goes through `ModelHub.loadModels`, which on a load failure
/// that is not offline/cancellation/retryable calls
/// `ModelCache.purgeCorruptedCache(at:)` - an unconditional `removeItem` of the
/// whole repo folder - and then re-downloads it. `loadModelsOnce` likewise
/// downloads whenever `allModelsExist` is false. So on a machine that cannot
/// run one of the compiled mlmodelc bundles, `speech transcribe` would delete
/// the user's installed row, silently pull it again over the network, fail
/// identically, and leave the row unusable. That contradicts the invariant
/// `prepare` documents and that exit code 3 exists to express.
///
/// `ModelHub.offlineMode` is a process-global (`HFClient.offlineMode`, declared
/// `nonisolated(unsafe)`), so it is set to true once at engine construction and
/// cleared only for the duration of an install. That ordering is deliberate:
/// the default has to be the safe one, because a path we have not audited yet
/// inherits it.
enum FluidNetwork {
    /// KNOWN LIMIT, safe today, not safe for stage 5. This flag is one
    /// process-global and FluidAudio re-reads it per request, so it does not
    /// compose across concurrent engines: constructing a second engine during
    /// an install flips it back to true and aborts that download at the next
    /// file, and a `prepare` running while an install is suspended sees false,
    /// which puts the purge-and-refetch path back in play. The CLI is
    /// sequential so neither is reachable, but Speech.app drives several
    /// engines from one process. Before stage 4, this needs to become a
    /// serialized region (an actor owning the flag with a depth count) rather
    /// than a bare set/restore pair.
    ///
    /// Called from every engine's init. Idempotent.
    static func denyByDefault() {
        ModelHub.offlineMode = true
    }

    /// Opens the network for one explicit install. Always pair with a
    /// `defer { FluidNetwork.denyByDefault() }` in the same scope.
    ///
    /// Deliberately not a `withNetwork { ... }` closure: the call it wraps is
    /// actor-isolated, and handing an isolated closure to a nonisolated static
    /// is a Swift 6 sending violation. A bare pair with `defer` keeps the
    /// restore on every exit path, including a thrown error.
    static func allowDownloads() {
        ModelHub.offlineMode = false
    }
}
