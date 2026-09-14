// AppleSpeechSupport.swift - the availability gate and the locale plumbing that
// both Apple engines share.
//
// Three gates, the pattern mlx-agent uses for Foundation Models:
//
//   compile time  #if canImport(Speech) - always true on macOS, kept so the
//                 target can be dropped from a future non-Apple build without
//                 editing call sites.
//   link time     nothing to do. Speech.framework itself has shipped since
//                 macOS 10.15, so the framework links normally at our 14.0
//                 deployment target; only the SpeechAnalyzer generation of
//                 classes inside it is new, and Swift weak-imports those from
//                 the @available annotations.
//   run time      `#available(macOS 26, *)` for both engines, plus
//                 SpeechTranscriber.isAvailable for apple.transcriber alone.
//                 That property exists on SpeechTranscriber and nowhere else
//                 in the SDK: Apple names DictationTranscriber as the module to
//                 use where SpeechTranscriber is not available, so gating
//                 dictation on it would take away the fallback exactly where
//                 it is needed.
//
// Everything here reports a reason when it says no. "unavailable" with no
// explanation is the failure mode that makes a user reinstall an OS for
// nothing.

import Foundation
import SpeechCore

#if canImport(Speech)
import Speech
#endif

public enum AppleSpeech {
    public static let transcriberID = "apple.transcriber"
    public static let dictationID = "apple.dictation"

    /// Languages SpeechTranscriber covers, as primary subtags: the 30 locales
    /// it reported on this Mac (Apple M5, macOS 26.6.2) collapsed to their
    /// primary subtags.
    ///
    /// These lists are for display and for the catalog's language filter, and
    /// they can go stale when Apple ships a locale in an OS update. They are
    /// never the gate: `prepare()` asks `supportedLocale(equivalentTo:)` for
    /// the real answer, and `speech info` prints the live lists, which is how a
    /// drift gets noticed. Re-derive them from `speech info` when it does.
    public static let transcriberLanguages = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "yue", "zh",
    ]

    /// DictationTranscriber's 54 locales collapse to these 33 primary subtags.
    /// This is the set that matters for the product: it is where Polish,
    /// Czech, Ukrainian, Russian and Croatian come from, none of which
    /// SpeechTranscriber offers at all.
    public static let dictationLanguages = [
        "ar", "ca", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "hr",
        "hu", "id", "it", "ja", "ko", "ms", "nb", "nl", "pl", "pt", "ro", "ru", "sk",
        "sv", "th", "tr", "uk", "vi", "yue", "zh",
    ]

    public enum Availability: Sendable, Equatable {
        case available
        case osTooOld(String)
        case notAvailable(String)

        public var isAvailable: Bool { self == .available }

        public var reason: String? {
            switch self {
            case .available: return nil
            case .osTooOld(let r), .notAvailable(let r): return r
            }
        }
    }

    /// Whether one Apple engine can run on this Mac, and why not when it cannot.
    ///
    /// Neither engine needs Siri or keyboard dictation turned on: that was
    /// SFSpeechRecognizer's requirement, and Apple says in the SpeechAnalyzer
    /// session (WWDC25 277) that it no longer applies. A missing locale is not
    /// unavailability either - the engine installs it on first use.
    public static func availability(for kind: AppleEngineKind) -> Availability {
        #if canImport(Speech)
        if #available(macOS 26, *) {
            return decide(
                kind, osVersion: SystemInfo.operatingSystemVersion, osSupported: true,
                longFormAvailable: SpeechTranscriber.isAvailable)
        }
        return decide(
            kind, osVersion: SystemInfo.operatingSystemVersion, osSupported: false,
            longFormAvailable: false)
        #else
        return .notAvailable("this build has no Speech framework")
        #endif
    }

    /// A tag with no region, onto the module's locale for the language's main
    /// region: "it" is it_IT and never it_CH, "nl" is nl_NL and never nl_BE.
    /// nil when the tag names a region, or when the module has no locale for
    /// the main region (Arabic has only ar_SA, and "yue" has no yue_HK), and
    /// then `supportedLocale(equivalentTo:)` decides as before.
    ///
    /// Asked first because Apple's own answer for a bare language is whichever
    /// variant it lists first, and that changes: on macOS 26.6.2 it gave it_CH
    /// for "it" and nl_BE for dictation's "nl", where earlier the same macOS
    /// had given de_AT for "de" and fr_CA for "fr".
    static func mainRegional(_ tag: String, in available: [Locale]) -> Locale? {
        guard let region = Language.mainRegion(tag) else { return nil }
        let wanted = "\(Language.primarySubtag(tag))_\(region)"
        return available.first { $0.identifier == wanted }
    }

    /// The rule without the system calls, so it can be tested on a Mac where
    /// every answer is yes.
    static func decide(
        _ kind: AppleEngineKind, osVersion: String, osSupported: Bool, longFormAvailable: Bool
    ) -> Availability {
        guard osSupported else {
            return .osTooOld(
                "Apple's on-device speech engines need macOS 26 or later"
                + " (this Mac runs macOS \(osVersion))")
        }
        if kind == .transcriber && !longFormAvailable {
            return .notAvailable(
                "macOS reports SpeechTranscriber, Apple's long-form model, as not available on this Mac;"
                + " \(dictationID) does not depend on it and runs here")
        }
        return .available
    }

    /// What `speech info` reports about the built-in engines.
    public struct LocaleReport: Sendable {
        public var engine: String
        public var supported: [String]
        public var installed: [String]
    }

    public static func localeReports() async -> [LocaleReport] {
        #if canImport(Speech)
        guard #available(macOS 26, *) else { return [] }
        async let transcriberSupported = SpeechTranscriber.supportedLocales
        async let transcriberInstalled = SpeechTranscriber.installedLocales
        async let dictationSupported = DictationTranscriber.supportedLocales
        async let dictationInstalled = DictationTranscriber.installedLocales
        return [
            LocaleReport(
                engine: transcriberID,
                supported: await transcriberSupported.map(\.identifier).sorted(),
                installed: await transcriberInstalled.map(\.identifier).sorted()),
            LocaleReport(
                engine: dictationID,
                supported: await dictationSupported.map(\.identifier).sorted(),
                installed: await dictationInstalled.map(\.identifier).sorted()),
        ]
        #else
        return []
        #endif
    }
}

#if canImport(Speech)

@available(macOS 26, *)
enum AppleLocaleInstaller {
    /// Resolve a user-supplied tag onto a locale the module actually has.
    ///
    /// `supportedLocale(equivalentTo:)` alone is NOT a support test, which is
    /// the trap this function exists to close. Measured on macOS 26.6.2, it
    /// returns pl_PL, cs_CZ and uk_UA for SpeechTranscriber - none of which
    /// appear in SpeechTranscriber.supportedLocales, and all of which
    /// AssetInventory then reports as `.unsupported`. It returns nil only for
    /// languages the framework has never heard of. So it is a normalizer ("pt"
    /// onto whichever Portuguese variant Apple ships), and the authoritative
    /// membership test is `supportedLocales`.
    ///
    /// Getting this wrong is not cosmetic: a Polish request would be accepted
    /// by the long-form engine, reserve a locale, and fail several calls later
    /// with "Apple reports pl_PL as unsupported for this module" instead of
    /// "this engine has no Polish".
    static func resolve(
        requested: String?,
        moduleName: String,
        languages: [String],
        supportedLocales: () async -> [Locale],
        supportedLocale: (Locale) async -> Locale?
    ) async throws -> Locale {
        let identifier = Language.canonical(requested ?? "en-US")
        let available = await supportedLocales()
        if let main = AppleSpeech.mainRegional(identifier, in: available) {
            return main
        }
        let wanted = Locale(identifier: identifier)
        guard let resolved = await supportedLocale(wanted) else {
            throw SpeechError.unsupportedLanguage(
                "\(moduleName) has no model for '\(identifier)'; run 'speech info' for the list it does have")
        }
        guard available.contains(where: { $0.identifier == resolved.identifier }) else {
            let covered = languages.isEmpty
                ? ""
                : "; it covers \(languages.joined(separator: " "))"
            throw SpeechError.unsupportedLanguage(
                "\(moduleName) has no model for '\(identifier)'\(covered)."
                + " Run 'speech info' for the locales it does have")
        }
        return resolved
    }

    /// Whether this module has a model for the tag, without throwing. Used by
    /// `install-locale`, which has to try both modules and install for
    /// whichever ones can take it.
    static func supports(
        _ tag: String,
        supportedLocales: () async -> [Locale],
        supportedLocale: (Locale) async -> Locale?
    ) async -> Locale? {
        let available = await supportedLocales()
        if let main = AppleSpeech.mainRegional(tag, in: available) {
            return main
        }
        guard let resolved = await supportedLocale(Locale(identifier: Language.canonical(tag))) else {
            return nil
        }
        return available.contains { $0.identifier == resolved.identifier } ? resolved : nil
    }

    /// Reserve the locale and install its assets, reporting progress.
    ///
    /// Reservations are capped (`maximumReservedLocales`, 5 on macOS 26.6.2)
    /// and survive the process, so a tool that reserves a new locale on every
    /// run would eventually hit the cap and start failing for no reason a user
    /// can see. Room is made only when it is actually needed: an earlier
    /// version released every other reservation on every run, which meant that
    /// transcribing something in Polish dropped the German the user had
    /// installed the day before - a destructive side effect of a read-only
    /// sounding operation.
    static func install(
        locale: Locale,
        modules: [any SpeechModule],
        progress report: @escaping LoadProgressHandler
    ) async throws {
        var reserved = await AssetInventory.reservedLocales
        if !reserved.contains(locale) {
            let cap = AssetInventory.maximumReservedLocales
            while reserved.count >= cap, let oldest = reserved.first {
                let released = await AssetInventory.release(reservedLocale: oldest)
                reserved.removeFirst()
                // Observed on macOS 26.6.2: installing Spanish released German,
                // and German then no longer appeared in installedLocales.
                // Apple answers false when it released nothing, and a warning
                // about a language that is still there would be wrong.
                if released {
                    report(LoadProgress(
                        phase: .listing, file: locale.identifier, releasedLocale: oldest.identifier))
                }
            }
        }
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            throw SpeechError.unavailable(
                "cannot reserve locale \(locale.identifier): \(error.localizedDescription)")
        }

        report(LoadProgress(phase: .listing, file: locale.identifier))
        let status = await AssetInventory.status(forModules: modules)
        if status == .installed { return }
        if status == .unsupported {
            // resolve() should have caught this. If it fires anyway, Apple's
            // own two answers disagree, and saying so beats a bare refusal.
            throw SpeechError.unsupportedLanguage(
                "\(locale.identifier) is listed as supported but AssetInventory reports it as"
                + " unsupported; this locale cannot be installed on this Mac")
        }

        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: modules)
        } catch {
            throw SpeechError.unavailable(
                "cannot request speech assets for \(locale.identifier): \(error.localizedDescription)")
        }
        guard let request else {
            // Nothing to install and yet not installed: treat as installed and
            // let the transcription attempt produce the real error, rather than
            // inventing one here.
            return
        }

        // Progress is a Foundation.Progress, so KVO is the only way to watch
        // it. The observation is held for the duration of the install and
        // released after, which is what keeps the callback alive.
        let identifier = locale.identifier
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            report(LoadProgress(
                phase: .installing,
                fraction: progress.fractionCompleted,
                file: identifier))
        }
        defer { observation.invalidate() }

        do {
            try await request.downloadAndInstall()
        } catch {
            throw SpeechError.unavailable(
                "installing speech assets for \(identifier) failed: \(error.localizedDescription)")
        }
        report(LoadProgress(phase: .installing, fraction: 1.0, file: identifier))
    }
}

#endif

// MARK: - Locale installation as a command

extension AppleSpeech {
    public struct InstalledLocale: Sendable {
        public var engine: String
        public var locale: String
    }

    /// `speech models install-locale <bcp47>`. Installs the asset for every
    /// built-in module that has a model for the tag, and says which.
    ///
    /// The verification step at the end is not paranoia: the plan records a
    /// case (Arabic) where a locale appears in `supportedLocales`, the install
    /// reports success, and the locale never turns up in `installedLocales`.
    /// Reporting that as a failure is the only way the user learns the model
    /// they picked will not work.
    public static func installLocale(
        _ tag: String,
        progress: @escaping LoadProgressHandler
    ) async throws -> [InstalledLocale] {
        #if canImport(Speech)
        guard #available(macOS 26, *) else {
            throw SpeechError.unavailable(availability(for: .dictation).reason ?? "macOS 26 or later required")
        }
        var installed: [InstalledLocale] = []
        var failures: [String] = []
        var skipped: [String] = []

        // Each module is asked separately and a module that has no model for
        // this tag is skipped, not fatal. The long-form engine covers ten
        // languages and the dictation engine thirty-three; installing Polish
        // has to succeed on the strength of the second even though the first
        // has nothing to offer.
        // A long-form model this Mac cannot run has no assets worth installing,
        // and must not stop the dictation half from installing.
        if let reason = availability(for: .transcriber).reason {
            skipped.append("\(transcriberID): \(reason)")
        } else if let locale = await AppleLocaleInstaller.supports(
            tag,
            supportedLocales: { await SpeechTranscriber.supportedLocales },
            supportedLocale: { await SpeechTranscriber.supportedLocale(equivalentTo: $0) })
        {
            let module = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            try await AppleLocaleInstaller.install(locale: locale, modules: [module], progress: progress)
            if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) {
                installed.append(InstalledLocale(engine: transcriberID, locale: locale.identifier))
            } else {
                failures.append("\(transcriberID): \(locale.identifier) still reports as not installed")
            }
        }

        if let locale = await AppleLocaleInstaller.supports(
            tag,
            supportedLocales: { await DictationTranscriber.supportedLocales },
            supportedLocale: { await DictationTranscriber.supportedLocale(equivalentTo: $0) })
        {
            let module = DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            try await AppleLocaleInstaller.install(locale: locale, modules: [module], progress: progress)
            if await DictationTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) {
                installed.append(InstalledLocale(engine: dictationID, locale: locale.identifier))
            } else {
                failures.append("\(dictationID): \(locale.identifier) still reports as not installed")
            }
        }

        if installed.isEmpty {
            if failures.isEmpty && skipped.isEmpty {
                throw SpeechError.unsupportedLanguage(
                    "neither built-in engine has a model for '\(tag)'")
            }
            if failures.isEmpty {
                throw SpeechError.unsupportedLanguage(
                    "\(dictationID) has no model for '\(tag)', and macOS reports \(transcriberID)"
                    + " as not available on this Mac")
            }
            throw SpeechError.unavailable((failures + skipped).joined(separator: "; "))
        }
        return installed
        #else
        throw SpeechError.unavailable("this build has no Speech framework")
        #endif
    }
}
