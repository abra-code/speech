// Environment.swift - what produced a given answer.
//
// Several things this tool reports are not properties of a model but of the
// software that asked it. A row's languages, its capability flags and its macOS
// floor are read out of a GGUF or a CoreML bundle by a particular engine
// version running on a particular OS, and stage 2 already found four cases
// where the answer differed from the published one. A download size is the size
// of one revision of one repository, and these repositories are requantized in
// place - which is exactly why the download client pins a resume to an LFS
// object id.
//
// So anything this program emits that a person might compare against a later
// run carries the environment that produced it. Without it, a table of
// capabilities from two builds looks like a table of contradictions.

import Foundation
import SpeechCore
import TranscribeCpp

enum SpeechEnvironment {
    /// FluidAudio has no runtime version to ask for, so this is the pin from
    /// Package.swift. `packagePinMatchesLiteral` in the test suite parses the
    /// manifest and fails if the two drift, because a stale version string is
    /// worse than none: it is a claim about which library produced a number.
    static let fluidAudioVersion = "0.15.6"

    /// transcribe.cpp does report itself, so it is asked rather than pinned.
    static var transcribeCppVersion: String { Transcribe.version() }

    /// Ordered because it is written into a file that gets diffed.
    static func facts() -> [(key: String, value: String)] {
        [
            ("tool", kVersion),
            ("machine", SystemInfo.chip),
            ("macos", SystemInfo.operatingSystemVersion),
            ("apple-speech", "bundled with macOS \(SystemInfo.operatingSystemVersion)"),
            ("fluidaudio", fluidAudioVersion),
            ("transcribe.cpp", transcribeCppVersion),
        ]
    }

    static func json() -> [String: Any] {
        var out: [String: Any] = [:]
        for fact in facts() { out[fact.key] = fact.value }
        return out
    }
}
