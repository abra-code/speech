// GGMLPiecesTests.swift - how long one transcribe.cpp run may be. A wrong answer here does not fail
// quietly: a piece too long for a family crashes the process or truncates the transcript, which is
// what a 36-minute talk did before the ceilings existed.

import Foundation
import Testing

@testable import SpeechGGML

@Suite("ggml run length")
struct GGMLPiecesTests {
    @Test("a family that writes text gets its measured length, not its declared one")
    func textDecoders() {
        // Qwen3-ASR declares 5,218,560 ms and refused five minutes.
        #expect(GGMLPieces.ceilingSeconds(architecture: "qwen3_asr", declaredMs: 5_218_560) == 10)
        // Canary declares 400 s.
        #expect(GGMLPieces.ceilingSeconds(architecture: "canary", declaredMs: 400_000) == 30)
        #expect(GGMLPieces.ceilingSeconds(architecture: "granite_speech_nar", declaredMs: 0) == 15)
        // A text family with no measurement of its own.
        #expect(GGMLPieces.ceilingSeconds(architecture: "moss", declaredMs: 0) == GGMLPieces.textDecoderSeconds)
    }

    @Test("every measured length is shorter than a minute, the generation budget's reach")
    func measuredAreShort() {
        for (architecture, seconds) in GGMLPieces.measuredSeconds {
            #expect(seconds > 0 && seconds < 60, "\(architecture): \(seconds)")
        }
    }

    @Test("a refusal for length is retried in shorter pieces, any other is not")
    func retriable() {
        #expect(GGMLEngine.isRetriableWithShorterPieces(.outputTruncated(message: "x", partial: nil)))
        #expect(GGMLEngine.isRetriableWithShorterPieces(.inputTooLong("x")))
        #expect(GGMLEngine.isRetriableWithShorterPieces(.outOfMemory("x")))
        #expect(!GGMLEngine.isRetriableWithShorterPieces(.modelLoad("x")))
        #expect(!GGMLEngine.isRetriableWithShorterPieces(.aborted(message: "x", partial: nil)))
    }

    @Test("a failed piece's place is written the way a player shows it")
    func clock() {
        #expect(GGMLEngine.clock(0) == "0:00")
        #expect(GGMLEngine.clock(245.7) == "4:05")
        #expect(GGMLEngine.clock(3727) == "1:02:07")
    }

    @Test("a declared ceiling shorter than the engine's still wins")
    func declaredWins() {
        #expect(GGMLPieces.ceilingSeconds(architecture: "qwen3_asr", declaredMs: 5_000) == 5)
        #expect(GGMLPieces.ceilingSeconds(architecture: "parakeet", declaredMs: 20_000) == 20)
    }

    @Test("an encoder family gets the encoder ceiling even when it declares no limit")
    func encoders() {
        // Parakeet declares none and crashed at 20 minutes.
        #expect(GGMLPieces.ceilingSeconds(architecture: "parakeet", declaredMs: 0) == 30)
        #expect(GGMLPieces.ceilingSeconds(architecture: "gigaam", declaredMs: 0) == GGMLPieces.encoderSeconds)
    }

    @Test("whisper windows itself and is given the file whole")
    func whisper() {
        #expect(GGMLPieces.ceilingSeconds(architecture: "whisper", declaredMs: 0) == .infinity)
        #expect(GGMLPieces.practicalMaxSeconds(architecture: "whisper") == nil)
    }

    @Test("an architecture this engine does not know gets the short ceiling, and so does a model that names none")
    func unknown() {
        #expect(GGMLPieces.ceilingSeconds(architecture: "some_new_family", declaredMs: 0) == GGMLPieces.textDecoderSeconds)
        #expect(GGMLPieces.ceilingSeconds(architecture: "", declaredMs: 0) == GGMLPieces.textDecoderSeconds)
    }
}
