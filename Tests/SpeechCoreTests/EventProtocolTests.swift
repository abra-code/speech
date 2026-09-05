// EventProtocolTests.swift - the JSONL wire format.
//
// Two properties are pinned here because breaking either one silently breaks
// the applet: every event kind round-trips through Codable, and the payload
// fields sit flat next to `type` and `t` rather than nested. A reader written
// against docs/protocol.md gets what that document promises.

import Foundation
import Testing
@testable import SpeechCore

@Suite("Event protocol")
struct EventProtocolTests {
    private func roundTrip(_ payload: SpeechEvent.Payload) throws -> [String: Any] {
        let event = SpeechEvent(t: 1.25, payload: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(event)

        let decoded = try JSONDecoder().decode(SpeechEvent.self, from: data)
        #expect(decoded.t == 1.25)
        #expect(decoded.payload == payload)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("event did not encode as a JSON object")
            return [:]
        }
        #expect(object["type"] as? String == payload.type)
        #expect(object["t"] as? Double == 1.25)
        return object
    }

    private var sampleSegment: Segment {
        Segment(
            id: 3, start: 1, end: 2.5, text: "hello there",
            words: [Word(text: "hello", start: 1, end: 1.4, confidence: 0.9),
                    Word(text: "there", start: 1.4, end: 2.5)],
            confidence: 0.87, speaker: 2, language: "en")
    }

    @Test("every event kind round-trips")
    func allKinds() throws {
        let capabilities = EngineCapabilities(
            batch: true, live: true, wordTimestamps: true, segmentTimestamps: true,
            vocabulary: true, diarization: false, languageID: true, languageHint: true,
            languages: ["en", "pl"], minimumMacOS: "15.0")

        _ = try roundTrip(.engineReady(.init(
            engine: "apple.transcriber", model: "apple.transcriber",
            capabilities: capabilities, loadSeconds: 0.5)))
        _ = try roundTrip(.modelProgress(.init(
            model: "fluid.parakeet-v3@int8",
            progress: LoadProgress(
                phase: .downloading, fraction: 0.5,
                bytesDone: 100, bytesTotal: 200, file: "Encoder.mlmodelc"))))
        _ = try roundTrip(.modelInstalled(.init(
            model: "fluid.parakeet-v3@int8", path: "/tmp/models", bytes: 740_000_000)))
        // Apple's locale assets have neither; both fields drop out of the line.
        let systemInstall = try roundTrip(.modelInstalled(.init(model: "apple.dictation@pl_PL")))
        #expect(systemInstall["path"] == nil)
        #expect(systemInstall["bytes"] == nil)
        let installedRow = try roundTrip(.modelEntry(.init(
            model: "fluid.parakeet-v3@int8", state: .installed,
            path: "/tmp/models/fluid/parakeet-v3@int8", bytes: 483_000_000)))
        // The wire spelling is snake_case like every other multi-word value in
        // this protocol. An applet switches on this string.
        #expect(installedRow["state"] as? String == "installed")

        let systemRow = try roundTrip(.modelEntry(.init(
            model: "apple.transcriber", state: .systemManaged)))
        #expect(systemRow["state"] as? String == "system_managed")
        #expect(systemRow["path"] == nil)
        #expect(systemRow["bytes"] == nil)

        // A row that is not usable but is still occupying disk. `bytes` present
        // with `state` missing is the whole point: it is how a failed download
        // stops being invisible.
        let brokenRow = try roundTrip(.modelEntry(.init(
            model: "fluid.parakeet-v3@int4", state: .missing,
            path: "/tmp/models/fluid/parakeet-v3@int4", bytes: 3000)))
        #expect(brokenRow["state"] as? String == "missing")
        #expect(brokenRow["bytes"] as? Int == 3000)

        _ = try roundTrip(.modelEntry(.init(model: "fluid.canary-1b-v2@int4", state: .partial)))
        // A row this build cannot judge. It must not be reported as installed:
        // an applet reading models list --json would offer it for transcription,
        // which then exits 2.
        let unknownRow = try roundTrip(.modelEntry(.init(
            model: "fluid.parakeet-v3@int8-v2", state: .unknown,
            path: "/tmp/models/fluid/parakeet-v3@int8-v2", bytes: 2_100_000)))
        #expect(unknownRow["state"] as? String == "unknown")
        _ = try roundTrip(.progress(.init(audioSecondsDone: 5, audioSecondsTotal: 20)))
        _ = try roundTrip(.segmentPartial(sampleSegment))
        _ = try roundTrip(.segmentFinal(sampleSegment))
        _ = try roundTrip(.segmentRefined(.init(segment: sampleSegment, refinedBy: "fluid.canary-1b-v2@int4")))
        _ = try roundTrip(.warning(.init(message: "no vocabulary support", code: "vocabulary_unsupported")))
        _ = try roundTrip(.error(.init(SpeechError.modelMissing("fluid.parakeet-v3@int8"))))
        _ = try roundTrip(.done(.init(
            segments: 2, audioSeconds: 10, wallSeconds: 1,
            peakRSSBytes: 1024, peakMemoryBytes: 4096, output: "/tmp/out.srt")))
        _ = try roundTrip(.evalRow(.init(
            index: 1, path: "/tmp/a.wav", reference: "a b", hypothesis: "a c",
            wer: 0.5, cer: 0.25, audioSeconds: 1, wallSeconds: 0.1)))
        _ = try roundTrip(.evalSummary(.init(
            model: "apple.dictation", language: "pl", rows: 2, wer: 0.1, cer: 0.05,
            audioSeconds: 20, wallSeconds: 2, peakRSSBytes: 2048, peakMemoryBytes: 8192,
            worst: [.init(index: 1, wer: 0.5, reference: "a b", hypothesis: "a c")])))
    }

    @Test("segment fields are flat, not nested under a payload key")
    func segmentsAreFlat() throws {
        let object = try roundTrip(.segmentFinal(sampleSegment))
        #expect(object["id"] as? Int == 3)
        #expect(object["text"] as? String == "hello there")
        #expect(object["speaker"] as? Int == 2)
        #expect((object["words"] as? [Any])?.count == 2)
    }

    @Test("a refined segment carries the segment's own fields plus refined_by")
    func refinedIsASegment() throws {
        let object = try roundTrip(.segmentRefined(
            .init(segment: sampleSegment, refinedBy: "ggml.qwen3-asr-1.7b@q8_0")))
        #expect(object["id"] as? Int == 3)
        #expect(object["refined_by"] as? String == "ggml.qwen3-asr-1.7b@q8_0")
    }

    @Test("optional segment fields are omitted rather than encoded as null")
    func optionalsAreOmitted() throws {
        let bare = Segment(id: 0, start: 0, end: 1, text: "x")
        let object = try roundTrip(.segmentFinal(bare))
        #expect(object["words"] == nil)
        #expect(object["speaker"] == nil)
        #expect(object["confidence"] == nil)
    }

    @Test("rtfx is derived, not trusted from the caller")
    func derivedRates() {
        let done = SpeechEvent.DoneEvent(
            segments: 1, audioSeconds: 60, wallSeconds: 2, peakRSSBytes: 0, peakMemoryBytes: 0)
        #expect(done.rtfx == 30)
        let stalled = SpeechEvent.DoneEvent(
            segments: 0, audioSeconds: 60, wallSeconds: 0, peakRSSBytes: 0, peakMemoryBytes: 0)
        #expect(stalled.rtfx == 0)
    }

    @Test("an unknown type is a decoding error, not a silent drop")
    func unknownType() {
        let data = Data(#"{"type":"segment.telepathic","t":1}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SpeechEvent.self, from: data)
        }
    }
}
