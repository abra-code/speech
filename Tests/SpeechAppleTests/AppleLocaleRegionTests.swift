// AppleLocaleRegionTests.swift - Apple's locale for a bare language is the one
// for its main region. The lists are Apple's own, as `supportedLocales`
// reported them on macOS 26.6.2, where `supportedLocale(equivalentTo:)` gave
// it_CH for "it" and nl_BE for "nl".

import Foundation
import Testing

@testable import SpeechApple

@Suite("Apple locale for a bare language")
struct AppleLocaleRegionTests {
    let dictation = ["ar_SA", "de_AT", "de_CH", "de_DE", "it_CH", "it_IT", "nl_BE", "nl_NL",
                     "pt_BR", "pt_PT", "yue_CN", "zh_CN", "zh_HK", "zh_TW"].map(Locale.init(identifier:))

    @Test("a bare language lands on its main region")
    func mainRegion() {
        #expect(AppleSpeech.mainRegional("it", in: dictation)?.identifier == "it_IT")
        #expect(AppleSpeech.mainRegional("nl", in: dictation)?.identifier == "nl_NL")
        #expect(AppleSpeech.mainRegional("de", in: dictation)?.identifier == "de_DE")
        #expect(AppleSpeech.mainRegional("pt", in: dictation)?.identifier == "pt_BR")
        #expect(AppleSpeech.mainRegional("zh-Hant", in: dictation)?.identifier == "zh_TW")
    }

    @Test("Apple's own answer decides when there is no main-region locale or a region was asked")
    func fallsBack() {
        // Arabic's main region is Egypt, and Apple ships only ar_SA.
        #expect(AppleSpeech.mainRegional("ar", in: dictation) == nil)
        #expect(AppleSpeech.mainRegional("yue", in: dictation) == nil)
        #expect(AppleSpeech.mainRegional("it-CH", in: dictation) == nil)
        #expect(AppleSpeech.mainRegional("es-419", in: dictation) == nil)
    }

    @Test("resolve and install-locale take the main region over Apple's first pick")
    func resolverUsesMainRegion() async throws {
        guard #available(macOS 26, *) else { return }
        let list = dictation
        // Apple's resolver as measured: the first Italian it lists.
        let applePick: (Locale) async -> Locale? = { locale in
            Locale.Language(identifier: locale.identifier).languageCode?.identifier == "it"
                ? Locale(identifier: "it_CH") : Locale(identifier: "ar_SA")
        }
        let resolved = try await AppleLocaleInstaller.resolve(
            requested: "it", moduleName: "DictationTranscriber", languages: ["it"],
            supportedLocales: { list }, supportedLocale: applePick)
        #expect(resolved.identifier == "it_IT")
        let asked = try await AppleLocaleInstaller.resolve(
            requested: "it-CH", moduleName: "DictationTranscriber", languages: ["it"],
            supportedLocales: { list }, supportedLocale: applePick)
        #expect(asked.identifier == "it_CH")
        let supported = await AppleLocaleInstaller.supports(
            "it", supportedLocales: { list }, supportedLocale: applePick)
        #expect(supported?.identifier == "it_IT")
        let arabic = await AppleLocaleInstaller.supports(
            "ar", supportedLocales: { list }, supportedLocale: applePick)
        #expect(arabic?.identifier == "ar_SA")
    }

    // Apple lists four Spanish locales and answers "es-419" with an arbitrary
    // one of them, redrawn on each process launch. The draw is worth 6.5 WER
    // points, so Spanish is pinned rather than left to chance.
    let spanish = ["es_CL", "es_ES", "es_MX", "es_US", "it_IT", "pt_BR"]
        .map(Locale.init(identifier:))

    @Test("a bare es and es-419 pin to es_MX, a named region is taken as asked")
    func spanishPin() {
        #expect(AppleSpeech.pinned("es", in: spanish)?.identifier == "es_MX")
        #expect(AppleSpeech.pinned("es-419", in: spanish)?.identifier == "es_MX")
        #expect(AppleSpeech.pinned("es_419", in: spanish)?.identifier == "es_MX")
        #expect(AppleSpeech.pinned("es-ES", in: spanish) == nil)
        #expect(AppleSpeech.pinned("es-CL", in: spanish) == nil)
        #expect(AppleSpeech.pinned("it", in: spanish) == nil)
    }

    @Test("the pin yields to a module that does not have es_MX")
    func spanishPinNeedsTheLocale() {
        let withoutMexico = ["es_ES", "es_US"].map(Locale.init(identifier:))
        #expect(AppleSpeech.pinned("es-419", in: withoutMexico) == nil)
    }

    @Test("resolve and install-locale both take the pin, whatever Apple answers")
    func spanishResolves() async throws {
        guard #available(macOS 26, *) else { return }
        let list = spanish
        // Apple's lookup at its worst: a different Spanish locale every call.
        var draws = ["es_US", "es_CL", "es_ES", "es_MX"].makeIterator()
        let applePick: (Locale) async -> Locale? = { locale in
            guard Locale.Language(identifier: locale.identifier).languageCode?.identifier == "es" else {
                return nil
            }
            return Locale(identifier: draws.next() ?? "es_CL")
        }
        for tag in ["es", "es-419"] {
            let resolved = try await AppleLocaleInstaller.resolve(
                requested: tag, moduleName: "DictationTranscriber", languages: ["es"],
                supportedLocales: { list }, supportedLocale: applePick)
            #expect(resolved.identifier == "es_MX")
            let installed = await AppleLocaleInstaller.supports(
                tag, supportedLocales: { list }, supportedLocale: applePick)
            #expect(installed?.identifier == "es_MX")
        }
        // A named region Apple ships is still taken as asked.
        let spain = try await AppleLocaleInstaller.resolve(
            requested: "es-ES", moduleName: "DictationTranscriber", languages: ["es"],
            supportedLocales: { list }, supportedLocale: { _ in Locale(identifier: "es_ES") })
        #expect(spain.identifier == "es_ES")
    }
}
