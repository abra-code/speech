// LocaleReleasedWarningTests.swift - a locale given up to make room for
// another reaches the reader as a warning, not as a progress step it would
// show and forget.

import Foundation
import Testing

@testable import SpeechCore

@Suite("Released locale warning")
struct LocaleReleasedWarningTests {
    @Test("a released locale becomes a locale_released warning naming both languages")
    func releasedLocaleIsAWarning() throws {
        let directory = try Fixtures.makeDirectory()
        defer { Fixtures.cleanUp(directory) }
        // Through a file, because the sink writes rather than calls back.
        let log = directory.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let sink = EventSink(mode: .jsonl, out: handle, err: handle)
        sink.modelProgress(
            model: "apple.dictation",
            LoadProgress(phase: .listing, file: "it_IT", releasedLocale: "de_DE"))
        sink.modelProgress(model: "apple.dictation", LoadProgress(phase: .listing, file: "it_IT"))
        try handle.close()

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(lines.count == 2)
        let warning = lines.first { $0["type"] as? String == "warning" }
        #expect(warning?["code"] as? String == "locale_released")
        let message = warning?["message"] as? String ?? ""
        #expect(message.contains("de_DE") && message.contains("it_IT"))
        // The ordinary step is still progress, and the release is not also sent as one.
        #expect(lines.filter { $0["type"] as? String == "model.progress" }.count == 1)
    }
}
