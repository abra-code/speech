// ModelSession.swift - one loaded model, and the eight ways to get one.
//
// Every entry point here reads a directory this process was handed and touches
// no network. That is a contract, not a convenience: `speech` owns downloads,
// and a helper that could fetch would mean two download paths, two definitions
// of "installed" and a model store whose contents nobody could account for.
//
// One of them writes, and it is worth knowing before the store is wired up:
// `Qwen3ASRModel.fromModelDirectory` synthesizes a `tokenizer.json` from
// vocab.json and merges.txt when the repository ships none, which per the
// library's own comment is the normal case for these checkpoints, and writes it
// into the directory it was handed. So a `qwen3_asr` row grows a file after it
// was installed. Whatever completeness check `speech` uses for these rows has
// to expect that, and a read-only store would fail the load outright.
//
// MLX Audio offers a second route - `STT.loadModel(modelRepo:)` - which takes a
// Hugging Face repository id and resolves it through a cache. It is not used,
// and pointing that cache at our own store would be worse than not using it:
// `ModelUtils.resolveOrDownloadModel` deletes the directory it was asked to
// read when it judges the contents incomplete, and then downloads. Aimed at the
// model store that would be `speech models download` losing a user's weights to
// a validation rule written elsewhere.
//
// Which types are reachable this way was read from mlx-audio-swift v0.1.3
// rather than from its documentation: seven have a public `fromDirectory`, and
// Qwen3-ASR has `fromModelDirectory` under a different name.

import Foundation
import MLX
import MLXAudioSTT
import SpeechMLXProtocol

enum ModelSessionError: Error, CustomStringConvertible {
    case noConfig(String)
    case unknownType(String)
    case missingTokenizer(String)
    case notLoaded

    var description: String {
        switch self {
        case .noConfig(let path):
            return "no readable config.json in \(path)"
        case .unknownType(let type):
            return "this build has no loader for model type '\(type)'"
                + " (has: \(ModelSession.implementedTypes.joined(separator: ", ")))"
        case .missingTokenizer(let path):
            return "\(path) has no tokenizer.json, and this helper does not download one;"
                + " install the row again so the tokenizer files come with the weights"
        case .notLoaded:
            return "no model is loaded"
        }
    }
}

/// Holds at most one model. One at a time is the whole design: a second loaded
/// model would double the memory a measurement is trying to report, and
/// `speech` runs one row at a time for exactly that reason.
final class ModelSession {
    /// Model types this build can construct, spelled as `config.json` spells
    /// them. Not a capability table - what a checkpoint can do is reported by
    /// `loaded`, after the weights are read.
    static let implementedTypes = [
        "cohere_asr", "fireredasr2", "nemotron_asr", "parakeet",
        "qwen3_asr", "sensevoice", "voxtral_realtime", "whisper",
    ]

    /// Types whose `generate` reads the language parameter. A property of this
    /// library's implementation, which is a fact the helper owns rather than
    /// something either side has to guess from a model card.
    private static let takesLanguageHint: Set<String> = [
        "cohere_asr", "qwen3_asr", "voxtral_realtime", "whisper",
    ]

    private var model: (any STTGenerationModel)?
    private(set) var type: String?
    private(set) var language: String?

    func unload() {
        model = nil
        type = nil
        language = nil
        // MLX holds freed blocks in its own pool, so dropping the last
        // reference is not the same as giving the memory back. A measurement
        // taken after this call would otherwise report the previous model's
        // high-water mark.
        MLX.Memory.clearCache()
    }

    func load(_ request: MLXRequest.Load) async throws -> MLXResponse.Loaded {
        unload()
        let directory = URL(fileURLWithPath: request.directory, isDirectory: true)
        let config = try Self.readConfig(in: directory)
        let resolved = Self.normalize(request.type) ?? Self.type(from: config, at: directory)
        guard let resolved, Self.implementedTypes.contains(resolved) else {
            throw ModelSessionError.unknownType(resolved ?? "unknown")
        }

        let started = Date()
        let loaded: any STTGenerationModel
        switch resolved {
        case "parakeet":
            loaded = try ParakeetModel.fromDirectory(directory)
        case "nemotron_asr":
            loaded = try NemotronASRModel.fromDirectory(directory)
        case "qwen3_asr":
            loaded = try await Qwen3ASRModel.fromModelDirectory(directory)
        case "whisper":
            // `WhisperModel.fromDirectory` fetches tokenizer assets from a
            // sibling openai/whisper-* repository when the directory has none,
            // which is the mlx-community layout. Refusing is the honest answer
            // for a process that promises not to reach the network: the fix is
            // in the install, not here.
            let tokenizer = directory.appendingPathComponent("tokenizer.json")
            guard FileManager.default.fileExists(atPath: tokenizer.path) else {
                throw ModelSessionError.missingTokenizer(directory.path)
            }
            loaded = try await WhisperModel.fromDirectory(directory)
        case "sensevoice":
            loaded = try SenseVoiceModel.fromDirectory(directory)
        case "fireredasr2":
            loaded = try FireRedASR2Model.fromDirectory(directory)
        case "cohere_asr":
            loaded = try CohereTranscribeModel.fromDirectory(directory)
        case "voxtral_realtime":
            loaded = try VoxtralRealtimeModel.fromDirectory(directory)
        default:
            throw ModelSessionError.unknownType(resolved)
        }

        model = loaded
        type = resolved
        language = request.language
        return MLXResponse.Loaded(
            type: resolved,
            seconds: Date().timeIntervalSince(started),
            languages: Self.languages(from: directory),
            languageHint: Self.takesLanguageHint.contains(resolved))
    }

    func transcribe(_ request: MLXRequest.Transcribe, samples: [Float]) throws
        -> (segments: [MLXResponse.SegmentEvent], done: MLXResponse.Done)
    {
        guard let model, let type else { throw ModelSessionError.notLoaded }
        // `maxTokens` is not one thing across these families, which is worth
        // knowing before a number is read as a limit. Measured in v0.1.3:
        // Qwen3-ASR, Cohere and Voxtral decrement one budget across every chunk
        // of a buffer; Whisper recomputes a fresh budget per 30-second window;
        // and Parakeet never consults it at all - its transducer decode is
        // bounded by symbols per frame instead. So it is a total for three
        // types, a per-window cap for one, and inert for another.
        let defaults = model.defaultGenerationParameters
        let parameters = STTGenerateParameters(
            maxTokens: request.maxTokens ?? defaults.maxTokens,
            temperature: defaults.temperature,
            topP: defaults.topP,
            topK: defaults.topK,
            verbose: false,
            language: Self.takesLanguageHint.contains(type) ? language : nil,
            chunkDuration: Float(request.chunkSeconds ?? Double(defaults.chunkDuration)),
            minChunkDuration: defaults.minChunkDuration,
            repetitionPenalty: defaults.repetitionPenalty,
            repetitionContextSize: defaults.repetitionContextSize)

        let started = Date()
        let output = model.generate(audio: MLXArray(samples), generationParameters: parameters)
        let seconds = Date().timeIntervalSince(started)
        // Not every model fills this in - Parakeet reports 0.0 - and zero
        // gigabytes is not a measurement. Absent says so; a zero would be read
        // as a number.
        let peak = output.peakMemoryUsage > 0 ? output.peakMemoryUsage : nil

        let duration = Double(samples.count) / Double(Self.sampleRate)
        let spans = Self.spans(from: output.segments)
        if spans.isEmpty {
            // No timings came back, so the only honest span is the whole
            // buffer. `synthesized` says so, because a caller cannot otherwise
            // tell a measured boundary from this one.
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = text.isEmpty
                ? []
                : [MLXResponse.SegmentEvent(
                    id: request.id, index: 0, start: 0, end: duration, text: text)]
            return (segments, MLXResponse.Done(
                id: request.id, seconds: seconds, segments: segments.count,
                synthesized: true, peakMemoryGB: peak))
        }

        let segments = spans.enumerated().map { index, span in
            MLXResponse.SegmentEvent(
                id: request.id, index: index,
                start: span.start, end: span.end, text: span.text)
        }
        return (segments, MLXResponse.Done(
            id: request.id, seconds: seconds, segments: segments.count,
            synthesized: false, peakMemoryGB: peak))
    }

    // MARK: - Reading a directory

    /// The rate this protocol's audio arrives at, and the rate every model here
    /// is built for.
    static let sampleRate = 16000

    private static func readConfig(in directory: URL) throws -> [String: Any] {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ModelSessionError.noConfig(directory.path) }
        return object
    }

    private static func normalize(_ type: String?) -> String? {
        guard let type else { return nil }
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The keys MLX Audio itself reads, in its order, then the directory name.
    /// Same order rather than a tidier one: a directory this library would load
    /// as a Whisper must not load here as something else.
    private static func type(from config: [String: Any], at directory: URL) -> String? {
        for key in ["model_type", "architecture", "model_version"] {
            if let value = normalize(config[key] as? String) {
                return canonical(value)
            }
        }
        return canonical(directory.lastPathComponent.lowercased())
    }

    /// One spelling per family. The library accepts several aliases for the
    /// same type and this keeps the switch above from having to.
    private static func canonical(_ value: String) -> String? {
        if value.contains("qwen3-asr") || value.contains("qwen3_asr") { return "qwen3_asr" }
        if value.contains("parakeet") { return "parakeet" }
        if value.contains("nemotron") { return "nemotron_asr" }
        if value.contains("whisper") { return "whisper" }
        if value.contains("sensevoice") { return "sensevoice" }
        if value.contains("firered") { return "fireredasr2" }
        if value.contains("cohere") { return "cohere_asr" }
        if value.contains("voxtral") { return "voxtral_realtime" }
        return nil
    }

    /// Languages the checkpoint itself names, which today means Whisper's
    /// generation config and nothing else. Empty means the files do not say -
    /// which is not the same as "no languages", and `speech` reports it as the
    /// former rather than inventing a list.
    private static func languages(from directory: URL) -> [String] {
        let url = directory.appendingPathComponent("generation_config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = object["lang_to_id"] as? [String: Any]
        else { return [] }
        return map.keys
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<|>")) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// `STTOutput.segments` is `[[String: Any]]`, so the keys are read rather
    /// than decoded. A span missing any of the three is dropped instead of
    /// being filled in with a zero, because a timestamp nobody produced is the
    /// thing this protocol exists to keep out of a measurement.
    private static func spans(from segments: [[String: Any]]?) -> [(start: Double, end: Double, text: String)] {
        guard let segments, !segments.isEmpty else { return [] }
        var spans: [(start: Double, end: Double, text: String)] = []
        for item in segments {
            guard let text = item["text"] as? String else { return [] }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let start = number(item["start"]), let end = number(item["end"]) else {
                // All or nothing, and the reason is transcript loss rather than
                // tidiness. Two of the eight types return entries with no
                // timings at all, which is fine - they fall through to the
                // whole-buffer span, which carries the model's full text. But a
                // response that mixed timed and untimed entries would, entry by
                // entry, publish the timed ones and silently drop the words in
                // the others: the wire format has no combined-text field, so
                // `speech` reconstructs the transcript by concatenating what it
                // receives. Refusing the whole set costs timings; keeping part
                // of it costs words.
                return []
            }
            // A repair, not a check: `end < start` cannot happen with any of
            // the eight types today, and if a future one produces it this hides
            // it rather than reporting it. That is the lesser harm - the
            // alternative is publishing a span that runs backwards - but it is
            // a repair.
            spans.append((start, max(start, end), trimmed))
        }
        return spans
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let float as Float: return Double(float)
        case let int as Int: return Double(int)
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }
}
