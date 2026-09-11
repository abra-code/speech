// GGMLAddition.swift - the decisions behind `speech models add`: which GGUF in
// a repository to take, what to call it, and the catalog entry the loaded model
// earns.
//
// transcribe.cpp loads any GGUF whose architecture it knows and reports the
// rest itself - languages, language identification, streaming, timestamps. So
// adding a model needs nothing the file cannot answer except where it lives and
// what to call it, and those are guessed from the file name only as far as the
// name makes them obvious. Everything here is pure, so the guesses can be
// tested without a network or a model.

import Foundation
import SpeechCore

public enum GGMLAddition {
    /// A GGUF file name split into the model it names and the quantization it
    /// is: `Qwen3-ASR-1.7B-Q4_K_M.gguf` is `Qwen3-ASR-1.7B` at `Q4_K_M`. The
    /// quantization is the last dash-separated part, and only when it looks
    /// like one - `model.gguf` has none.
    public static func split(_ fileName: String) -> (stem: String, quant: String?) {
        var name = String(fileName.split(separator: "/").last ?? Substring(fileName))
        if name.lowercased().hasSuffix(".gguf") { name.removeLast(5) }
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count > 1, let last = parts.last, isQuantization(String(last)) else {
            return (name, nil)
        }
        return (parts.dropLast().joined(separator: "-"), String(last))
    }

    /// Q8_0, Q4_K_M, IQ4_XS, F16, BF16, F32: the spellings llama.cpp-style
    /// quantizers put at the end of a GGUF name.
    static func isQuantization(_ token: String) -> Bool {
        let lower = token.lowercased()
        if ["f16", "bf16", "f32", "fp16", "fp32"].contains(lower) { return true }
        var scalars = Substring(lower)
        if scalars.hasPrefix("i") { scalars = scalars.dropFirst() }
        guard scalars.hasPrefix("q"), scalars.count >= 2 else { return false }
        let rest = scalars.dropFirst()
        guard let first = rest.first, first.isNumber else { return false }
        return rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Which GGUF to take from a repository listing.
    ///
    /// An explicit file wins, then an explicit quantization; with neither, the
    /// only GGUF there is, or else Q8_0 - the precision every other row in the
    /// catalog is measured at first. Anything else asks, and says what there is
    /// to choose from, rather than picking one of several gigabyte downloads by
    /// a rule the user never saw.
    public static func chooseFile(
        from listing: [String], quant: String?, file: String?, repo: String
    ) throws -> String {
        let ggufs = listing.filter { $0.lowercased().hasSuffix(".gguf") }.sorted()
        guard !ggufs.isEmpty else {
            throw SpeechError.usage("\(repo) lists no .gguf files, so it is not a transcribe.cpp model"
                + (listing.isEmpty ? "" : " (it lists \(listing.sorted().joined(separator: ", ")))"))
        }
        let choices = ggufs.joined(separator: ", ")
        if let file {
            guard ggufs.contains(file) else {
                throw SpeechError.usage("\(repo) does not list '\(file)' (have: \(choices))")
            }
            return file
        }
        func quantOf(_ name: String) -> String? { split(name).quant?.lowercased() }
        if let quant {
            let matches = ggufs.filter { quantOf($0) == quant.lowercased() }
            guard matches.count == 1, let only = matches.first else {
                throw SpeechError.usage(
                    matches.isEmpty
                        ? "\(repo) has no \(quant.uppercased()) file (have: \(choices))"
                        : "\(repo) has several \(quant.uppercased()) files (\(matches.joined(separator: ", ")));"
                            + " pick one with --file")
            }
            return only
        }
        if ggufs.count == 1, let only = ggufs.first { return only }
        let q8 = ggufs.filter { quantOf($0) == "q8_0" }
        if q8.count == 1, let only = q8.first { return only }
        throw SpeechError.usage("\(repo) has several .gguf files; pick one with --quant or --file"
            + " (have: \(choices))")
    }

    /// A name that can be a catalog id component: lowercase, with anything
    /// outside `a-z 0-9 . _ -` turned into `-`. nil when nothing usable is left.
    public static func idName(_ text: String) -> String? {
        let mapped = String(text.lowercased().unicodeScalars.map { scalar -> Character in
            let allowed = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-"
            return allowed ? Character(scalar) : "-"
        })
        let trimmed = String(mapped.drop { !$0.isLetter && !$0.isNumber })
        return CatalogModel.isName(trimmed) ? trimmed : nil
    }

    /// The model name a file suggests: its stem, or failing that the
    /// repository's name without a trailing `-gguf`.
    public static func modelName(stem: String, repo: String) -> String? {
        if let name = idName(stem) { return name }
        var repoName = String(repo.split(separator: "/").last ?? "")
        if repoName.lowercased().hasSuffix("-gguf") { repoName.removeLast(5) }
        return idName(repoName)
    }

    /// The family a GGUF's architecture names, spelled the way the catalog
    /// spells families: `qwen3_asr` is the built-in `qwen3-asr`, and
    /// `granite_speech` joins the built-in Granite entries as `granite-speech`.
    /// Without the respelling a model added this way would sit in a family of
    /// its own beside the built-in builds of the same model.
    public static func family(architecture: String) -> CatalogFamily {
        CatalogFamily(rawValue: idName(architecture.replacingOccurrences(of: "_", with: "-")) ?? "unknown")
    }

    /// The variant a loaded model earns in a catalog entry.
    public static func variant(
        name: String, file: String, sizeBytes: Int64?, label: String
    ) -> CatalogVariant {
        CatalogVariant(variant: name, file: file, precision: name, sizeBytes: sizeBytes, label: label)
    }

    /// A new catalog entry for a model nobody described: every capability
    /// field from the loaded weights, the family from its architecture.
    public static func entry(
        model: String, repo: String, variant: CatalogVariant, probe: GGMLProbe, date: Date = Date()
    ) -> CatalogModel {
        var facts = ["architecture \(probe.architecture)"]
        if !probe.variant.isEmpty { facts.append("stt.variant \(probe.variant)") }
        if let seconds = probe.maxAudioSeconds {
            facts.append("at most \(Int(seconds.rounded())) s of audio per run")
        }
        let day = ISO8601DateFormatter.string(
            from: date, timeZone: TimeZone(identifier: "UTC") ?? .current,
            formatOptions: [.withFullDate])
        return CatalogModel(
            engine: "ggml",
            model: model,
            family: family(architecture: probe.architecture),
            note: "Added by 'speech models add \(repo)' on \(day) UTC. Read from the loaded GGUF: "
                + facts.joined(separator: ", ") + ". Edit freely; an entry here replaces any"
                + " built-in entry of the same model.",
            source: repo,
            languages: probe.languages,
            languageID: probe.languageID,
            streaming: probe.streaming,
            wordTimestamps: probe.wordTimestamps,
            segmentTimestamps: probe.segmentTimestamps,
            variants: [variant])
    }
}
