// FluidAliases.swift - names for FluidAudio types that cannot be spelled
// anywhere else in this module.
//
// Two collisions make module-qualification impossible:
//
//   - FluidAudio exports a `struct FluidAudio`, so `FluidAudio.Language` binds
//     to a member of that struct, not to the module's top-level type, and the
//     compiler says "'Language' is not a member type of struct FluidAudio".
//   - SpeechCore has its own `Language`, so the bare name is ambiguous in any
//     file that imports both.
//
// This file imports only FluidAudio, which makes every bare name below resolve
// unambiguously to theirs. Everywhere else in SpeechFluid uses these aliases.
//
// Note that FluidAudio declares three separate types called `Language` - the
// top-level one in Shared/TokenLanguageFilter.swift, plus nested ones in the
// Cohere ASR and TTS text-normalizer namespaces. Only the top-level one is
// visible here, and it is the one `AsrManager.transcribe(language:)` takes.

import FluidAudio

/// FluidAudio's ASR language hint (28 European languages, String-backed).
typealias FluidASRLanguage = Language

/// `@Sendable (DownloadProgress) -> Void`.
typealias FluidProgressHandler = ProgressHandler
