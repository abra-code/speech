// Coding.swift - the two enums on the wire, encoded flat.
//
// Flat, like the JSONL protocol `speech` already emits: the discriminator and
// the payload's fields share one object rather than nesting the payload under a
// key. JSONEncoder merges when a payload encodes into the same encoder the
// header wrote to, and decoding reads the discriminator and then re-decodes the
// whole object as the payload type. `MLXWireTests` pins the round trip.

import Foundation

// MARK: - Requests

extension MLXRequest: Codable {
    private enum HeaderKeys: String, CodingKey { case op }

    public func encode(to encoder: Encoder) throws {
        var header = encoder.container(keyedBy: HeaderKeys.self)
        try header.encode(op, forKey: .op)
        switch self {
        case .load(let request): try request.encode(to: encoder)
        case .transcribe(let request): try request.encode(to: encoder)
        case .unload, .bye: break
        }
    }

    public init(from decoder: Decoder) throws {
        let header = try decoder.container(keyedBy: HeaderKeys.self)
        let op = try header.decode(String.self, forKey: .op)
        switch op {
        case "load": self = .load(try Load(from: decoder))
        case "transcribe": self = .transcribe(try Transcribe(from: decoder))
        case "unload": self = .unload
        case "bye": self = .bye
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: header, debugDescription: "unknown op '\(op)'")
        }
    }
}

// MARK: - Responses

extension MLXResponse: Codable {
    private enum HeaderKeys: String, CodingKey { case event }

    public func encode(to encoder: Encoder) throws {
        var header = encoder.container(keyedBy: HeaderKeys.self)
        try header.encode(event, forKey: .event)
        switch self {
        case .ready(let payload): try payload.encode(to: encoder)
        case .loaded(let payload): try payload.encode(to: encoder)
        case .segment(let payload): try payload.encode(to: encoder)
        case .done(let payload): try payload.encode(to: encoder)
        case .ok(let payload): try payload.encode(to: encoder)
        case .failure(let payload): try payload.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let header = try decoder.container(keyedBy: HeaderKeys.self)
        let event = try header.decode(String.self, forKey: .event)
        switch event {
        case "ready": self = .ready(try Ready(from: decoder))
        case "loaded": self = .loaded(try Loaded(from: decoder))
        case "segment": self = .segment(try SegmentEvent(from: decoder))
        case "done": self = .done(try Done(from: decoder))
        case "ok": self = .ok(try Ok(from: decoder))
        case "error": self = .failure(try Failure(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: header, debugDescription: "unknown event '\(event)'")
        }
    }
}

// MARK: - One encoder and one decoder, configured once

public enum MLXWire {
    /// Sorted keys so that a line is reproducible: `test.sh` regenerates the
    /// examples in docs/mlx-helper.md and diffs them, which only works if the
    /// same value always produces the same bytes.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }

    /// One request as its line, without the newline.
    public static func line(_ request: MLXRequest) throws -> Data {
        try encoder().encode(request)
    }

    /// One response as its line, without the newline.
    public static func line(_ response: MLXResponse) throws -> Data {
        try encoder().encode(response)
    }
}
