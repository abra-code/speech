// VocabularyBooster.swift - hotword biasing for the FluidAudio rows, and the
// `fluid.parakeet-ctc-110m` row it needs.
//
// The mechanism is Argmax-style CTC keyword spotting used as a *rescorer*: a
// small CTC model runs over the same audio the transcriber already saw, and
// where the acoustics support one of the caller's terms better than the word
// that was emitted, the word is replaced. It runs after transcription and never
// changes the timings, so a failure to boost is a transcript that is merely
// unbiased rather than a transcript that is wrong.
//
// It lives in its own file because two engines share it and neither owns it,
// and because getting it pointed at this program's model store rather than
// FluidAudio's private cache is the whole design problem - see `load`.

import Foundation
import FluidAudio
import SpeechCore

/// The catalog row holding the CTC spotter, as a dependency of the rows that
/// can use it rather than a transcriber in its own right.
enum VocabularySpotter {
    /// The id a user downloads, deletes and sees in `models list`.
    static let catalogID = "fluid.parakeet-ctc-110m"

    static func spec(modelsDirectory: URL) throws -> EngineSpec {
        try EngineSpec.parse(catalogID: catalogID, modelsDirectory: modelsDirectory)
    }

    /// Where the row's files live once installed.
    static func directory(modelsDirectory: URL) throws -> URL {
        try ModelStore(root: modelsDirectory).directory(for: spec(modelsDirectory: modelsDirectory))
    }
}

/// A loaded spotter plus a caller's terms, ready to rescore transcripts.
///
/// Immutable once built: the term list is baked into the rescorer, so a caller
/// whose vocabulary changes builds a new one. That is cheap relative to the
/// model load, which is the part worth caching.
struct VocabularyBooster: Sendable {
    /// The terms this instance was built for, so a caller can tell whether the
    /// one it cached still matches the request.
    let terms: [String]

    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer
    private let vocabulary: CustomVocabularyContext
    private let sizeConfig: ContextBiasingConstants.VocabSizeConfig

    /// The rescorer thresholds, and a deliberate deviation from FluidAudio's
    /// own recommendation.
    ///
    /// They ship two configurations. `.default` is documented for engines whose
    /// output is spelled out ("thirty five percent"), where the
    /// spotter-anchored rescue pass is what recovers a brand name the model
    /// mangled. `itnDefaultConfig` raises two similarity floors and is
    /// documented for inverse-text-normalized engines ("35.3%"), where one
    /// short written word covers seconds of audio and the same pass will
    /// otherwise match a term against that span at garbage similarity (their
    /// issue #702).
    ///
    /// By that rule `fluid.parakeet-unified` takes the floors and
    /// `fluid.parakeet-v3` does not - the two really do differ, and it was
    /// checked rather than assumed: on the same clip v3 writes "one hundred
    /// percent" and unified writes "100%".
    ///
    /// Both rows use the floors anyway, because `.default` was measured doing
    /// real damage on the v3 batch path. Three FLEURS rows, three terms, and
    /// every one of them came out worse:
    ///
    ///   - "said the accused appeared in court" -> "Solanki Chandra"
    ///   - "The normal local price is 500 Congolese francs" -> "The normal
    ///     local Congolese francs"
    ///   - "First Lady Cristina Fernandez de Kirchner" -> "First Lady Kirchner
    ///     de Kirchner"
    ///
    /// The last two are the damning ones: the model already had the term right,
    /// and boosting deleted correct words around it. With the floors, all three
    /// rows are clean on both engines and the Solanki row gains three correct
    /// proper nouns.
    ///
    /// Their guidance is presumably right for `SlidingWindowAsrManager`, which
    /// is what it names; this row is the batch `AsrManager`, whose token
    /// timings come from a different decoder, and the rescue pass is timed
    /// against those. The asymmetry decides it either way: the loose config's
    /// worst case is destroying text that was already correct, the tight one's
    /// is declining to improve text that was already wrong.
    private static let rescorerConfig = VocabularyBoostingSession.itnDefaultConfig

    /// Builds a booster from a spotter row that is already on disk.
    ///
    /// **Deliberately not `VocabularyBoostingSession`**, which is FluidAudio's
    /// own wrapper for exactly this and which the plan named. Its initializer
    /// resolves the CTC tokenizer through
    /// `CtcModels.defaultCacheDirectory(for:)` - a hardcoded path under
    /// `~/Library/Application Support/FluidAudio/Models` - with no way to
    /// override it. The same is true of `configureVocabularyBoosting` on the
    /// managers, which builds one internally. Using either would mean the
    /// spotter's weights had to live in FluidAudio's private cache: invisible
    /// to `models list`, unreachable by `models delete`, and outside every
    /// guarantee the model store exists to provide.
    ///
    /// Everything underneath that wrapper is public, so this assembles the same
    /// pipeline pointed at our own row. The cost is that `rescore` below
    /// mirrors ~20 lines of theirs; the comment there says what it mirrors so
    /// the two can be compared on a pin bump.
    ///
    /// It also is not optional. `AsrManager`, which drives `fluid.parakeet-v3`,
    /// has no `configureVocabularyBoosting` at all - only the sliding-window
    /// and unified managers do - so the manual path is needed for that row
    /// whatever we do about the cache directory. One path for both rows beats
    /// two.
    /// Throws `modelMissing` when the spotter row is absent or incomplete.
    ///
    /// Separated from `load` so an engine's `validate` can ask the question
    /// without paying for the model load - which is the whole point, since the
    /// answer is a filesystem check and the alternative is discovering it after
    /// transcribing an hour of audio.
    static func requireSpotter(modelsDirectory: URL) throws {
        let row = try VocabularySpotter.directory(modelsDirectory: modelsDirectory)
        guard FluidModelFiles.ctc(row) else {
            throw SpeechError.modelMissing(
                "custom vocabulary needs the '\(VocabularySpotter.catalogID)' spotter,"
                + " which is not installed;"
                + " run 'speech models download \(VocabularySpotter.catalogID)'")
        }
    }

    static func load(terms: [String], modelsDirectory: URL) async throws -> VocabularyBooster {
        try requireSpotter(modelsDirectory: modelsDirectory)
        let row = try VocabularySpotter.directory(modelsDirectory: modelsDirectory)
        let repo = FluidPaths.ctcRepo(in: row)

        let models: CtcModels
        let tokenizer: CtcTokenizer
        do {
            // `loadDirect`, not `load`: the latter routes through
            // `ModelHub.loadModels`, which can fetch. This one opens the files
            // and nothing else, which is the guarantee every load path in this
            // module keeps.
            models = try await CtcModels.loadDirect(from: repo)
            tokenizer = try await CtcTokenizer.load(from: repo)
        } catch {
            throw SpeechError.runtime(
                "cannot load the vocabulary spotter from \(repo.path): \(error.localizedDescription)")
        }

        // Duplicates are removed before anything counts them. The rescorer
        // picks its similarity thresholds from the *number* of terms - the
        // buckets are at 10 and 100 - so eleven copies of one word would
        // tighten `minSimilarity` from 0.50 to 0.55 and change the output.
        var seen = Set<String>()
        let unique = terms.filter { seen.insert($0).inserted }

        // Two filters, and both have to happen here rather than being left to
        // FluidAudio.
        //
        // A term is tokenized with the *CTC* vocabulary, which is not the
        // transcriber's; one that tokenizes to nothing can never be spotted.
        //
        // And a term shorter than `minTermLength` is ignored by the spotter
        // anyway, because short ones are false-positive machines ("or" spotted
        // as "VR"). Leaving those in the list would still be wrong, because the
        // list's *length* selects the similarity thresholds - the buckets are
        // at 10 and 100 terms - so a dozen two-letter terms that can never
        // match would tighten the thresholds for the terms that can.
        let minimumLength = CustomVocabularyContext(terms: []).minTermLength
        var kept: [CustomVocabularyTerm] = []
        for term in unique where term.count >= minimumLength {
            let ids = tokenizer.encode(term)
            guard !ids.isEmpty else { continue }
            kept.append(CustomVocabularyTerm(
                text: term, weight: nil, aliases: nil, tokenIds: nil, ctcTokenIds: ids,
                minSimilarity: nil))
        }
        let context = CustomVocabularyContext(terms: kept)

        // Nothing usable is worth saying out loud. A per-term report would be
        // better - "AI was ignored, it is two characters" - but an engine has
        // no channel to warn on, the same gap the Nemotron row's dropped
        // language hint runs into. The all-or-nothing case is the one a user
        // is most likely to hit and least likely to diagnose, so it is an
        // error rather than a transcript that quietly ignored every term.
        guard !kept.isEmpty else {
            throw SpeechError.usage(
                "none of the \(unique.count) vocabulary terms can be used:"
                + " each is either shorter than \(minimumLength) characters"
                + " or cannot be spelled in the spotter's vocabulary")
        }

        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let rescorer: VocabularyRescorer
        do {
            rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: context,
                config: rescorerConfig,
                // The whole reason this type exists rather than a call to
                // theirs: the tokenizer comes from the row this program owns.
                ctcModelDirectory: repo)
        } catch {
            throw SpeechError.runtime(
                "cannot prepare vocabulary boosting: \(error.localizedDescription)")
        }

        return VocabularyBooster(
            terms: terms, spotter: spotter, rescorer: rescorer, vocabulary: context,
            sizeConfig: ContextBiasingConstants.rescorerConfig(forVocabSize: kept.count))
    }

    /// Rescores a transcript, returning the replacement text or nil when
    /// nothing changed.
    ///
    /// Mirrors `VocabularyBoostingSession.rescore`, which cannot be used for
    /// the reason given on `load`: spot the terms in the audio, then let the
    /// rescorer decide word by word whether the acoustic evidence beats what
    /// was emitted. The vocabulary-size-aware thresholds and the "respect the
    /// caller's floor when it is stricter" rule come from there too.
    ///
    /// Never throws. Boosting is an improvement on a transcript that already
    /// exists, so a CTC failure returns nil and the caller keeps what it had -
    /// which is also how FluidAudio treats it.
    ///
    /// KNOWN LIMIT: the spotter returns per-frame log probabilities for the
    /// whole file - 1025 floats every 80 ms - and accumulates each chunk before
    /// merging, so an hour of audio is on the order of 185 MB held twice, on
    /// top of the transcriber's own footprint. Passing `--vocab` therefore
    /// changes the memory profile of a long-file transcribe materially, and
    /// nothing caps it. Segmenting the rescore would fix it and is the obvious
    /// move if long files become a target.
    func rescore(text: String, timings: [TokenTiming], samples: [Float]) async -> String? {
        guard !terms.isEmpty, !timings.isEmpty, !samples.isEmpty else { return nil }
        do {
            let spotted = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: vocabulary, minScore: nil)
            guard !spotted.logProbs.isEmpty else { return nil }

            let output = rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: timings,
                logProbs: spotted.logProbs,
                frameDuration: spotted.frameDuration,
                cbw: sizeConfig.cbw,
                marginSeconds: 0.5,
                minSimilarity: max(sizeConfig.minSimilarity, vocabulary.minSimilarity))
            return output.wasModified ? output.text : nil
        } catch {
            return nil
        }
    }
}

/// `fluid.parakeet-ctc-110m` - a catalog row that is not a transcriber.
///
/// It exists so the CTC spotter is a first-class citizen of the model store:
/// downloadable, listable, sizable and deletable through exactly the commands
/// every other row uses, rather than a file that appears in a library's private
/// cache the first time somebody passes `--vocabulary`.
///
/// The cost of that choice is this shim, because `models download` reaches its
/// work through `TranscriptionEngine.install`. Everything else on the protocol
/// refuses with a reason: an id that cannot transcribe should say so rather
/// than fail somewhere less obvious.
actor SpotterEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities
    private nonisolated let check: ModelCompletenessCheck
    nonisolated var completenessCheck: ModelCompletenessCheck? { check }

    private let spec: EngineSpec
    private let store: ModelStore

    init(spec: EngineSpec) {
        self.spec = spec
        self.id = spec.catalogID
        self.store = ModelStore(root: spec.modelsDirectory)
        self.check = FluidModelFiles.ctc
        FluidNetwork.denyByDefault()
        self.capabilities = EngineCapabilities(
            // Every one of these is false, which is the honest description of a
            // row that cannot transcribe anything. `speech engines` lists it so
            // that a user who sees it in `models list` can find out what it is;
            // a picker built from `batch` will not offer it.
            batch: false,
            live: false,
            wordTimestamps: false,
            segmentTimestamps: false,
            // Not "this row accepts hotwords" - it is the machinery *behind*
            // hotwords for other rows, and claiming the capability here would
            // put it in the wrong list.
            vocabulary: false,
            diarization: false,
            languageID: false,
            languageHint: false,
            languages: ["en"],
            minimumMacOS: "15.0")
    }

    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        throw SpeechError.usage(
            "'\(id)' is the custom-vocabulary spotter used by other rows, not a transcriber;"
            + " pass --vocabulary to a row that supports it")
    }

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        throw SpeechError.usage("'\(id)' is a vocabulary spotter, not a transcriber")
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        throw SpeechError.usage("'\(id)' is a vocabulary spotter, not a transcriber")
    }

    func install(progress: @escaping LoadProgressHandler) async throws {
        let directory = try store.beginInstall(spec)
        FluidNetwork.allowDownloads()
        defer { FluidNetwork.denyByDefault() }
        do {
            // `ModelHub.download` rather than `CtcModels.download`, for three
            // reasons that all point the same way.
            //
            // It takes a progress handler and theirs does not, so this is the
            // only way `speech models download` can report anything at all for
            // 103 MB.
            //
            // It downloads rather than loading. Theirs calls
            // `ModelHub.loadModels` once per model name, so it compiles and
            // loads both CoreML models - twice - and throws the result away.
            //
            // And it has no "looks complete already" short circuit. Theirs
            // returns early when `modelsExist` passes, and that check is
            // existence-only over two directories plus `vocab.json` - it never
            // asks for `tokenizer.json`, which this row does need. A row
            // holding everything but the tokenizer would make every retry a
            // no-op while `finishInstall` kept failing: the Nemotron trap in a
            // new place. `ModelHub.download` re-checks each file and fetches
            // what is missing, so a retry resumes.
            //
            // `to:` is the row: ModelHub appends the repo folder itself, which
            // is what `FluidPaths.ctcRepo` describes.
            try await ModelHub.download(
                CtcModelVariant.ctc110m.repo,
                to: directory,
                progressHandler: FluidProgress.handler(.installing, progress))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.runtime("downloading '\(id)' failed: \(error.localizedDescription)")
        }
        try store.finishInstall(spec, isComplete: check)
    }

    func unload() async {}
}
