// MLXWireTests.swift - the format two processes have to agree on.
//
// Nothing here loads a model or spawns anything. What is being tested is the
// part that can silently corrupt a measurement: where one message stops when
// the bytes arrive in whatever sizes a pipe felt like delivering.
//
// The audio payload is the reason this is not just "split on newline". Float32
// samples contain 0x0A as often as any other byte - `newlinesInAudioDoNotEndAFrame`
// builds a buffer that is nothing but newline bytes - so a decoder that looked
// for a terminator inside a payload would cut a buffer of audio in half and
// hand the model the front of it.

import Foundation
import Testing
@testable import SpeechMLXProtocol

@Suite("The speech-mlx wire format")
struct MLXWireTests {
    // MARK: - Encoding

    @Test("every request survives the round trip")
    func requestsRoundTrip() throws {
        let requests: [MLXRequest] = [
            .load(.init(directory: "/models/mlx/parakeet-tdt-0.6b-v3")),
            .load(.init(directory: "/m", type: "whisper", language: "pl")),
            .transcribe(.init(id: 1, samples: 16000, bytes: 64000)),
            .transcribe(.init(id: 7, samples: 8, bytes: 32, chunkSeconds: 30, maxTokens: 512)),
            .unload,
            .bye,
        ]
        for request in requests {
            let line = try MLXWire.line(request)
            let back = try MLXWire.decoder().decode(MLXRequest.self, from: line)
            #expect(back == request)
        }
    }

    @Test("every response survives the round trip")
    func responsesRoundTrip() throws {
        let responses: [MLXResponse] = [
            .ready(.init(helper: "0.1.0", mlxAudio: "0.1.3", mlxSwift: "0.31.6",
                         types: ["parakeet", "whisper"], cacheMegabytes: 512)),
            .loaded(.init(type: "whisper", seconds: 1.5, languages: ["en", "pl"],
                          languageHint: true)),
            .loaded(.init(type: "parakeet", seconds: 0.9, languages: [], languageHint: false)),
            .segment(.init(id: 1, index: 0, start: 0, end: 2.5, text: "hello")),
            .done(.init(id: 1, seconds: 0.4, segments: 2, synthesized: false, peakMemoryGB: 1.25)),
            .done(.init(id: 2, seconds: 0.1, segments: 1, synthesized: true)),
            .ok(.init(op: "unload")),
            .failure(.init(op: "load", message: "no config.json")),
            .failure(.init(op: "transcribe", id: 3, message: "out of memory")),
        ]
        for response in responses {
            let line = try MLXWire.line(response)
            let back = try MLXWire.decoder().decode(MLXResponse.self, from: line)
            #expect(back == response)
        }
    }

    @Test("the discriminator and the payload share one object")
    func encodingIsFlat() throws {
        let line = try MLXWire.line(MLXRequest.transcribe(
            .init(id: 4, samples: 2, bytes: 8, chunkSeconds: 30)))
        let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        let keys = Set(object?.keys ?? [:].keys)
        #expect(keys == ["op", "id", "samples", "bytes", "chunk_seconds"])
        #expect(object?["op"] as? String == "transcribe")

        let event = try MLXWire.line(MLXResponse.segment(
            .init(id: 4, index: 1, start: 1, end: 2, text: "x")))
        let decoded = try JSONSerialization.jsonObject(with: event) as? [String: Any]
        #expect(decoded?["event"] as? String == "segment")
        #expect(decoded?["text"] as? String == "x")
    }

    @Test("a line is one line whatever the payload text contains")
    func linesNeverContainANewline() throws {
        // A message can carry text a model produced, and a raw newline in it
        // would end the frame early. JSONEncoder escapes it; this pins that.
        let line = try MLXWire.line(MLXResponse.segment(
            .init(id: 1, index: 0, start: 0, end: 1, text: "one\ntwo\r\nthree")))
        #expect(!line.contains(0x0A))
        let back = try MLXWire.decoder().decode(MLXResponse.self, from: line)
        #expect(back == .segment(.init(id: 1, index: 0, start: 0, end: 1,
                                       text: "one\ntwo\r\nthree")))
    }

    @Test("an unknown op or event is refused rather than ignored")
    func unknownKindsAreRefused() {
        let request = Data(#"{"op":"reboot"}"#.utf8)
        #expect(throws: (any Error).self) {
            try MLXWire.decoder().decode(MLXRequest.self, from: request)
        }
        let response = Data(#"{"event":"gossip"}"#.utf8)
        #expect(throws: (any Error).self) {
            try MLXWire.decoder().decode(MLXResponse.self, from: response)
        }
    }

    // MARK: - Framing

    /// The stream used by the split tests: three frames, two of them carrying
    /// audio, one carrying none.
    private func sampleStream() throws -> (bytes: Data, frames: [MLXFrame]) {
        let first = [Float](repeating: 0.5, count: 16)
        let second: [Float] = (0..<64).map { Float($0) / 64 }
        var bytes = Data()
        var frames: [MLXFrame] = []

        let a = MLXRequest.transcribe(
            .init(id: 1, samples: first.count, bytes: first.count * 4))
        let aPayload = MLXFrameWriter.payload(samples: first)
        bytes += try MLXFrameWriter.frame(a, payload: aPayload)
        frames.append(MLXFrame(line: try MLXWire.line(a), payload: aPayload))

        let b = MLXRequest.unload
        bytes += try MLXFrameWriter.frame(b)
        frames.append(MLXFrame(line: try MLXWire.line(b)))

        let c = MLXRequest.transcribe(
            .init(id: 2, samples: second.count, bytes: second.count * 4))
        let cPayload = MLXFrameWriter.payload(samples: second)
        bytes += try MLXFrameWriter.frame(c, payload: cPayload)
        frames.append(MLXFrame(line: try MLXWire.line(c), payload: cPayload))

        return (bytes, frames)
    }

    @Test("frames come out whole at every split point")
    func everySplitPointDecodesTheSame() throws {
        let (bytes, expected) = try sampleStream()
        // Every chunk size from one byte up to the whole stream. One byte at a
        // time is the case that finds a decoder which peeks past what it has;
        // the awkward sizes in between are the ones that land inside a length
        // prefix or inside a payload.
        for size in 1...bytes.count {
            var decoder = MLXFrameDecoder()
            var got: [MLXFrame] = []
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + size, bytes.count)
                let batch = decoder.push(bytes.subdata(in: offset..<end))
                #expect(batch.failure == nil)
                got += batch.frames
                offset = end
            }
            #expect(got == expected, "chunk size \(size)")
            #expect(decoder.isIdle, "chunk size \(size) left the decoder mid-frame")
            try decoder.finish()
        }
    }

    @Test("a newline inside the audio does not end a frame")
    func newlinesInAudioDoNotEndAFrame() throws {
        // 0x0A0A0A0A as a Float is a real number, and a buffer of them is a
        // legal one. A decoder that scanned for a terminator inside a payload
        // would report four frames here and cut the audio to pieces.
        let value = Float(bitPattern: 0x0A0A_0A0A)
        let samples = [Float](repeating: value, count: 32)
        let payload = MLXFrameWriter.payload(samples: samples)
        #expect(payload.allSatisfy { $0 == 0x0A })

        let request = MLXRequest.transcribe(
            .init(id: 9, samples: samples.count, bytes: payload.count))
        var decoder = MLXFrameDecoder()
        let frames = decoder.push(try MLXFrameWriter.frame(request, payload: payload)).frames
        #expect(frames.count == 1)
        #expect(MLXFrameWriter.samples(from: frames[0].payload) == samples)
        #expect(decoder.isIdle)
    }

    @Test("blank lines are skipped and nothing else is")
    func blankLinesAreSkipped() throws {
        var decoder = MLXFrameDecoder()
        var bytes = Data("\n  \n".utf8)
        bytes += try MLXFrameWriter.frame(MLXRequest.bye)
        let frames = decoder.push(bytes).frames
        #expect(frames.count == 1)
        #expect(try MLXWire.decoder().decode(MLXRequest.self, from: frames[0].line) == .bye)

        var strict = MLXFrameDecoder()
        let bad = strict.push(Data("not json\n".utf8))
        #expect(bad.frames.isEmpty)
        guard case .malformedHeader = bad.failure else {
            Issue.record("expected a malformed header, got \(String(describing: bad.failure))")
            return
        }
    }

    @Test("a payload size outside the range is refused before it is reserved")
    func payloadSizeIsBounded() {
        func refuses(_ bytes: Int, limit: Int) -> Bool {
            var decoder = MLXFrameDecoder(payloadLimit: limit)
            let header = "{\"op\":\"transcribe\",\"id\":1,\"samples\":1,\"bytes\":\(bytes)}\n"
            let batch = decoder.push(Data(header.utf8))
            guard case .payloadOutOfRange = batch.failure else { return false }
            return true
        }
        #expect(refuses(-4, limit: 1024))
        #expect(refuses(4096, limit: 1024))
        // Both sides of the boundary, so the cap is a limit rather than an
        // off-by-one in either direction.
        #expect(refuses(9, limit: 8))
        #expect(!refuses(8, limit: 8))

        var atLimit = MLXFrameDecoder(payloadLimit: 8)
        let batch = atLimit.push(
            Data((#"{"op":"transcribe","id":1,"samples":2,"bytes":8}"# + "\n").utf8)
            + Data(repeating: 0, count: 8))
        #expect(batch.frames.count == 1)
        #expect(batch.failure == nil)
    }

    @Test("a line with no newline is abandoned at the cap")
    func lineLengthIsBounded() {
        // Two branches, and they are reached by different streams. This one is
        // the line that has not ended yet: nothing to parse, just a buffer that
        // has outgrown the cap.
        var growing = MLXFrameDecoder(lineLimit: 64)
        let batch = growing.push(Data(repeating: 0x41, count: 65))
        #expect(batch.frames.isEmpty)
        #expect(batch.failure == .lineTooLong(limit: 64))

        // And this one is a line that arrives complete, terminator and all, in
        // a single push - so the search finds its newline immediately and the
        // length is only checked afterwards. A sweep that only fed the first
        // shape left this branch untested.
        var complete = MLXFrameDecoder(lineLimit: 64)
        var line = Data(repeating: 0x41, count: 4096)
        line.append(0x0A)
        let batchTwo = complete.push(line)
        #expect(batchTwo.frames.isEmpty)
        #expect(batchTwo.failure == .lineTooLong(limit: 64))

        // A line at the cap is still a line, so the refusal is a limit rather
        // than an off-by-one.
        var exact = MLXFrameDecoder(lineLimit: 13)
        let ok = exact.push(Data((#"{"op":"bye"}"# + "\n").utf8))
        #expect(ok.failure == nil)
        #expect(ok.frames.count == 1)
    }

    @Test("a stream that ends mid-frame says so")
    func truncationIsReported() throws {
        let (bytes, _) = try sampleStream()

        // The specific case matters: `finish` has two truncation sites and one
        // latched-failure site, and a test that accepts any MLXProtocolError
        // cannot tell them apart.
        func truncation(of decoder: inout MLXFrameDecoder) -> String? {
            do {
                try decoder.finish()
                return nil
            } catch let error as MLXProtocolError {
                guard case .truncated(let detail) = error else { return nil }
                return detail
            } catch {
                return nil
            }
        }

        var midPayload = MLXFrameDecoder()
        _ = midPayload.push(bytes.prefix(bytes.count - 4))
        #expect(!midPayload.isIdle)
        #expect(truncation(of: &midPayload)?.contains("payload bytes") == true)

        var midLine = MLXFrameDecoder()
        _ = midLine.push(Data(#"{"op":"by"#.utf8))
        #expect(truncation(of: &midLine)?.contains("no newline") == true)
    }

    @Test("audio survives the trip through the payload")
    func samplesRoundTrip() {
        let samples: [Float] = [-1, -0.5, 0, 0.5, 1, .leastNormalMagnitude, .greatestFiniteMagnitude]
        let payload = MLXFrameWriter.payload(samples: samples)
        #expect(payload.count == samples.count * 4)
        #expect(MLXFrameWriter.samples(from: payload) == samples)
        #expect(MLXFrameWriter.samples(from: Data()) == [])
        // The check that turns a short write into an error rather than into a
        // transcript of whatever arrived.
        #expect(MLXFrameWriter.samples(from: payload.dropLast()) == nil)
        // An offset slice, which is what comes out of the decoder and what
        // `dropLast` above does not produce: dropping from the end leaves
        // startIndex at zero, so it never exercises a Data whose own indices
        // do not start there.
        let offset = payload.dropFirst(2 * MemoryLayout<Float>.size)
        #expect(offset.startIndex == 8)
        #expect(MLXFrameWriter.samples(from: offset) == Array(samples.dropFirst(2)))
    }


    @Test("a long session compacts its buffer without losing a byte")
    func compactionKeepsTheStreamIntact() throws {
        // The compaction branch only runs once the consumed prefix passes 64 KB
        // with a frame still open, so nothing smaller reaches it - and an
        // evaluation cell is 700 utterances through one pipe, which is exactly
        // where a compaction that moved the wrong amount would show up. Twenty
        // 8 KB payloads put the cursor past the threshold; withholding the last
        // ten bytes leaves a frame open across it.
        var stream = Data()
        var expected: [MLXFrame] = []
        for id in 0..<20 {
            let samples = (0..<2048).map { Float($0 &+ id) }
            let payload = MLXFrameWriter.payload(samples: samples)
            let request = MLXRequest.transcribe(
                .init(id: id, samples: samples.count, bytes: payload.count))
            stream += try MLXFrameWriter.frame(request, payload: payload)
            expected.append(MLXFrame(line: try MLXWire.line(request), payload: payload))
        }
        #expect(stream.count > 2 * 65536)

        var decoder = MLXFrameDecoder()
        var got = decoder.push(stream.prefix(stream.count - 10)).frames
        #expect(got.count == 19)
        #expect(!decoder.isIdle)
        got += decoder.push(stream.suffix(10)).frames
        #expect(got == expected)
        #expect(decoder.isIdle)
        try decoder.finish()
    }

    @Test("a session that never lands on a frame boundary still bounds its buffer")
    func compactionBoundsTheBuffer() throws {
        // Compaction is invisible in the frames that come out - which is why
        // deleting it passes every other test here - so what is checked is the
        // memory. Every push stops one byte short of a frame boundary, so the
        // cheap "the cursor reached the end, drop everything" reset never
        // fires and only the compaction branch can return any memory. Without
        // it the decoder holds every byte of the session, and an evaluation
        // cell is about 570 MB of audio through one pipe.
        var stream = Data()
        var boundaries: [Int] = []
        for id in 0..<256 {
            let samples = [Float](repeating: Float(id), count: 1024)
            let payload = MLXFrameWriter.payload(samples: samples)
            let request = MLXRequest.transcribe(
                .init(id: id, samples: samples.count, bytes: payload.count))
            stream += try MLXFrameWriter.frame(request, payload: payload)
            boundaries.append(stream.count)
        }
        #expect(stream.count > 1_000_000)

        var decoder = MLXFrameDecoder()
        var frames = 0
        var peak = 0
        var offset = 0
        for boundary in boundaries {
            let end = boundary - 1
            frames += decoder.push(stream.subdata(in: offset..<end)).frames.count
            peak = max(peak, decoder.retainedBytes)
            #expect(decoder.pendingBytes > 0, "a push landed on a frame boundary after all")
            offset = end
        }
        frames += decoder.push(stream.subdata(in: offset..<stream.count)).frames.count

        #expect(frames == 256)
        #expect(peak < 200_000,
                "the decoder held \(peak) bytes of a \(stream.count) byte session")
    }

    @Test("the newline search does not start over on every push")
    func scanningIsLinearInTheStream() {
        // A rule about work, not about output: a decoder that rescanned the
        // whole unterminated prefix each time would return exactly the same
        // frames and take time quadratic in the length of a line that never
        // ends. That is the shape a garbage stream has, and it is what the line
        // cap exists to reject - but the cap bounds the memory, not the CPU
        // spent reaching it. Counting is the only way to assert it without a
        // stopwatch.
        let length = 4096
        var decoder = MLXFrameDecoder(lineLimit: 1 << 20)
        for _ in 0..<length {
            _ = decoder.push(Data([0x41]))
        }
        #expect(decoder.failure == nil)
        // Linear means each byte is looked at about once. Rescanning would be
        // length * (length + 1) / 2, which is over eight million here.
        #expect(decoder.bytesScanned <= 2 * length,
                "scanned \(decoder.bytesScanned) bytes of a \(length) byte line")
    }

    @Test("a failure keeps the frames that arrived with it, and latches")
    func aFailureDoesNotTakeGoodFramesWithIt() throws {
        // One read off a pipe routinely carries several messages, so a corrupt
        // one arrives behind good ones. Losing those is not a cosmetic problem:
        // they are replies the other side legitimately produced, and a decoder
        // that dropped them would afterwards report `isIdle` and no pending
        // bytes - it would look healthy.
        var stream = try MLXFrameWriter.frame(MLXRequest.unload)
        stream += try MLXFrameWriter.frame(MLXRequest.bye)
        stream += Data((#"{"op":"transcribe","id":1,"samples":1,"bytes":-4}"# + "\n").utf8)
        stream += try MLXFrameWriter.frame(MLXRequest.bye)

        var decoder = MLXFrameDecoder()
        let batch = decoder.push(stream)
        #expect(batch.frames.count == 2, "the two whole frames before the bad one were lost")
        #expect(try MLXWire.decoder().decode(MLXRequest.self, from: batch.frames[0].line) == .unload)
        guard case .payloadOutOfRange = batch.failure else {
            Issue.record("expected payloadOutOfRange, got \(String(describing: batch.failure))")
            return
        }

        // And the stream cannot quietly become this protocol's again: a later
        // push reports the same failure and decodes nothing, however valid it
        // looks.
        let after = decoder.push(try MLXFrameWriter.frame(MLXRequest.bye))
        #expect(after.frames.isEmpty)
        #expect(after.failure != nil)
        #expect(decoder.failure != nil)

        // And a stream that failed did not end cleanly, even when nothing is
        // left in the buffer to call truncated. This decoder consumed every
        // byte it was given - the bad line included - so only the latch can
        // make `finish` refuse.
        var consumed = MLXFrameDecoder()
        var everything = try MLXFrameWriter.frame(MLXRequest.unload)
        everything += Data("not json\n".utf8)
        let batchTwo = consumed.push(everything)
        #expect(batchTwo.frames.count == 1)
        #expect(batchTwo.failure != nil)
        #expect(consumed.isIdle, "the fixture must leave nothing pending, or this proves nothing")
        #expect(throws: MLXProtocolError.self) { try consumed.finish() }
    }

    @Test("every message emits exactly the keys it is supposed to")
    func keysAreWhatTheyAreDeclaredToBe() throws {
        // Two invariants in one place. `bytes` belongs to the framing layer, so
        // no message but `transcribe` may carry that key - a response that grew
        // one would be read as a length prefix and leave the decoder waiting
        // for a payload nobody is going to send. And spelling out the whole key
        // set means a field added to any payload fails here until the
        // specification is updated too, which the document test cannot catch on
        // its own: an added optional is simply absent from the old examples.
        func keys(_ line: Data) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
            return Set(object?.keys ?? [:].keys)
        }

        let requests: [(MLXRequest, Set<String>)] = [
            (.load(.init(directory: "/d")), ["op", "directory"]),
            (.load(.init(directory: "/d", type: "whisper", language: "pl")),
             ["op", "directory", "type", "language"]),
            (.transcribe(.init(id: 1, samples: 2, bytes: 8)),
             ["op", "id", "samples", "bytes"]),
            (.transcribe(.init(id: 1, samples: 2, bytes: 8, chunkSeconds: 30, maxTokens: 9)),
             ["op", "id", "samples", "bytes", "chunk_seconds", "max_tokens"]),
            (.unload, ["op"]),
            (.bye, ["op"]),
        ]
        for (request, expected) in requests {
            let got = try keys(MLXWire.line(request))
            #expect(got == expected, "\(request.op): \(got.sorted())")
        }

        let responses: [(MLXResponse, Set<String>)] = [
            (.ready(.init(helper: "1", mlxAudio: "2", mlxSwift: "3", types: [], cacheMegabytes: 0)),
             ["event", "helper", "mlx_audio", "mlx_swift", "types", "cache_mb"]),
            (.loaded(.init(type: "t", seconds: 1, languages: [], languageHint: false)),
             ["event", "type", "seconds", "languages", "language_hint"]),
            (.segment(.init(id: 1, index: 0, start: 0, end: 1, text: "x")),
             ["event", "id", "index", "start", "end", "text"]),
            (.done(.init(id: 1, seconds: 1, segments: 1, synthesized: false)),
             ["event", "id", "seconds", "segments", "synthesized"]),
            (.done(.init(id: 1, seconds: 1, segments: 1, synthesized: false, peakMemoryGB: 2)),
             ["event", "id", "seconds", "segments", "synthesized", "peak_memory_gb"]),
            (.ok(.init(op: "unload")), ["event", "op"]),
            (.failure(.init(op: "load", message: "m")), ["event", "op", "message"]),
            (.failure(.init(op: "transcribe", id: 3, message: "m")),
             ["event", "op", "id", "message"]),
        ]
        for (response, expected) in responses {
            let got = try keys(MLXWire.line(response))
            #expect(got == expected, "\(response.event): \(got.sorted())")
            #expect(!got.contains("bytes"),
                    "a response carrying `bytes` would be read as a length prefix")
        }
    }

    @Test("the examples in docs/mlx-helper.md are the format this code speaks")
    func documentedExamplesAreReal() throws {
        // A specification nobody executes drifts from the code within a
        // commit or two. Every fenced `jsonl` line in the document is decoded
        // here, re-encoded, and compared key by key: a renamed field fails to
        // decode, and a field the document still shows but the code no longer
        // emits fails as a key with nothing behind it.
        let document = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/mlx-helper.md")
        let text = try String(contentsOf: document, encoding: .utf8)

        var examples: [String] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```jsonl") { inside = true; continue }
            if line.hasPrefix("```") { inside = false; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inside, !trimmed.isEmpty { examples.append(trimmed) }
        }
        #expect(examples.count >= 12, "found only \(examples.count) examples")

        for example in examples {
            let data = Data(example.utf8)
            let documented = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let keys = Set(documented?.keys ?? [:].keys)

            // `event` is tested first, not `op`: an `error` response carries
            // both, because it names the request it is about. Reading `op`
            // first would decode every error example as a request.
            let reencoded: Data
            if keys.contains("event") {
                let response = try MLXWire.decoder().decode(MLXResponse.self, from: data)
                reencoded = try MLXWire.line(response)
            } else {
                let request = try MLXWire.decoder().decode(MLXRequest.self, from: data)
                reencoded = try MLXWire.line(request)
            }
            let produced = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
            let producedKeys = Set(produced?.keys ?? [:].keys)
            let orphans = keys.subtracting(producedKeys).sorted()
            #expect(orphans.isEmpty,
                    "\(example) documents keys this code does not emit: \(orphans)")
        }
    }

    // MARK: - The target's boundary

    @Test("this target compiles into the helper, so it imports nothing of ours")
    func protocolTargetIsSelfContained() throws {
        // The helper's Xcode project lists Sources/SpeechMLXProtocol as a
        // source path. An import of SpeechCore here would compile FluidAudio
        // and the transcribe.cpp xcframework into a binary whose reason to
        // exist is being optional - and it would not fail until that build,
        // which is not run by `swift test`.
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SpeechMLXProtocolTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/SpeechMLXProtocol")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!names.isEmpty, "no sources found at \(directory.path)")
        for name in names {
            let source = try String(contentsOf: directory.appendingPathComponent(name),
                                    encoding: .utf8)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                // `@testable import SpeechCore` does not start with "import",
                // and it would violate this rule exactly as much as the plain
                // form does.
                for attribute in ["@testable ", "@_exported ", "@_implementationOnly "]
                where trimmed.hasPrefix(attribute) {
                    trimmed = String(trimmed.dropFirst(attribute.count))
                }
                guard trimmed.hasPrefix("import ") else { continue }
                #expect(trimmed == "import Foundation",
                        "\(name) imports something the helper cannot have: \(trimmed)")
            }
        }
    }
}
