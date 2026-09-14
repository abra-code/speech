// AppleAvailabilityTests.swift - which Apple engine may run where. The system
// answers (the macOS version, SpeechTranscriber.isAvailable) are yes on the Mac
// that runs this suite, so the rule is tested apart from them.

import Foundation
import Testing

@testable import SpeechApple

@Suite("Apple engine availability")
struct AppleAvailabilityTests {
    @Test("both engines run where macOS 26 has the long-form model")
    func bothAvailable() {
        for kind in [AppleEngineKind.transcriber, .dictation] {
            #expect(AppleSpeech.decide(kind, osVersion: "26.6.2", osSupported: true, longFormAvailable: true) == .available)
        }
    }

    @Test("dictation stays available where the long-form model is not")
    func dictationIsTheFallback() {
        #expect(AppleSpeech.decide(.dictation, osVersion: "26.6.2", osSupported: true, longFormAvailable: false) == .available)
        let transcriber = AppleSpeech.decide(.transcriber, osVersion: "26.6.2", osSupported: true, longFormAvailable: false)
        guard case .notAvailable(let reason) = transcriber else {
            Issue.record("expected notAvailable, got \(transcriber)")
            return
        }
        #expect(reason.contains("apple.dictation"))
        #expect(!reason.contains("Settings"))
    }

    @Test("an older macOS rules out both, naming the version it runs")
    func osTooOld() {
        for kind in [AppleEngineKind.transcriber, .dictation] {
            let answer = AppleSpeech.decide(kind, osVersion: "15.5.0", osSupported: false, longFormAvailable: false)
            guard case .osTooOld(let reason) = answer else {
                Issue.record("expected osTooOld for \(kind), got \(answer)")
                continue
            }
            #expect(reason.contains("macOS 26"))
            #expect(reason.contains("15.5.0"))
        }
    }
}
