// LanguageRegionTests.swift - a language with no region lands on its main
// region, never on whichever variant a list happens to name first.

import Foundation
import Testing

@testable import SpeechCore

@Suite("Language regions")
struct LanguageRegionTests {
    @Test("the region a tag names, in either spelling")
    func region() {
        #expect(Language.region("pt-BR") == "BR")
        #expect(Language.region("it_it") == "IT")
        #expect(Language.region("zh-Hant-TW") == "TW")
        #expect(Language.region("es-419") == "419")
        #expect(Language.region("pt") == nil)
        #expect(Language.region("zh-Hant") == nil)
    }

    @Test("a bare language's main region comes from likely subtags")
    func mainRegion() {
        #expect(Language.mainRegion("it") == "IT")
        #expect(Language.mainRegion("nl") == "NL")
        #expect(Language.mainRegion("es") == "ES")
        #expect(Language.mainRegion("pt") == "BR")
        #expect(Language.mainRegion("zh") == "CN")
        #expect(Language.mainRegion("zh-Hant") == "TW")
        // A tag that names a region is taken as asked.
        #expect(Language.mainRegion("it-CH") == nil)
        #expect(Language.mainRegion("es-419") == nil)
    }

    @Test("a bare language matches its main-region variant wherever the list puts it")
    func matchPrefersMainRegion() {
        #expect(Language.match("es", in: ["en-US", "es-US", "es-ES"]) == "es-ES")
        #expect(Language.match("it", in: ["it-CH", "it-IT"]) == "it-IT")
        #expect(Language.match("pt", in: ["pt-PT", "pt-BR"]) == "pt-BR")
        // An explicit region still finds itself, and a bare entry still wins.
        #expect(Language.match("es-US", in: ["es-ES", "es-US"]) == "es-US")
        #expect(Language.match("pl", in: ["pl-PL", "pl"]) == "pl")
        // No main-region variant: the first variant, rather than a refusal.
        #expect(Language.match("ar", in: ["ar-SA", "ar-AR"]) == "ar-SA")
        #expect(Language.match("de", in: ["en", "fr"]) == nil)
    }
}
