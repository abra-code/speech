// AppleEngine.swift - `apple.transcriber` and `apple.dictation`.
//
// These two are the baseline the whole catalog is measured against, so their
// job is to be a faithful, unembellished wrapper: no chunking, no retries, no
// post-processing that a third-party row would not also get. Whatever Apple's
// model does with a clip is what gets scored.
//
// The two ids are one class because the difference between them is three
// values, not three code paths:
//
//   apple.transcriber   SpeechTranscriber, long-form, 9 languages, ignores
//                       contextual strings entirely (confirmed by an Apple
//                       engineer in forum thread 801877) - so it reports
//                       vocabulary: false rather than silently dropping them.
//   apple.dictation     DictationTranscriber, short-form, 54 locales including
//                       Polish, and the only Apple module that accepts a
//                       custom vocabulary.
//
// Both are fed the decoded 16 kHz samples written back out as a temporary wav.
// That looks wasteful and is deliberate: SpeechAnalyzer only takes an
// AVAudioFile, and letting it open the user's original media would mean Apple
// decoded the audio with its own resampler while every other engine got ours,
// which would quietly corrupt every WER comparison in the product.

import AVFoundation
import Foundation
import SpeechCore

#if canImport(Speech)
import Speech
#endif

public enum AppleEngineFactory {
    /// Registry entry point. Sync, because the registry is: the availability
    /// check that needs macOS 26 lives inside, and an old system gets a clear
    /// `unavailable` here rather than a link failure at launch.
    public static func make(_ spec: EngineSpec) throws -> any TranscriptionEngine {
        #if canImport(Speech)
        guard #available(macOS 26, *) else {
            throw SpeechError.unavailable(AppleSpeech.availability().reason ?? "macOS 26 or later required")
        }
        switch spec.model {
        case "transcriber":
            return AppleEngine(kind: .transcriber, catalogID: spec.catalogID)
        case "dictation":
            return AppleEngine(kind: .dictation, catalogID: spec.catalogID)
        default:
            throw SpeechError.usage(
                "unknown Apple model '\(spec.model)' (want apple.transcriber or apple.dictation)")
        }
        #else
        throw SpeechError.unavailable("this build has no Speech framework")
        #endif
    }

    public static func capabilities(for model: String) -> EngineCapabilities? {
        switch model {
        case "transcriber": return AppleEngineKind.transcriber.capabilities
        case "dictation": return AppleEngineKind.dictation.capabilities
        default: return nil
        }
    }
}

public enum AppleEngineKind: Sendable {
    case transcriber
    case dictation

    var catalogID: String {
        switch self {
        case .transcriber: return AppleSpeech.transcriberID
        case .dictation: return AppleSpeech.dictationID
        }
    }

    var displayName: String {
        switch self {
        case .transcriber: return "SpeechTranscriber"
        case .dictation: return "DictationTranscriber"
        }
    }

    public var capabilities: EngineCapabilities {
        switch self {
        case .transcriber:
            return EngineCapabilities(
                batch: true,
                // Live since stage 4: SpeechAnalyzer takes a push sequence of
                // buffers and emits volatile results, which is what
                // AppleLiveSession drives.
                live: true,
                wordTimestamps: true,
                segmentTimestamps: true,
                vocabulary: false,
                diarization: false,
                languageID: false,
                languageHint: true,
                languages: AppleSpeech.transcriberLanguages,
                minimumMacOS: "26.0")
        case .dictation:
            return EngineCapabilities(
                batch: true,
                live: true,
                wordTimestamps: true,
                segmentTimestamps: true,
                vocabulary: true,
                diarization: false,
                languageID: false,
                languageHint: true,
                languages: AppleSpeech.dictationLanguages,
                minimumMacOS: "26.0")
        }
    }
}

#if canImport(Speech)

@available(macOS 26, *)
actor AppleEngine: TranscriptionEngine {
    nonisolated let id: String
    nonisolated let capabilities: EngineCapabilities

    private let kind: AppleEngineKind
    /// The locale whose assets are known to be installed. Cached because an
    /// eval run asks 758 times in a row and the AssetInventory round trip is
    /// not free.
    private var preparedLocale: Locale?
    /// Kept from `prepare` so that a locale switch during `transcribe` still
    /// reports its progress. Installing an Apple locale asset can take minutes,
    /// and a caller that sees `engine.ready` and then silence assumes a hang.
    private var progressHandler: LoadProgressHandler = { _ in }
    private var scratchDirectory: URL?
    private var nextSegmentID = 0

    init(kind: AppleEngineKind, catalogID: String) {
        self.kind = kind
        self.id = catalogID
        self.capabilities = kind.capabilities
    }

    @discardableResult
    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        progressHandler = progress
        // The identifier, not the primary subtag: "de" resolves to de_AT here
        // and a measurement that does not record that is not reproducible.
        return try await ensureLocale(language).identifier
    }

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        guard !samples.isEmpty else { return [] }
        // Re-prepares when the request names a different language than prepare
        // did, still reporting progress through the handler prepare was given.
        let locale = try await ensureLocale(options.language)

        let vocabulary = options.vocabulary.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let module = makeModule(locale: locale, live: false)

        let context = AnalysisContext()
        if !vocabulary.isEmpty, capabilities.vocabulary {
            context.contextualStrings[.general] = vocabulary
        }

        // The wav and the directory holding it both go on every exit path.
        // Only `unload()` used to remove the directory, and the verbs skip
        // unload when transcribe throws, so a failed run left one behind.
        let audioURL = try writeScratchWAV(samples: samples)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent())
            scratchDirectory = nil
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            throw SpeechError.runtime("cannot reopen decoded audio: \(error.localizedDescription)")
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        if !vocabulary.isEmpty, capabilities.vocabulary {
            try await analyzer.setContext(context)
        }

        // Start reading before starting analysis. The results sequence is not
        // replayed: a consumer attached after the analyzer has already emitted
        // would miss the beginning of short clips.
        let collector = ResultCollector()
        let reading = Task { [kind] in
            switch kind {
            case .transcriber:
                guard let transcriber = module as? SpeechTranscriber else { return }
                for try await result in transcriber.results where result.isFinal {
                    await collector.append(text: result.text, range: result.range)
                }
            case .dictation:
                guard let transcriber = module as? DictationTranscriber else { return }
                for try await result in transcriber.results where result.isFinal {
                    await collector.append(text: result.text, range: result.range)
                }
            }
        }

        do {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            try await reading.value
        } catch {
            reading.cancel()
            await analyzer.cancelAndFinishNow()
            throw SpeechError.runtime(
                "\(kind.displayName) failed: \(error.localizedDescription)")
        }

        let collected = await collector.take()
        return collected.enumerated().map { offset, item in
            makeSegment(
                id: nextSegmentID + offset,
                text: item.text,
                range: item.range,
                language: locale.identifier)
        }
        .also { nextSegmentID += collected.count }
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        // Same locale resolution and the same asset install as the batch path,
        // so `speech stream --language pl` downloads Polish once and both
        // commands then find it installed.
        let locale = try await ensureLocale(options.language)
        let vocabulary = options.vocabulary.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let module = makeModule(locale: locale, live: true)

        var context: AnalysisContext?
        if !vocabulary.isEmpty, capabilities.vocabulary {
            let made = AnalysisContext()
            made.contextualStrings[.general] = vocabulary
            context = made
        }
        return try await AppleLiveSession.make(
            module: module, kind: kind, locale: locale, context: context)
    }

    func unload() async {
        preparedLocale = nil
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
            self.scratchDirectory = nil
        }
    }

    // MARK: - Locale and modules

    private func ensureLocale(_ language: String?) async throws -> Locale {
        switch AppleSpeech.availability() {
        case .available:
            break
        case .osTooOld(let reason), .notAvailable(let reason):
            throw SpeechError.unavailable(reason)
        }

        let resolved: Locale
        switch kind {
        case .transcriber:
            resolved = try await AppleLocaleInstaller.resolve(
                requested: language, moduleName: kind.displayName,
                languages: capabilities.languages,
                supportedLocales: { await SpeechTranscriber.supportedLocales },
                supportedLocale: { await SpeechTranscriber.supportedLocale(equivalentTo: $0) })
        case .dictation:
            resolved = try await AppleLocaleInstaller.resolve(
                requested: language, moduleName: kind.displayName,
                languages: capabilities.languages,
                supportedLocales: { await DictationTranscriber.supportedLocales },
                supportedLocale: { await DictationTranscriber.supportedLocale(equivalentTo: $0) })
        }

        if preparedLocale == resolved { return resolved }

        let module = makeModule(locale: resolved, live: false)
        try await AppleLocaleInstaller.install(
            locale: resolved, modules: [module], progress: progressHandler)
        preparedLocale = resolved
        return resolved
    }

    private func makeModule(locale: Locale, live: Bool) -> any SpeechModule {
        switch kind {
        case .transcriber:
            return SpeechTranscriber(
                locale: locale,
                // No .etiquetteReplacements: masking profanity would change the
                // words and therefore the WER, and this row is the ruler
                // everything else is measured against.
                transcriptionOptions: [],
                reportingOptions: live ? [.volatileResults] : [],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        case .dictation:
            return DictationTranscriber(
                locale: locale,
                contentHints: [],
                // Keyboard dictation emits unpunctuated text by default. For a
                // transcript that is not what anyone wants, and the scorer
                // strips punctuation anyway, so it costs nothing measurable.
                transcriptionOptions: [.punctuation],
                reportingOptions: live ? [.volatileResults] : [],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        }
    }

    // MARK: - Result mapping

    /// Both the batch path and the live session map results the same way, and
    /// the mapping lives in `AppleResults` so they cannot drift apart.
    private func makeSegment(id: Int, text: AttributedString, range: CMTimeRange, language: String) -> Segment {
        AppleResults.segment(id: id, text: text, range: range, language: language)
    }

    // MARK: - Scratch audio

    private func writeScratchWAV(samples: [Float]) throws -> URL {
        let directory: URL
        if let scratchDirectory {
            directory = scratchDirectory
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("speech-apple-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            scratchDirectory = directory
        }
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try AudioDecoder.writeWAV(samples: samples, to: url)
        return url
    }
}

/// Results arrive on the analyzer's task; this collects them without making the
/// engine actor reentrant in the middle of a transcription.
@available(macOS 26, *)
private actor ResultCollector {
    struct Item {
        var text: AttributedString
        var range: CMTimeRange
    }

    private var items: [Item] = []

    func append(text: AttributedString, range: CMTimeRange) {
        items.append(Item(text: text, range: range))
    }

    func take() -> [Item] {
        defer { items = [] }
        return items
    }
}

private extension Array {
    /// Run a side effect and return self, so a mapped result can bump a counter
    /// without an intermediate `let`.
    func also(_ body: () -> Void) -> [Element] {
        body()
        return self
    }
}

#endif
