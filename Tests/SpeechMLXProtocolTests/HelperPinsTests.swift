// HelperPinsTests.swift - the helper's version strings against the manifest
// that decides them.
//
// `speech-mlx` reports its dependency versions in the handshake, and those
// numbers end up beside a measurement. Neither mlx-swift nor mlx-audio-swift
// exposes a runtime version, so the helper carries literals - and a literal
// that drifts from the pin is worse than no version at all, because it is a
// claim about which library produced a number.
//
// The same shape as `packagePinMatchesLiteral` for FluidAudio, and here for the
// same reason. It lives in this test target rather than the helper's project
// because the helper has no test bundle: its whole graph is MLX, so a test
// there would need the Metal toolchain to check a string.

import Foundation
import Testing

@Suite("The MLX helper's pins")
struct HelperPinsTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SpeechMLXProtocolTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    /// `exactVersion: 0.1.3` under a named package in project.yml.
    private func pin(_ package: String, in spec: String) -> String? {
        guard let range = spec.range(of: "\n  \(package):\n") else { return nil }
        let rest = spec[range.upperBound...]
        for line in rest.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("exactVersion:") {
                return trimmed.replacingOccurrences(of: "exactVersion:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            // Stop at the next package or the next top-level key, so a missing
            // exactVersion reads as absent rather than as the next entry's.
            if !line.hasPrefix("    ") && !trimmed.isEmpty { break }
        }
        return nil
    }

    /// `static let mlxSwift = "0.31.6"` in the helper's Version.swift.
    private func literal(_ name: String, in source: String) -> String? {
        guard let range = source.range(of: "static let \(name) = \"") else { return nil }
        let rest = source[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    @Test("the helper reports the versions project.yml pins")
    func helperPinsMatchTheProject() throws {
        let spec = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Helpers/speech-mlx/project.yml"),
            encoding: .utf8)
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Helpers/speech-mlx/Sources/speech-mlx/Version.swift"),
            encoding: .utf8)

        for (package, constant) in [("mlx-audio-swift", "mlxAudio"), ("mlx-swift", "mlxSwift")] {
            let pinned = pin(package, in: spec)
            let reported = literal(constant, in: source)
            #expect(pinned != nil, "project.yml pins no exact version for \(package)")
            #expect(reported != nil, "Version.swift has no literal for \(constant)")
            let detail = "\(package): project.yml says \(pinned ?? "nothing"),"
                + " the helper reports \(reported ?? "nothing")"
            #expect(pinned == reported, "\(detail)")
        }
    }

    @Test("the generated project describes the manifest that is checked in")
    func projectMatchesTheSpec() throws {
        // Not a timestamp comparison: git does not preserve modification times,
        // so on a fresh clone the order of two files' mtimes is an accident and
        // a test built on it would fail for the wrong reason. What can be
        // checked without them is that everything the spec names is actually in
        // the generated project - which is what a forgotten `xcodegen generate`
        // gets wrong.
        let helper = repositoryRoot.appendingPathComponent("Helpers/speech-mlx")
        let spec = try String(
            contentsOf: helper.appendingPathComponent("project.yml"), encoding: .utf8)
        let generated = try String(
            contentsOf: helper.appendingPathComponent("speech-mlx.xcodeproj/project.pbxproj"),
            encoding: .utf8)

        // Every source directory the spec lists must have contributed its
        // files. Counted, because a spec reformatted into a style this
        // line-based parser does not recognize would otherwise run the loop
        // zero times and pass without checking anything - which is exactly the
        // forgotten-regeneration case the test exists for.
        var checked = 0
        for line in spec.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- path: ") else { continue }
            let path = String(trimmed.dropFirst("- path: ".count))
            let directory = URL(fileURLWithPath: path, relativeTo: helper)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasSuffix(".swift") } ?? []
            checked += 1
            #expect(!names.isEmpty, "the spec lists \(path), which holds no Swift sources")
            for name in names {
                let detail = "\(name) is under \(path) but not in the generated project;"
                    + " run: (cd Helpers/speech-mlx && xcodegen generate)"
                #expect(generated.contains(name), "\(detail)")
            }
        }

        #expect(checked >= 2, "found \(checked) source paths in project.yml; the parser is broken")

        // And both pins must have reached it, so a version bump in the spec
        // cannot sit in a project that still resolves the old one.
        for package in ["mlx-audio-swift", "mlx-swift"] {
            guard let version = pin(package, in: spec) else {
                Issue.record("project.yml pins no exact version for \(package)")
                continue
            }
            #expect(generated.contains(version),
                    "\(package) is pinned at \(version) in the spec but not in the project")
        }
    }
}
