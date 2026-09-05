// LivePump.swift - the one consumer between the microphone and a live session.
//
// It exists for three reasons, and only the third one is obvious.
//
// It converts. The tap delivers the hardware's format; the session named its
// own; and when `--refine` is on, the project's canonical 16 kHz mono is needed
// as well, because that is the format every batch measurement in this project
// was taken on. Two converters, one source, applied in one place.
//
// It owns the converters. `AVAudioConverter` is stateful and not thread-safe,
// which under Swift 6 means it cannot be captured by a `Task` closure at all
// without lying about `Sendable`. An actor's stored properties carry no such
// requirement, so making the pump an actor is what lets the converters stay
// honestly non-Sendable while the pump itself crosses task boundaries freely.
//
// It is the serialization point. Everything downstream of the tap - the feed to
// the engine, the append to the refinement buffer - happens here, in order, one
// buffer at a time. A second consumer would interleave audio and no test would
// ever catch it.

import AVFoundation
import Foundation

/// A capture buffer in transit from the audio thread to the pump.
///
/// `@unchecked Sendable` with an argument, not a shrug: the producer allocates
/// this buffer inside one tap callback and drops its own reference before that
/// callback returns, so exactly one reference crosses the boundary and the
/// audio thread can no longer reach it. `AVAudioPCMBuffer` is non-Sendable
/// because buffers are generally shared; this one never is.
public struct CapturedAudio: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

public actor LivePump {
    private let session: any LiveSession
    private let toSession: AudioFormatConverter?
    private let toCanonical: AudioFormatConverter?
    private let audio: LiveAudioBuffer?
    private let inputRate: Double
    private var capturedFrames = 0
    private var running = false
    private var warnedAboutConversion = false
    /// Called once, the first time a buffer cannot be converted for refinement.
    private let onConversionFailure: (@Sendable () -> Void)?

    /// Audio that actually reached the session, in seconds.
    ///
    /// Counted here rather than taken from the refinement buffer, because that
    /// buffer only exists under `--refine` - and a plain live run still has to
    /// report in `done` how much it heard. It reported zero until this existed.
    /// Incremented after a successful `feed`, so the number means what it says.
    public var capturedSeconds: Double {
        inputRate > 0 ? Double(capturedFrames) / inputRate : 0
    }

    /// - Parameters:
    ///   - inputFormat: what the microphone actually produces.
    ///   - audio: the refinement buffer, or nil when `--refine` is off - which
    ///     is also what skips the second conversion entirely, so a run without
    ///     refinement pays nothing for the feature.
    public init(
        session: any LiveSession,
        inputFormat: AVAudioFormat,
        audio: LiveAudioBuffer?,
        onConversionFailure: (@Sendable () -> Void)? = nil
    ) throws {
        self.session = session
        self.audio = audio
        self.inputRate = inputFormat.sampleRate
        self.onConversionFailure = onConversionFailure
        if let target = session.preferredFormat, target != inputFormat {
            self.toSession = try AudioFormatConverter(from: inputFormat, to: target)
        } else {
            self.toSession = nil
        }
        let canonical = LiveAudioFormat.canonical
        if audio != nil, inputFormat != canonical {
            self.toCanonical = try AudioFormatConverter(from: inputFormat, to: canonical)
        } else {
            self.toCanonical = nil
        }
    }

    /// Drains `stream` until it finishes. Throws the first failure from the
    /// session, because a session that has stopped accepting audio is not a
    /// condition to keep pumping through.
    public func run(_ stream: AsyncStream<CapturedAudio>) async throws {
        // One run per pump. Two would interleave into the same stateful
        // `AVAudioConverter`s, which produces audio that is subtly wrong rather
        // than an error anyone would notice.
        guard !running else {
            throw SpeechError.runtime("this live pump is already running")
        }
        running = true
        defer { running = false }

        for await item in stream {
            try Task.checkCancellation()
            let raw = item.buffer

            // Refinement first. If the session throws, the audio that provoked
            // it is still in the buffer, which is what a person trying to work
            // out what happened will want.
            if let audio {
                await append(raw, to: audio)
            }

            let forSession: AVAudioPCMBuffer
            if let toSession {
                forSession = try toSession.convert(raw)
            } else {
                forSession = raw
            }
            guard forSession.frameLength > 0 else { continue }
            try await session.feed(CapturedAudio(forSession))
            capturedFrames += Int(raw.frameLength)
        }
    }

    /// Appends this buffer to the refinement store, at its true length even
    /// when the conversion fails.
    ///
    /// The silence on the failure path is the whole point. `LiveAudioBuffer` is
    /// addressed by seconds since capture start, and its clock is nothing but
    /// the count of samples appended to it. Skipping a failed buffer would put
    /// that clock permanently behind the session's, so *every later* slice would
    /// hand the refine engine audio offset from the text it is replacing, and
    /// `discard(before:)` would trim the wrong span. The cost of a failed
    /// conversion has to stay one bad refinement, not all of them.
    private func append(_ raw: AVAudioPCMBuffer, to audio: LiveAudioBuffer) async {
        guard let converter = toCanonical else {
            await audio.append(LiveAudioFormat.samples(raw))
            return
        }
        if let canonical = try? converter.convert(raw) {
            await audio.append(LiveAudioFormat.samples(canonical))
            return
        }
        // From the buffer's own rate, not the pump's. They are the same for
        // every buffer a tap produces, and when they are not - which is one of
        // the ways a conversion fails in the first place - the buffer's rate is
        // the one that says how much wall time it represents.
        let rate = raw.format.sampleRate > 0 ? raw.format.sampleRate : inputRate
        let ratio = LiveAudioFormat.canonical.sampleRate / max(rate, 1)
        let expected = Int((Double(raw.frameLength) * ratio).rounded())
        await audio.append([Float](repeating: 0, count: max(0, expected)))
        if !warnedAboutConversion {
            warnedAboutConversion = true
            onConversionFailure?()
        }
    }
}
