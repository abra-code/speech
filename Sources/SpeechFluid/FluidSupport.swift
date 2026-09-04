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

    static func canary(precision: CanaryPrecision) -> ModelCompletenessCheck {
        { directory in CanaryModels.modelsExist(at: directory, precision: precision) }
    }

    static var ctc: ModelCompletenessCheck {
        { directory in CtcModels.modelsExist(at: directory) }
    }

    /// Nemotron multilingual has no `modelsExist`, so the list is ours. The
    /// tokenizer and metadata are included deliberately: `metadata.json` holds
    /// the prompt dictionary that `setLanguage` reads, and a download that
    /// stopped before it produces a model that loads and then cannot be
    /// pointed at a language.
    static var nemotronMultilingual: ModelCompletenessCheck {
        requiring([
            "preprocessor.mlmodelc", "encoder.mlmodelc", "decoder.mlmodelc",
            "joint.mlmodelc", "tokenizer.json", "metadata.json",
        ])
    }

    /// Parakeet Unified, likewise. The encoder is matched by prefix because its
    /// file name carries the precision.
    static var unified: ModelCompletenessCheck {
        { directory in
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
            let set = Set(names)
            let required = [
                "parakeet_unified_decoder.mlmodelc",
                "parakeet_unified_joint_decision_single_step.mlmodelc",
                "vocab.json", "metadata.json",
            ]
            guard required.allSatisfy(set.contains) else { return false }
            return names.contains { $0.hasPrefix("parakeet_unified_encoder") && $0.hasSuffix(".mlmodelc") }
        }
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
