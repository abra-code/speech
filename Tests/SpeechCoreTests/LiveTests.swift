// LiveTests.swift - the parts of live mode that can be tested without a
// microphone, which is more of it than it first looks.
//
// The microphone itself needs hardware, a TCC grant and a person to speak, so
// none of it is exercised here. Everything downstream of the tap is
// deterministic and is: format conversion, the mono mixdown, the time-addressed
// audio buffer that refinement slices out of, the pump that wires them
// together, and the refinement queue's ordering, backlog and drain behavior.

import AVFoundation
import Foundation
import Testing

@testable import SpeechCore

@Suite("Live audio buffer")
struct LiveAudioBufferTests {
    static func ramp(_ count: Int, from start: Float = 0) -> [Float] {
        (0..<count).map { start + Float($0) }
    }

    @Test("a slice comes back at the seconds it was written at")
    func sliceByTime() async {
        let rate = AudioDecoder.sampleRate
        let buffer = LiveAudioBuffer(sampleRate: rate)
        await buffer.append(Self.ramp(Int(rate) * 3))

        let second = await buffer.slice(from: 1, to: 2)
        #expect(second?.count == Int(rate))
        #expect(second?.first == Float(Int(rate)))
        #expect(await buffer.capturedSeconds == 3)
    }

    @Test("time addressing survives the front being dropped")
    func sliceAfterDiscard() async {
        let rate = AudioDecoder.sampleRate
        let buffer = LiveAudioBuffer(sampleRate: rate)
        await buffer.append(Self.ramp(Int(rate) * 4))
        await buffer.discard(before: 2)

        // The whole point: the third second is still the third second.
        let third = await buffer.slice(from: 2, to: 3)
        #expect(third?.count == Int(rate))
        #expect(third?.first == Float(Int(rate) * 2))
        // And the first is gone rather than misreported.
        #expect(await buffer.slice(from: 0, to: 1) == nil)
    }

    @Test("a partly trimmed span returns its surviving tail, not nothing")
    func sliceOverlapsTrimLine() async {
        let rate = AudioDecoder.sampleRate
        let buffer = LiveAudioBuffer(sampleRate: rate)
        await buffer.append(Self.ramp(Int(rate) * 4))
        await buffer.discard(before: 2)

        let straddling = await buffer.slice(from: 1, to: 3)
        #expect(straddling?.count == Int(rate))
        #expect(straddling?.first == Float(Int(rate) * 2))
    }

    @Test("the retention ceiling bounds a session nobody finalizes")
    func ceiling() async {
        let rate = 100.0
        let buffer = LiveAudioBuffer(sampleRate: rate, retainedSeconds: 2)
        for _ in 0..<10 { await buffer.append(Self.ramp(100)) }

        // The contract, not the trim schedule: everything was counted, no more
        // than the ceiling is retained, and what is retained is the newest.
        // Asserting an exact window would pin the chunk size instead, which is
        // an implementation choice made for the cost of `removeFirst`.
        #expect(await buffer.capturedSeconds == 10)
        let window = await buffer.retainedWindow
        #expect(window.end == 10)
        #expect(window.end - window.start <= 2)
        #expect(window.start > 0)
        #expect(await buffer.slice(from: 0, to: 1) == nil)
        #expect(await buffer.slice(from: 9, to: 10)?.count == 100)
    }

    @Test("a hostile timestamp is refused, not a trap")
    func hostileTimes() async {
        // These come from engine-reported time ranges once stage 4.2 lands, and
        // `Int(Double)` traps rather than saturating. A model reporting a bad
        // range must not be able to crash the process.
        let buffer = LiveAudioBuffer()
        await buffer.append([0, 1, 2, 3])
        #expect(await buffer.slice(from: .nan, to: 1) == nil)
        #expect(await buffer.slice(from: 0, to: .nan) == nil)
        #expect(await buffer.slice(from: .nan, to: .nan) == nil)
        // Infinities clamp to the ends rather than being refused: "everything
        // from here on" is a sensible request and the clamp makes it exact.
        #expect(await buffer.slice(from: 0, to: .infinity)?.count == 4)
        #expect(await buffer.slice(from: -.infinity, to: .infinity)?.count == 4)
        #expect(await buffer.slice(from: 0, to: 1e30)?.count == 4)
        #expect(await buffer.slice(from: 1e30, to: .infinity) == nil)
        await buffer.discard(before: .nan)
        await buffer.discard(before: 1e30)
        #expect(await buffer.capturedSeconds > 0)
    }

    @Test("an empty or reversed span is nil rather than a crash")
    func degenerateSpans() async {
        let buffer = LiveAudioBuffer()
        await buffer.append([0, 1, 2, 3])
        #expect(await buffer.slice(from: 1, to: 1) == nil)
        #expect(await buffer.slice(from: 2, to: 1) == nil)
        #expect(await buffer.slice(from: 100, to: 200) == nil)
    }
}

@Suite("Live audio format")
struct LiveAudioFormatTests {
    static func buffer(
        rate: Double, channels: AVAudioChannelCount, interleaved: Bool, frames: Int,
        fill: (Int, Int) -> Float
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        for frame in 0..<frames {
            for channel in 0..<Int(channels) {
                if interleaved {
                    data[0][frame * Int(channels) + channel] = fill(frame, channel)
                } else {
                    data[channel][frame] = fill(frame, channel)
                }
            }
        }
        return buffer
    }

    @Test("mono passes through untouched")
    func mono() {
        let buffer = Self.buffer(
            rate: 16000, channels: 1, interleaved: false, frames: 4) { frame, _ in Float(frame) }
        #expect(LiveAudioFormat.samples(buffer) == [0, 1, 2, 3])
    }

    @Test("a stereo microphone on one channel is averaged, not dropped")
    func stereoNonInterleaved() {
        // The failure this guards: taking channel 0 only. An interface with the
        // microphone wired to the right channel would then record silence, and
        // the transcript would be empty with nothing to explain it.
        let buffer = Self.buffer(rate: 16000, channels: 2, interleaved: false, frames: 4) {
            frame, channel in channel == 0 ? 0 : Float(frame) * 2
        }
        #expect(LiveAudioFormat.samples(buffer) == [0, 1, 2, 3])
    }

    @Test("interleaved stereo is averaged with the right stride")
    func stereoInterleaved() {
        let buffer = Self.buffer(rate: 16000, channels: 2, interleaved: true, frames: 4) {
            frame, channel in channel == 0 ? 0 : Float(frame) * 2
        }
        #expect(LiveAudioFormat.samples(buffer) == [0, 1, 2, 3])
    }

    @Test("the canonical format is what the decoder produces")
    func canonical() {
        let format = LiveAudioFormat.canonical
        #expect(format.sampleRate == AudioDecoder.sampleRate)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatFloat32)
        #expect(format.isInterleaved == false)
    }
}

@Suite("Audio format conversion")
struct AudioFormatConverterTests {
    static func tone(rate: Double, channels: AVAudioChannelCount, seconds: Double) -> AVAudioPCMBuffer {
        let frames = Int(rate * seconds)
        return LiveAudioFormatTests.buffer(
            rate: rate, channels: channels, interleaved: false, frames: frames
        ) { frame, _ in
            Float(sin(2 * Double.pi * 440 * Double(frame) / rate))
        }
    }

    /// Total output frames for `count` identical buffers.
    ///
    /// Duration is a property of the *stream*, not of one call: the resampler
    /// holds a filter delay, so the first conversion is short by about 1180
    /// frames and gives them back over the next few. Asserting on a single
    /// buffer measures the delay line, not the conversion.
    static func totalFrames(
        _ source: AVAudioPCMBuffer, to target: AVAudioFormat, count: Int
    ) throws -> Int {
        let converter = try AudioFormatConverter(from: source.format, to: target)
        var frames = 0
        for _ in 0..<count { frames += Int(try converter.convert(source).frameLength) }
        return frames
    }

    @Test("48 kHz stereo down to 16 kHz mono conserves duration")
    func downsample() throws {
        let source = Self.tone(rate: 48000, channels: 2, seconds: 0.5)
        let converter = try AudioFormatConverter(
            from: source.format, to: LiveAudioFormat.canonical)
        let first = try converter.convert(source)
        #expect(first.format.sampleRate == AudioDecoder.sampleRate)
        #expect(first.format.channelCount == 1)

        // Ten half-second buffers is five seconds, which is 80000 frames at
        // 16 kHz. The only shortfall allowed is the resampler's delay line,
        // which is bounded and does not accumulate - that is the property that
        // matters, because one lost frame per buffer would be a growing drift.
        let total = try Self.totalFrames(source, to: LiveAudioFormat.canonical, count: 10)
        #expect(total <= 80000)
        #expect(total >= 80000 - 2000)
    }

    @Test("a non-integer ratio does not drift")
    func fractionalRatio() throws {
        // 44100 to 16000 is where a floor-based capacity calculation loses a
        // frame per buffer, which over a minute is an audible drift.
        let source = Self.tone(rate: 44100, channels: 1, seconds: 0.1)
        let ten = try Self.totalFrames(source, to: LiveAudioFormat.canonical, count: 10)
        let twenty = try Self.totalFrames(source, to: LiveAudioFormat.canonical, count: 20)
        #expect(ten <= 16000)
        #expect(twenty <= 32000)
        // The shortfall is a fixed delay, so it must not grow with the number
        // of buffers. A per-buffer truncation would double it here.
        #expect((32000 - twenty) <= (16000 - ten) + 8)
    }

    @Test("consecutive buffers keep converting")
    func repeated() throws {
        let source = Self.tone(rate: 48000, channels: 1, seconds: 0.1)
        let converter = try AudioFormatConverter(
            from: source.format, to: LiveAudioFormat.canonical)
        // The regression this pins: answering `.endOfStream` instead of
        // `.noDataNow` in the input block works for one buffer and then
        // produces nothing forever.
        for _ in 0..<5 {
            let out = try converter.convert(source)
            #expect(out.frameLength > 0)
        }
    }

    @Test("a copy is independent of the buffer it came from")
    func copyIsPrivate() {
        let source = LiveAudioFormatTests.buffer(
            rate: 16000, channels: 1, interleaved: false, frames: 4) { frame, _ in Float(frame) }
        let copy = AudioFormatConverter.copy(source)
        #expect(copy != nil)
        source.floatChannelData![0][0] = 99
        #expect(copy?.floatChannelData?[0][0] == 0)
        #expect(copy?.frameLength == 4)
    }

    /// Every layout a capture device can present. Int16 and Int32 are common on
    /// USB interfaces; the previous copy went through `floatChannelData` and
    /// friends and returned nil for anything they did not name, which made the
    /// whole run silent with no error until it ended.
    @Test(
        "a copy round-trips every sample format and interleaving",
        arguments: [
            (AVAudioCommonFormat.pcmFormatFloat32, AVAudioChannelCount(1), false),
            (.pcmFormatFloat32, 2, false),
            (.pcmFormatFloat32, 2, true),
            (.pcmFormatInt16, 1, true),
            (.pcmFormatInt16, 2, true),
            (.pcmFormatInt32, 2, true),
            (.pcmFormatFloat64, 1, false),
            (.pcmFormatFloat64, 2, true),
        ])
    func copyAcrossFormats(
        format: AVAudioCommonFormat, channels: AVAudioChannelCount, interleaved: Bool
    ) throws {
        let audioFormat = try #require(AVAudioFormat(
            commonFormat: format, sampleRate: 48000,
            channels: channels, interleaved: interleaved))
        let frames = 64
        let source = try #require(AVAudioPCMBuffer(
            pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frames)))
        source.frameLength = AVAudioFrameCount(frames)

        // Fill through the raw buffer list so the test does not depend on the
        // typed accessors it is checking the copy no longer needs.
        let list = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        for index in 0..<list.count {
            let bytes = UnsafeMutableRawBufferPointer(
                start: list[index].mData, count: Int(list[index].mDataByteSize))
            for offset in bytes.indices { bytes[offset] = UInt8((offset &+ index &* 7) % 251) }
        }

        let copy = try #require(AudioFormatConverter.copy(source))
        #expect(copy.frameLength == source.frameLength)
        #expect(copy.format == source.format)

        let copied = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        #expect(copied.count == list.count)
        for index in 0..<list.count {
            let from = UnsafeRawBufferPointer(
                start: list[index].mData, count: Int(list[index].mDataByteSize))
            let to = UnsafeRawBufferPointer(
                start: copied[index].mData, count: Int(copied[index].mDataByteSize))
            #expect(from.elementsEqual(to), "buffer \(index) differs")
        }

        // And it is a copy, not an alias.
        let firstByte = UnsafeMutableRawBufferPointer(
            start: list[0].mData, count: Int(list[0].mDataByteSize))
        let before = UnsafeRawBufferPointer(
            start: copied[0].mData, count: Int(copied[0].mDataByteSize))[0]
        firstByte[0] = firstByte[0] &+ 1
        let after = UnsafeRawBufferPointer(
            start: copied[0].mData, count: Int(copied[0].mDataByteSize))[0]
        #expect(before == after)
    }
}

// MARK: - Doubles

/// A live session that records what it was fed and replays a scripted set of
/// events. Enough to drive `LivePump` and the refinement path without a model.
actor FakeLiveSession: LiveSession {
    nonisolated let events: AsyncStream<LiveEvent>
    nonisolated let preferredFormat: AVAudioFormat?

    nonisolated let honorsSpeechBoundaries: Bool

    private let continuation: AsyncStream<LiveEvent>.Continuation
    private var fed: [(rate: Double, channels: Int, frames: Int)] = []
    private var marks: [SpeechBoundary] = []
    private var finals: [Segment] = []
    private var failOnFeed: String?

    init(
        preferredFormat: AVAudioFormat? = nil,
        failOnFeed: String? = nil,
        honorsBoundaries: Bool = true
    ) {
        self.preferredFormat = preferredFormat
        self.failOnFeed = failOnFeed
        self.honorsSpeechBoundaries = honorsBoundaries
        let (events, continuation) = AsyncStream<LiveEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    private var markPositions: [Int] = []

    func feed(_ audio: CapturedAudio) async throws {
        if let failOnFeed { throw SpeechError.runtime(failOnFeed) }
        fed.append((
            audio.buffer.format.sampleRate,
            Int(audio.buffer.format.channelCount),
            Int(audio.buffer.frameLength)))
    }

    func mark(_ boundary: SpeechBoundary) async {
        marks.append(boundary)
        markPositions.append(fed.count)
    }

    /// What the pump reported, in the order it reported it. Interleaved with
    /// `received` in the sense that matters: a boundary is recorded only after
    /// the audio it was found in has been fed.
    var marked: [SpeechBoundary] { marks }
    var feedsWhenMarked: [Int] { markPositions }

    func emit(_ event: LiveEvent) {
        if case .final(let segment) = event { finals.append(segment) }
        continuation.yield(event)
    }

    func closeEvents() { continuation.finish() }

    func finish() async throws -> [Segment] {
        continuation.finish()
        return finals
    }

    func cancel() async { continuation.finish() }

    var received: [(rate: Double, channels: Int, frames: Int)] { fed }
}

/// A batch engine that answers with a fixed transcript, optionally after a
/// delay, so the queue's ordering and drain timeout are observable.
final class FakeBatchEngine: TranscriptionEngine, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let capabilities = EngineCapabilities(batch: true)

    private let text: (Int) -> String
    private let delay: Duration
    private let cancellable: Bool
    private let lock = NSLock()
    private var calls = 0

    /// - Parameter cancellable: whether the delay ends early on cancellation.
    ///   Defaults to **false**, which is what a real engine does: CoreML, Metal
    ///   and the Neural Engine do not abandon an inference part way through, so
    ///   `transcribe` returns normally some time after the task was cancelled.
    ///   A `Task.sleep` double has the opposite property, and a queue test built
    ///   on one never reaches the code that handles a late result at all - which
    ///   is how two tests here passed with the behavior they were written for
    ///   removed.
    init(
        id: String = "fake.refiner", delay: Duration = .zero,
        cancellable: Bool = false, text: @escaping (Int) -> String
    ) {
        self.id = id
        self.delay = delay
        self.cancellable = cancellable
        self.text = text
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? {
        nil
    }

    func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
        // `withLock`, not lock/unlock: NSLock's unscoped pair is unavailable in
        // an async context because a suspension between them would hold the
        // lock across a hop.
        let index = lock.withLock { calls += 1; return calls }
        if delay > .zero {
            if cancellable {
                try await Task.sleep(for: delay)
            } else {
                let seconds = Double(delay.components.seconds)
                    + Double(delay.components.attoseconds) / 1e18
                await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                        resume.resume()
                    }
                }
            }
        }
        let string = text(index)
        guard !string.isEmpty else { return [] }
        return [Segment(id: 0, start: 0, end: 1, text: string)]
    }

    func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
        throw SpeechError.unavailable("no live mode")
    }

    func unload() async {}
}

/// A detector that counts what it is handed and reports the boundaries it was
/// built with as the count passes them.
///
/// It answers the only two questions a pump test can ask: did the audio reach
/// the detector at the canonical rate and length, and did what came back reach
/// the session.
actor FakeVoiceActivity: VoiceActivityDetector {
    private let schedule: [SpeechBoundary]
    private let failing: Bool
    private var next = 0
    private(set) var samplesSeen = 0
    private(set) var calls = 0

    init(schedule: [SpeechBoundary] = [], failing: Bool = false) {
        self.schedule = schedule
        self.failing = failing
    }

    func detect(_ samples: [Float]) async throws -> [SpeechBoundary] {
        calls += 1
        if failing { throw SpeechError.runtime("no detector model") }
        samplesSeen += samples.count
        let now = Double(samplesSeen) / AudioDecoder.sampleRate
        var found: [SpeechBoundary] = []
        while next < schedule.count, schedule[next].seconds <= now {
            found.append(schedule[next])
            next += 1
        }
        return found
    }

    func reset() {
        next = 0
        samplesSeen = 0
    }
}

@Suite("Live pump")
struct LivePumpTests {
    @Test("hardware buffers reach the session in the format it asked for")
    func convertsToSessionFormat() async throws {
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        let session = FakeLiveSession(preferredFormat: target)
        let input = AudioFormatConverterTests.tone(rate: 48000, channels: 2, seconds: 0.1)
        let pump = try LivePump(session: session, inputFormat: input.format, audio: nil)

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(CapturedAudio(input))
        continuation.finish()
        try await pump.run(stream)

        let received = await session.received
        #expect(received.count == 1)
        #expect(received.first?.rate == 24000)
        #expect(received.first?.channels == 1)
    }

    @Test("with refinement on, the same audio also lands in the buffer at 16 kHz")
    func fillsRefinementBuffer() async throws {
        let session = FakeLiveSession(preferredFormat: nil)
        let audio = LiveAudioBuffer()
        let input = AudioFormatConverterTests.tone(rate: 48000, channels: 1, seconds: 0.25)
        let pump = try LivePump(session: session, inputFormat: input.format, audio: audio)

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(CapturedAudio(input))
        continuation.finish()
        try await pump.run(stream)

        // A quarter second in, a quarter second stored, at the canonical rate.
        let captured = await audio.capturedSeconds
        #expect(abs(captured - 0.25) < 0.01)
        // And the session still got its own copy, unconverted.
        let received = await session.received
        #expect(received.first?.rate == 48000)
    }

    @Test("a failed refinement conversion keeps the clock aligned")
    func conversionFailureKeepsClock() async throws {
        // Built for 48 kHz stereo, then fed a 44.1 kHz mono buffer: the
        // canonical converter rejects it. The audio is still 0.2 s of wall
        // time, and the refinement buffer has to advance by 0.2 s anyway -
        // skipping it would put its clock permanently behind the session's, and
        // then *every later* slice would hand the refine engine audio offset
        // from the text it is replacing.
        let session = FakeLiveSession(preferredFormat: nil)
        let audio = LiveAudioBuffer()
        let declared = AudioFormatConverterTests.tone(rate: 48000, channels: 2, seconds: 0.2)
        let actual = AudioFormatConverterTests.tone(rate: 44100, channels: 1, seconds: 0.2)

        let warned = CollectingBox()
        let pump = try LivePump(
            session: session, inputFormat: declared.format, audio: audio,
            onConversionFailure: { warned.warn("conversion") })

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(CapturedAudio(actual))
        continuation.finish()
        try await pump.run(stream)

        let captured = await audio.capturedSeconds
        #expect(abs(captured - 0.2) < 0.01, "the clock advanced by the real duration")
        #expect(warned.warnings.count == 1, "and said so once")
    }

    @Test("boundaries reach the session, after the audio they were found in")
    func detectorBoundariesReachTheSession() async throws {
        let session = FakeLiveSession(preferredFormat: nil)
        // Half a second of audio in five buffers, with a boundary in the middle
        // of the third and one in the fifth.
        let vad = FakeVoiceActivity(schedule: [
            SpeechBoundary(kind: .start, seconds: 0.25),
            SpeechBoundary(kind: .end, seconds: 0.45),
        ])
        let input = AudioFormatConverterTests.tone(rate: 16000, channels: 1, seconds: 0.1)
        let pump = try LivePump(
            session: session, inputFormat: input.format, audio: nil, vad: vad)

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        for _ in 0..<5 { continuation.yield(CapturedAudio(input)) }
        continuation.finish()
        try await pump.run(stream)

        #expect(await session.marked == [
            SpeechBoundary(kind: .start, seconds: 0.25),
            SpeechBoundary(kind: .end, seconds: 0.45),
        ])
        // The ordering rule, and it is not cosmetic: a boundary that reached
        // the session before the audio it came from would be honored against a
        // commit watermark that had not seen that audio yet.
        #expect(await session.feedsWhenMarked == [3, 5])
        // Every sample, once, at the canonical rate.
        #expect(await vad.samplesSeen == 5 * 1600)
    }

    @Test("the detector is handed canonical audio, converted once")
    func detectorSeesCanonicalAudio() async throws {
        // 48 kHz stereo in, and the session wants the hardware format, so
        // nothing else on this path needs a conversion. The detector's clock is
        // the count of samples it is given, so a rate of anything but 16 kHz
        // would put every boundary it reports at the wrong moment.
        let session = FakeLiveSession(preferredFormat: nil)
        let vad = FakeVoiceActivity()
        let input = AudioFormatConverterTests.tone(rate: 48000, channels: 2, seconds: 0.1)
        let pump = try LivePump(
            session: session, inputFormat: input.format, audio: nil, vad: vad)

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        for _ in 0..<10 { continuation.yield(CapturedAudio(input)) }
        continuation.finish()
        try await pump.run(stream)

        // One second in. The shortfall is the resampler's delay line filling
        // up: measured here at 475, 987 and 1200 samples for 2, 10 and 40
        // buffers, so it approaches a ceiling rather than accruing per buffer.
        // That is the property worth pinning - a clock losing 475 samples every
        // two buffers would be three seconds behind after a minute, and every
        // boundary would name a moment that had already passed.
        let seen = await vad.samplesSeen
        let shortfall = Int(AudioDecoder.sampleRate) - seen
        #expect(shortfall >= 0)
        #expect(shortfall < 1600, "the clock is behind by \(shortfall) samples")
        #expect(await session.received.first?.rate == 48000, "and the session still got its own")
    }

    @Test("a detector that fails costs boundaries, not the run")
    func detectorFailuresAreNotFatal() async throws {
        // The rule the whole design rests on: the detector is an observer. A
        // session with no boundaries falls back to the rule it would have used
        // anyway, so a broken detector must never cost a transcript.
        let session = FakeLiveSession(preferredFormat: nil)
        let vad = FakeVoiceActivity(failing: true)
        let input = AudioFormatConverterTests.tone(rate: 16000, channels: 1, seconds: 0.1)
        let pump = try LivePump(
            session: session, inputFormat: input.format, audio: nil, vad: vad)

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        for _ in 0..<3 { continuation.yield(CapturedAudio(input)) }
        continuation.finish()
        try await pump.run(stream)

        #expect(await session.received.count == 3, "the audio kept flowing")
        #expect(await session.marked.isEmpty)
        #expect(await vad.calls == 3, "and it was asked every time, not disabled after one failure")
    }

    @Test("a failed conversion keeps the detector's clock aligned too")
    func detectorClockSurvivesAConversionFailure() async throws {
        // Same trap as the refinement buffer, one clock over. The detector
        // counts samples; skipping a buffer it could not convert would put
        // every later boundary earlier than the moment it names, for the rest
        // of the session.
        let session = FakeLiveSession(preferredFormat: nil)
        let vad = FakeVoiceActivity()
        let declared = AudioFormatConverterTests.tone(rate: 48000, channels: 2, seconds: 0.2)
        let actual = AudioFormatConverterTests.tone(rate: 44100, channels: 1, seconds: 0.2)
        let warned = CollectingBox()
        let pump = try LivePump(
            session: session, inputFormat: declared.format, audio: nil, vad: vad,
            onConversionFailure: { warned.warn("conversion") })

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(CapturedAudio(actual))
        continuation.finish()
        try await pump.run(stream)

        let seen = await vad.samplesSeen
        #expect(abs(Double(seen) / AudioDecoder.sampleRate - 0.2) < 0.01)
        #expect(warned.warnings.count == 1)
    }

    @Test("a buffer the session's converter empties still reaches the detector")
    func emptySessionBufferStillFeedsTheDetector() async throws {
        // One frame at 48 kHz is a third of a canonical sample, and the
        // resampler holds it back rather than emitting a partial one. The
        // session gets nothing from that buffer - which is what the old
        // `continue` skipped the rest of the loop for - and the detector still
        // has to see it, or its clock falls behind the audio for the rest of
        // the run.
        let session = FakeLiveSession(preferredFormat: LiveAudioFormat.canonical)
        let vad = FakeVoiceActivity()
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1,
            interleaved: false))
        let pump = try LivePump(session: session, inputFormat: format, audio: nil, vad: vad)
        let single = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        single.frameLength = 1
        single.floatChannelData?[0][0] = 0.5

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(CapturedAudio(single))
        continuation.finish()
        try await pump.run(stream)

        #expect(await session.received.isEmpty, "the converter emitted no frames")
        #expect(await vad.calls == 1, "and the detector was still asked")
    }

    @Test("a pump refuses a second concurrent run")
    func singleRun() async throws {
        let session = FakeLiveSession(preferredFormat: nil)
        let input = AudioFormatConverterTests.tone(rate: 16000, channels: 1, seconds: 0.05)
        let pump = try LivePump(session: session, inputFormat: input.format, audio: nil)

        // A stream that stays open, so the first run is still going.
        let (first, firstContinuation) = AsyncStream<CapturedAudio>.makeStream()
        let running = Task { try await pump.run(first) }
        try await Task.sleep(for: .milliseconds(20))

        let (second, secondContinuation) = AsyncStream<CapturedAudio>.makeStream()
        secondContinuation.finish()
        await #expect(throws: SpeechError.self) {
            try await pump.run(second)
        }

        firstContinuation.finish()
        _ = try await running.value
    }

    @Test("a session that refuses audio stops the pump rather than looping")
    func propagatesFeedFailure() async throws {
        let session = FakeLiveSession(failOnFeed: "the model went away")
        let input = AudioFormatConverterTests.tone(rate: 16000, channels: 1, seconds: 0.05)
        let pump = try LivePump(session: session, inputFormat: input.format, audio: nil)

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(CapturedAudio(input))
        continuation.finish()

        await #expect(throws: SpeechError.self) {
            try await pump.run(stream)
        }
    }
}

@Suite("Refinement queue")
struct RefinementQueueTests {
    static func segment(_ id: Int, start: Double, end: Double) -> Segment {
        Segment(id: id, start: start, end: end, text: "draft \(id)")
    }

    /// Blocks until the engine has actually entered `transcribe`.
    ///
    /// Every test about abandoning an in-flight refinement has to establish
    /// that one *is* in flight, and the only alternative is to guess at
    /// `drain`'s internal poll interval - which is how the first version of
    /// these tests came to fail under a loaded machine and pass on an idle one.
    /// With this, `drain(timeout: .zero)` is exact: it breaks on its first
    /// deadline check, before any sleep, with the item known to be at the
    /// engine.
    static func waitUntilRunning(
        _ engine: FakeBatchEngine, within limit: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: limit)
        while engine.callCount == 0 {
            if ContinuousClock().now >= deadline {
                Issue.record("the refine engine never started")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("each submission comes back with the same id and better text")
    func refines() async throws {
        let engine = FakeBatchEngine { "refined \($0)" }
        let box = CollectingBox()
        let queue = RefinementQueue(
            engine: engine, options: TranscribeOptions(),
            onRefined: { box.add($0) }, onWarning: { message, _ in box.warn(message) })

        await queue.submit(Self.segment(7, start: 0, end: 1), samples: [Float](repeating: 0.1, count: 16000))
        let remaining = await queue.drain(timeout: .seconds(5))

        #expect(remaining == 0)
        #expect(box.segments.count == 1)
        #expect(box.segments.first?.id == 7)
        #expect(box.segments.first?.text == "refined 1")
        // The draft's word timings describe words that are no longer there.
        #expect(box.segments.first?.words == nil)
    }

    @Test("an empty refinement never overwrites real text")
    func discardsEmptyResult() async throws {
        let engine = FakeBatchEngine { _ in "" }
        let box = CollectingBox()
        let queue = RefinementQueue(
            engine: engine, options: TranscribeOptions(),
            onRefined: { box.add($0) }, onWarning: { message, _ in box.warn(message) })

        await queue.submit(Self.segment(1, start: 0, end: 1), samples: [Float](repeating: 0.1, count: 16000))
        _ = await queue.drain(timeout: .seconds(5))

        #expect(box.segments.isEmpty)
        #expect(engine.callCount == 1)
    }

    @Test("submissions are refined one at a time, in order")
    func serialAndOrdered() async throws {
        let engine = FakeBatchEngine(delay: .milliseconds(20)) { "refined \($0)" }
        let box = CollectingBox()
        let queue = RefinementQueue(
            engine: engine, options: TranscribeOptions(),
            onRefined: { box.add($0) }, onWarning: { message, _ in box.warn(message) })

        for id in 1...4 {
            await queue.submit(
                Self.segment(id, start: Double(id), end: Double(id) + 1),
                samples: [Float](repeating: 0.1, count: 1600))
        }
        let remaining = await queue.drain(timeout: .seconds(10))

        #expect(remaining == 0)
        #expect(box.segments.map(\.id) == [1, 2, 3, 4])
        #expect(box.segments.map(\.text) == ["refined 1", "refined 2", "refined 3", "refined 4"])
    }

    @Test("a backlog past the cap is dropped oldest first, with a warning")
    func backlogIsBounded() async throws {
        // A refine engine slow enough that nothing completes while the backlog
        // is being built, so the cap is what decides the outcome.
        let engine = FakeBatchEngine(delay: .seconds(5)) { "refined \($0)" }
        let box = CollectingBox()
        let queue = RefinementQueue(
            engine: engine, options: TranscribeOptions(), backlogSecondsCap: 3,
            onRefined: { box.add($0) }, onWarning: { message, _ in box.warn(message) })

        // Ten one-second utterances into a three-second backlog.
        let oneSecond = [Float](repeating: 0.1, count: Int(AudioDecoder.sampleRate))
        for id in 1...10 {
            await queue.submit(
                Self.segment(id, start: Double(id), end: Double(id) + 1), samples: oneSecond)
        }
        #expect(box.warnings.contains { $0.contains("cannot keep up") })

        // The cap held: nothing like ten seconds of audio is still queued.
        let remaining = await queue.drain(timeout: .milliseconds(200))
        #expect(remaining > 0)
        #expect(remaining <= 4)
    }

    @Test("drain gives up rather than hanging on a stuck engine")
    func drainTimesOut() async throws {
        let engine = FakeBatchEngine(delay: .seconds(5)) { "refined \($0)" }
        let box = CollectingBox()
        let queue = RefinementQueue(
            engine: engine, options: TranscribeOptions(),
            onRefined: { box.add($0) }, onWarning: { message, _ in box.warn(message) })

        await queue.submit(Self.segment(1, start: 0, end: 1), samples: [Float](repeating: 0.1, count: 16000))
        let start = ContinuousClock().now
        let remaining = await queue.drain(timeout: .milliseconds(200))
        let waited = ContinuousClock().now - start

        #expect(remaining == 1)
        #expect(waited < .seconds(5))
    }

    @Test("a drained queue is closed, and says so instead of silently dropping")
    func closedAfterDrain() async throws {
        // A queue is single-use. Ending a run cancels the worker without
        // waiting for the inference inside it, so accepting new work would run
        // a second inference concurrently with the abandoned one - which is
        // exactly what the serial rule exists to prevent, and which the caller
        // would have no way to notice.
        let engine = FakeBatchEngine(delay: .milliseconds(300)) { "refined \($0)" }
        let box = CollectingBox()
        let queue = RefinementQueue(
            engine: engine, options: TranscribeOptions(),
            onRefined: { box.add($0) }, onWarning: { message, _ in box.warn(message) })

        await queue.submit(Self.segment(1, start: 0, end: 1), samples: [Float](repeating: 0.1, count: 16000))
        try await Self.waitUntilRunning(engine)
        let abandoned = await queue.drain(timeout: .zero)
        #expect(abandoned == 1)

        await queue.submit(Self.segment(2, start: 1, end: 2), samples: [Float](repeating: 0.1, count: 16000))
        #expect(box.warnings.contains { $0.contains("already stopped") })
        #expect(engine.callCount == 1, "the closed queue started no second inference")

        // And the abandoned item is not quietly re-popped and dropped either:
        // nothing is published for it, ever.
        #expect(box.segments.isEmpty)
    }

    @Test("nothing is published after the queue has been drained")
    func noPublishAfterDrain() async throws {
        // A refinement that completes after `drain` gave up must not emit: the
        // caller has already counted it as abandoned and may already have
        // emitted `done`, which the applet's poller treats as terminal.
        //
        // The engine's delay is non-cancellable, which is the default here and
        // is what a real one does. With a `Task.sleep` double the worker
        // unwinds through `CancellationError` and the guard under test is never
        // reached at all - the test passes either way and proves nothing.
        let engine = FakeBatchEngine(delay: .milliseconds(300)) { "refined \($0)" }
        let box = CollectingBox()
        let queue = RefinementQueue(
            engine: engine, options: TranscribeOptions(),
            onRefined: { box.add($0) }, onWarning: { message, _ in box.warn(message) })

        await queue.submit(Self.segment(1, start: 0, end: 1), samples: [Float](repeating: 0.1, count: 16000))
        try await Self.waitUntilRunning(engine)
        let abandoned = await queue.drain(timeout: .zero)
        #expect(abandoned == 1)

        // Well past when the engine answers.
        try await Task.sleep(for: .seconds(1))
        #expect(engine.callCount == 1, "the engine did run to completion")
        #expect(box.segments.isEmpty, "but nothing was published")
    }

    @Test("an engine that throws warns and keeps going")
    func survivesFailure() async throws {
        final class Failing: TranscriptionEngine, @unchecked Sendable {
            nonisolated let id = "fake.failing"
            nonisolated let capabilities = EngineCapabilities(batch: true)
            func prepare(language: String?, progress: @escaping LoadProgressHandler) async throws -> String? { nil }
            func transcribe(samples: [Float], options: TranscribeOptions) async throws -> [Segment] {
                throw SpeechError.runtime("out of memory")
            }
            func makeLiveSession(options: TranscribeOptions) async throws -> any LiveSession {
                throw SpeechError.unavailable("no")
            }
            func unload() async {}
        }

        let box = CollectingBox()
        let queue = RefinementQueue(
            engine: Failing(), options: TranscribeOptions(),
            onRefined: { box.add($0) }, onWarning: { message, _ in box.warn(message) })

        await queue.submit(Self.segment(1, start: 0, end: 1), samples: [Float](repeating: 0.1, count: 16000))
        await queue.submit(Self.segment(2, start: 1, end: 2), samples: [Float](repeating: 0.1, count: 16000))
        let remaining = await queue.drain(timeout: .seconds(5))

        #expect(remaining == 0)
        #expect(box.segments.isEmpty)
        #expect(box.warnings.count == 2)
        #expect(box.warnings.allSatisfy { $0.contains("out of memory") })
    }
}

/// Collects callback output from the queue, which fires from its own task.
final class CollectingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Segment] = []
    private var messages: [String] = []

    func add(_ segment: Segment) {
        lock.lock()
        collected.append(segment)
        lock.unlock()
    }

    func warn(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var segments: [Segment] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    var warnings: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
