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

import TranscribeCpp

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

@Suite("ggml committed-text workaround")
struct GGMLCommittedTextWorkaroundTests {
    @Test("only the parakeet cache-aware stream commits its tentative text")
    func scopedToParakeetStream() {
        // The transcribe.cpp v0.2.3 defect is in that family's commit boundary.
        // Widening this to the buffered kind or to a family that has never been
        // measured would be trusting tentative text nobody checked.
        #expect(GGMLLiveSession.commitsTentative(for: .parakeetStream(ParakeetStreamOptions())))
        #expect(!GGMLLiveSession.commitsTentative(for: .parakeetBuffered(ParakeetBufferedStreamOptions())))
        #expect(!GGMLLiveSession.commitsTentative(for: nil))
    }

    @Test("a frozen commit still reaches the accumulator as committed text")
    func frozenCommitIsRead() {
        // The measured shape: `committed` stops growing and the rest of the
        // speech sits in `tentative` until finalize.
        let view = GGMLLiveSession.committedView(
            committed: "We want you to help us publish",
            tentative: " some leading articles. Will you do it?",
            commitsTentative: true)
        #expect(view.committed == "We want you to help us publish some leading articles. Will you do it?")
        #expect(view.tentative.isEmpty)
    }

    @Test("a stream without the workaround passes the split through")
    func passThrough() {
        let view = GGMLLiveSession.committedView(
            committed: "one two", tentative: " three", commitsTentative: false)
        #expect(view.committed == "one two")
        #expect(view.tentative == " three")
    }

    @Test("with the workaround, a sentence closes before the stream ends")
    func finalsArriveMidStream() {
        // End to end through the real accumulator: before the workaround the
        // first final after the freeze came only at finalize.
        var accumulator = StreamSegmentAccumulator()
        var finals: [SpeechCore.Segment] = []
        let feeds: [(String, String, Double)] = [
            ("We want you", "", 2),
            ("We want you", " to help us.", 4),
            ("We want you", " to help us. Will you do it? Yes", 6),
        ]
        for (committed, tentative, seconds) in feeds {
            let view = GGMLLiveSession.committedView(
                committed: committed, tentative: tentative, commitsTentative: true)
            let events = accumulator.absorb(
                committed: view.committed, tentative: view.tentative,
                committedMs: Int64(seconds * 1000), receivedMs: Int64(seconds * 1000),
                isFinal: false)
            for event in events {
                if case .final(let segment) = event { finals.append(segment) }
            }
        }
        #expect(finals.map(\.text) == ["We want you to help us.", "Will you do it?"])
    }

    @Test("the finalize step, where committed becomes the full text, adds nothing twice")
    func finalizeSeam() {
        // At finalize the library appends the whole frozen suffix to
        // `committed` and empties `tentative`, so the view's committed string
        // is the same text as the feed before it plus whatever the flush
        // decoded. The scalar watermark must see only that growth: a
        // duplicated or dropped word here would land in the last final of
        // every live run on this row.
        var accumulator = StreamSegmentAccumulator()
        var finals: [SpeechCore.Segment] = []
        let feeds: [(String, String, Double, Bool)] = [
            ("We want you", "", 2, false),
            ("We want you", " to help us publish", 4, false),
            ("We want you", " to help us publish some articles. Will you", 6, false),
            ("We want you to help us publish some articles. Will you do it?", "", 8, true),
        ]
        for (committed, tentative, seconds, isFinal) in feeds {
            let view = GGMLLiveSession.committedView(
                committed: committed, tentative: tentative, commitsTentative: true)
            let events = accumulator.absorb(
                committed: view.committed, tentative: view.tentative,
                committedMs: Int64(seconds * 1000), receivedMs: Int64(seconds * 1000),
                isFinal: isFinal)
            for event in events {
                if case .final(let segment) = event { finals.append(segment) }
            }
        }
        #expect(finals.map(\.text) == [
            "We want you to help us publish some articles.", "Will you do it?",
        ])
        #expect(finals.map(\.text).joined(separator: " ") == feeds[3].0)
    }
}
