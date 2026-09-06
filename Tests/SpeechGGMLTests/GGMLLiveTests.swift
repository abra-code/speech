// GGMLLiveTests.swift - the part of ggml live mode that can be tested without
// a microphone or a two-gigabyte download.
//
// The streaming decoder itself is not testable here: it needs weights, real
// audio and about ten seconds per case, and what it produces is transcribe.cpp's
// business. The mapping from its growing committed string to segments is shared
// with the fluid streaming rows and is tested in SpeechCoreTests; what is left
// here is which rows claim a streaming decoder at all.

import Foundation
import Testing

@testable import SpeechCore
@testable import SpeechGGML

@Suite("ggml streaming rows")
struct GGMLStreamingRowTests {
    /// Measured 2026-09-05 by loading every installed GGUF and reading
    /// `Model.capabilities.supportsStreaming`. Pinned as a set rather than
    /// spot-checked so that adding a row forces a decision about it.
    static let streamingModels: Set<String> = [
        "parakeet-unified-en-0.6b",
        "nemotron-3.5-asr-streaming-0.6b",
    ]

    @Test("exactly the measured rows claim a streaming decoder")
    func streamingSet() {
        let claimed = Set(GGMLCatalog.rows.filter(\.streaming).map(\.model))
        #expect(claimed == Self.streamingModels)
    }

    @Test("the fast multilingual row is not one of them")
    func parakeetV3IsNotLive() throws {
        // Worth its own assertion because it is the row a reader would assume
        // streams: it is the fast one, it is multilingual, and its CoreML twin
        // has a sliding-window live mode. On this engine it does not stream, so
        // ggml live mode means either an English-only model or the row that
        // lost to Apple in all three languages in spike 2.
        let row = try #require(GGMLCatalog.row(model: "parakeet-tdt-0.6b-v3"))
        #expect(row.streaming == false)
    }

    /// Narrow on purpose: this checks the wiring, not the truth. Whether the
    /// row's flag matches the weights can only be settled by loading them, and
    /// `makeLiveSession` is where that check lives. What this catches is the
    /// flag being hardcoded again, which is what it replaced.
    @Test("the capability record carries the row's answer")
    func capabilitiesFollowTheRow() {
        for (model, variant) in GGMLEngineFactory.catalogRows {
            guard let row = GGMLCatalog.row(model: model),
                  let capabilities = GGMLEngineFactory.capabilities(for: model, variant: variant)
            else {
                Issue.record("no capabilities for \(model)")
                continue
            }
            #expect(
                capabilities.live == row.streaming,
                "\(model)@\(variant ?? "-") reports live=\(capabilities.live)")
        }
    }
}
