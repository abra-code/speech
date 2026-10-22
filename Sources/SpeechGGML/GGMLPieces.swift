// GGMLPieces.swift - how much audio one transcribe.cpp run is given.
//
// A model file declares `max_audio_ms`, and until 2026-09-17 that was the only
// reason this engine cut a file. It is an input bound and nothing more, and it
// is far too loose to transcribe with. Measured on a 36-minute talk on an M5
// with 24 GB (Private/ggml-pieces-2026-09-17):
//
// - **Families whose decoder writes text token by token stop at a generation
//   budget of 256 tokens per run** (`k_max_new` in transcribe.cpp's qwen3_asr,
//   canary_qwen, moss and funasr_nano; granite and cohere log the same
//   truncation). That is about a minute of speech. Qwen3-ASR declares 87
//   minutes and refused 5; Granite 4.0 and Canary refused 5 as well. Granite
//   Speech NAR has a 4096-token context instead, which 5 minutes overfills.
// - **Encoder families grow their compute graph with the square of the audio.**
//   Parakeet, Parakeet Unified and Nemotron finished 10 minutes but asked Metal
//   for a 13.7 GB buffer at 20. The ggml in transcribe.cpp 0.2.3 did not
//   survive that failed allocation - the process crashed with SIGSEGV rather
//   than returning an error - which this repository patched until 0.4.0, whose
//   newer ggml carries both fixes. Now the run returns an out-of-memory error,
//   so the retry below can act on it instead of the process disappearing. The
//   piece lengths still matter: a refusal that costs a retry is worse than a
//   length that never asks.
// - **Whisper windows its own input at 30 seconds** and ran 20 minutes in 1.3 GB
//   at 21x, so it is given the file whole.
//
// Staying under those limits is not enough: every family also transcribes long
// pieces worse, dropping whole sentences. The lengths below are the best of
// 10, 15, 20, 30 and 45 seconds (60, 120 and 300 for Parakeet) on four 5-minute
// recordings each of English and Polish, joined from unique FLEURS sentences,
// WER against the same sentences transcribed one at a time:
//
//   Qwen3-ASR 1.7B  en 11.3% at 10 s (4.2% by sentence), pl 17.0% (13.9%)
//   Canary 1B v2    en 11.4% at 30 s (5.0%), pl 8.7% (8.2%)
//   Granite 4.0 1B  en 7.7% at 15 s (7.4%)
//   Granite NAR     en 14.9% at 15 s (5.9%)
//   Parakeet v3     en 9.0% at 30 s (5.0%), pl 8.9% (8.4%); 24.7% and 11.1% at
//                   60 s, 46.6% and 14.4% at 300 s, and fastest at 30 s (76x)
//
// A new speaker every sentence makes that corpus harsher than a talk: the
// 36-minute recording came out at about the same word count from Qwen3-ASR and
// Parakeet. The differences between lengths are what these numbers are for.
//
// An architecture not listed gets the text-decoder default: a decoder that
// writes text is the common shape among new speech models, and a piece too
// short costs a little accuracy where a piece too long costs the transcript. A
// piece that is refused anyway is cut again (GGMLEngine.transcribePiece).
//
// Those lengths are for long recordings. **Audio up to `wholeSeconds` is given
// whole** whatever the family's length, because cutting one utterance is what
// costs accuracy: from 2026-09-17 to 2026-10-22 a FLEURS clip of 10.9 s went
// to Qwen3-ASR as 10 s plus 0.9 s, the first piece ended in a full stop
// mid-sentence and the second came back as "Okay." On FLEURS English that put
// Qwen3-ASR 1.7B at 5.46% WER against 3.74% when it was measured whole, and on
// 50 of its rows every clip over 10 s came out different from transcribe.cpp's
// own CLI, which does not cut. 50 s is past the longest utterance in FLEURS
// (German, 47.9 s) and in LibriSpeech (35 s), and its English text - over a
// hundred tokens - fits the 256 that every run of these families is allowed;
// Mandarin is denser and may not, and a piece refused for that is still cut
// and retried. A model that declares a shorter limit gets that limit and no
// shorter one: the fewest cuts it accepts.

import Foundation

enum GGMLPieces {
    /// Audio this long or shorter is one utterance, cut only where the model's
    /// declared limit forces it; see above.
    static let wholeSeconds: Double = 50

    /// For a family whose decoder writes text, when it has no measured length.
    static let textDecoderSeconds: Double = 15

    /// For an encoder family, whose memory grows with the square of the piece.
    static let encoderSeconds: Double = 30

    /// Measured per architecture; see the table above.
    static let measuredSeconds: [String: Double] = [
        "qwen3_asr": 10,
        "canary": 30,
        "granite_speech": 15,
        "granite_speech_nar": 15,
        "parakeet": 30,
    ]

    /// Architectures that transcribe a file of any length in bounded memory on
    /// their own.
    static let selfWindowing: Set<String> = ["whisper"]

    /// Architectures without an autoregressive text decoder.
    static let encoders: Set<String> = ["parakeet", "gigaam", "medasr", "sensevoice", "moonshine"]

    /// `SPEECH_GGML_PIECE_SECONDS`, for measuring: a positive number replaces
    /// every family's length (whisper's windowing excepted), so a sweep like
    /// the one above can run one build at several lengths. The whole-utterance
    /// rule and a model's declared limit still apply. Unset in normal use;
    /// anything but a finite number of at least a second is ignored, so a typo
    /// cannot turn a recording into a million one-sample runs.
    static let overrideVariable = "SPEECH_GGML_PIECE_SECONDS"

    static func overrideSeconds(_ environment: [String: String]) -> Double? {
        guard let raw = environment[overrideVariable], let seconds = Double(raw),
              seconds.isFinite, seconds >= 1 else { return nil }
        return seconds
    }

    /// The longest audio, in seconds, one run of `architecture` is given; nil
    /// when the architecture needs no ceiling of this engine's.
    static func practicalMaxSeconds(
        architecture: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double? {
        if selfWindowing.contains(architecture) { return nil }
        if let override = overrideSeconds(environment) { return override }
        if let measured = measuredSeconds[architecture] { return measured }
        if encoders.contains(architecture) { return encoderSeconds }
        return textDecoderSeconds
    }

    /// The ceiling a run is cut to: the smaller of the model's declared one and
    /// this engine's, where 0 or less in `declaredMs` means the model declares
    /// none. `.infinity` when neither applies.
    static func ceilingSeconds(architecture: String, declaredMs: Int64) -> Double {
        let declared = declaredMs > 0 ? Double(declaredMs) / 1000 : .infinity
        guard let practical = practicalMaxSeconds(architecture: architecture) else { return declared }
        return min(declared, practical)
    }

    /// The ceiling for `audioSeconds` of audio: the declared limit alone when
    /// the audio is no longer than `wholeSeconds`, so that it arrives in one
    /// run or in as few as the model accepts, and `ceilingSeconds` otherwise.
    static func ceilingSeconds(architecture: String, declaredMs: Int64, audioSeconds: Double) -> Double {
        if audioSeconds <= wholeSeconds { return declaredMs > 0 ? Double(declaredMs) / 1000 : .infinity }
        return ceilingSeconds(architecture: architecture, declaredMs: declaredMs)
    }
}
