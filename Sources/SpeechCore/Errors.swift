// Errors.swift - the one error type that crosses every layer, and the exit-code
// contract it maps onto.
//
// The codes are part of the published protocol: they appear verbatim in the
// `code` field of an `error` event (appendix B of the development plan) and the
// applet's poller switches on them. Adding a case here is a protocol change;
// renaming one is a breaking protocol change.

import Foundation

public enum SpeechError: Error, Sendable, Equatable {
    /// Bad arguments, an unreadable manifest, a catalog id that parses wrong.
    case usage(String)
    /// The engine exists but cannot run here: OS too old, framework missing,
    /// locale assets refused. Always carries the reason, never a bare "no".
    case unavailable(String)
    /// The weights are not installed. The message carries the catalog id so the
    /// applet can offer the download without re-deriving it.
    case modelMissing(String)
    /// AVFoundation refused the container (webm, mkv, ogg) or it holds no audio.
    case unsupportedFormat(String)
    /// The engine has no model for the requested language.
    case unsupportedLanguage(String)
    /// Everything else that went wrong at run time.
    case runtime(String)

    /// The `code` field of an `error` event.
    public var code: String {
        switch self {
        case .usage: return "usage"
        case .unavailable: return "unavailable"
        case .modelMissing: return "model_missing"
        case .unsupportedFormat: return "unsupported_format"
        case .unsupportedLanguage: return "unsupported_language"
        case .runtime: return "runtime"
        }
    }

    public var message: String {
        switch self {
        case .usage(let m), .unavailable(let m), .modelMissing(let m),
             .unsupportedFormat(let m), .unsupportedLanguage(let m), .runtime(let m):
            return m
        }
    }

    /// Process exit status. Fixed by part 4 of the plan: 0 ok, 1 runtime error,
    /// 2 usage or unavailable engine, 3 model missing. The format and language
    /// cases are runtime failures of a well-formed request, so they exit 1.
    public var exitCode: Int32 {
        switch self {
        case .usage, .unavailable: return 2
        case .modelMissing: return 3
        case .unsupportedFormat, .unsupportedLanguage, .runtime: return 1
        }
    }
}

extension SpeechError: LocalizedError {
    public var errorDescription: String? { message }
}
