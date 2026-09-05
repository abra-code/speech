// Microphone.swift - live audio in: pick an input device, tap it, and hand
// private copies of its buffers to whoever asked.
//
// Everything here is the *capture* half of stage 4 and knows nothing about
// transcription. That separation is what lets `speech stream` drive an Apple
// module, a FluidAudio pipeline and a ggml stream through one code path: no
// engine ever sees an AVAudioEngine, and this file never sees an engine.
//
// Three things are less obvious than they look.
//
// Format. The hardware picks its own rate and channel count and will not be
// argued with - a MacBook's built-in microphone commonly runs 48 kHz mono, an
// aggregate device can be 44.1 kHz with eight channels. Every engine wants
// something else. So the tap is installed with `format: nil` (the node's own
// format, the only one guaranteed to be accepted) and the *consumer* converts,
// through `AudioFormatConverter`. Conversion deliberately does not happen here:
// a run with `--refine` needs the same audio in two formats at once, and
// AVAudioConverter is stateful and has no business on a real-time thread.
//
// Ownership. The buffer a tap block receives belongs to the engine and is
// reused as soon as the block returns. Handing it onward would be a data race
// against the audio thread with no diagnostic - the text would just be wrong
// occasionally. Every buffer that leaves this file is a fresh allocation.
//
// Permission. Microphone access is granted to the *responsible* process, not to
// this binary: run from a terminal it is the terminal that gets asked and the
// terminal that appears in System Settings, and from the applet it is the
// applet (which is why the app has to carry NSMicrophoneUsageDescription).
// A denied prompt is reported as `unavailable` with that explanation, because
// "no audio arrived" is otherwise indistinguishable from a silent room.

import AVFoundation
import Foundation

#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

/// One selectable audio input, as `speech stream --device` names them.
public struct AudioInputDevice: Sendable, Equatable {
    /// CoreAudio's `AudioDeviceID`. Not stable across reboots or replugs, which
    /// is why `--device` takes a name and this is resolved fresh each run.
    public var id: UInt32
    /// The device's persistent UID. Stable across reboots, so it is also
    /// accepted by `--device` for scripts that need to be exact.
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var sampleRate: Double

    public init(id: UInt32, uid: String, name: String, inputChannels: Int, sampleRate: Double) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.sampleRate = sampleRate
    }
}

public enum AudioInput {
    #if os(macOS)

    /// Every device with at least one input channel, in CoreAudio's order.
    ///
    /// Output-only devices are filtered out by asking for the input stream
    /// configuration rather than by name: "MacBook Pro Speakers" is obvious,
    /// but a Blackhole or an aggregate can be either or both, and only the
    /// channel count settles it.
    public static func devices() -> [AudioInputDevice] {
        ids().compactMap { device(id: $0) }
    }

    public static func defaultInputDeviceID() -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Resolves what the user typed after `--device`.
    ///
    /// Matching is deliberately layered and stops at the first layer that finds
    /// anything: UID, then exact name, then case-insensitive name, then a
    /// unique case-insensitive substring. A substring that matches two devices
    /// is an error naming both rather than a silent pick, because the two are
    /// often "MacBook Pro Microphone" and "MacBook Pro Microphone (2)" on a
    /// machine with a dock, and recording from the wrong one is invisible until
    /// the transcript comes back empty.
    public static func resolve(device query: String) throws -> AudioInputDevice {
        guard !query.isEmpty else {
            throw SpeechError.usage("--device needs a device name or UID")
        }
        let all = devices()
        guard !all.isEmpty else {
            throw SpeechError.unavailable("no audio input devices are present")
        }
        // The UID test excludes the empty string on purpose: a device whose UID
        // cannot be read is stored with `uid == ""`, and `--device ""` would
        // otherwise silently select whichever one that is.
        if let match = all.first(where: { !$0.uid.isEmpty && $0.uid == query }) { return match }
        if let match = all.first(where: { $0.name == query }) { return match }

        let lowered = query.lowercased()
        let exact = all.filter { $0.name.lowercased() == lowered }
        if exact.count == 1 { return exact[0] }
        let partial = exact.isEmpty
            ? all.filter { $0.name.lowercased().contains(lowered) }
            : exact
        switch partial.count {
        case 1:
            return partial[0]
        case 0:
            throw SpeechError.usage(
                "no audio input device matches '\(query)'."
                + " Available: \(all.map(\.name).joined(separator: ", "))")
        default:
            throw SpeechError.usage(
                "'\(query)' matches \(partial.count) input devices"
                + " (\(partial.map(\.name).joined(separator: ", ")));"
                + " name one exactly or use its UID")
        }
    }

    // MARK: - CoreAudio plumbing

    private static func ids() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func device(id: AudioDeviceID) -> AudioInputDevice? {
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        return AudioInputDevice(
            id: id,
            uid: string(id, selector: kAudioDevicePropertyDeviceUID) ?? "",
            name: string(id, selector: kAudioObjectPropertyName) ?? "device \(id)",
            inputChannels: channels,
            sampleRate: nominalSampleRate(id))
    }

    /// Sums the channels across every input stream. The buffer list is
    /// variable-length, so it is read into raw bytes and walked through
    /// `UnsafeMutableAudioBufferListPointer`, which is the only correct way to
    /// index past the first buffer of an `AudioBufferList`.
    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    #else

    public static func devices() -> [AudioInputDevice] { [] }
    public static func defaultInputDeviceID() -> UInt32? { nil }
    public static func resolve(device query: String) throws -> AudioInputDevice {
        throw SpeechError.unavailable("device selection needs macOS")
    }

    #endif
}

/// Converts capture buffers into the format a live session asked for.
///
/// Split out from `Microphone` so it can be tested without a microphone: every
/// resampling bug this could have is reachable from a synthetic buffer, and
/// none of them are reachable from a unit test that needs hardware and a TCC
/// grant.
public final class AudioFormatConverter {
    public let source: AVAudioFormat
    public let target: AVAudioFormat
    private let converter: AVAudioConverter

    public init(from source: AVAudioFormat, to target: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw SpeechError.unsupportedFormat(
                "cannot convert \(Self.describe(source)) to \(Self.describe(target))")
        }
        self.source = source
        self.target = target
        self.converter = converter
    }

    /// One input buffer to one output buffer.
    ///
    /// The input block is the "one-shot" pattern AVAudioConverter requires for
    /// this style of use: hand over the source buffer exactly once, then answer
    /// `.noDataNow` forever. Returning the same buffer twice makes the
    /// converter loop on stale audio; returning `.endOfStream` tears down the
    /// converter's state and the *next* call resamples from a cold start,
    /// which puts a click at every buffer boundary.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        // Round up, then leave real headroom. Two separate reasons:
        //
        // A rate ratio that is not exact - 48000 to 16000 is, 44100 to 16000 is
        // not - can put the output one frame past the floor of the ratio, and
        // an undersized buffer truncates silently rather than failing.
        //
        // More importantly the resampler carries a filter delay. Measured on
        // this SDK, converting 48 kHz stereo to 16 kHz mono in 0.5 s buffers,
        // the first call yields about 1180 frames less than the arithmetic says
        // and the converter keeps them. Nothing is lost - they come out later -
        // but with a capacity sized exactly, "later" is one frame per call and
        // the stream runs a permanent 74 ms behind. Headroom lets that backlog
        // flush in the next call or two instead.
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            + Self.headroom
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw SpeechError.runtime("cannot allocate a \(capacity)-frame conversion buffer")
        }

        // AVAudioConverter's input block is `@Sendable`, so the "hand the
        // source buffer over exactly once" state cannot live in captured
        // locals. It lives in a box instead, which is safe for the reason the
        // box says: `convert` calls the block synchronously, on this thread,
        // before it returns.
        let input = OneShotInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            input.next(outStatus)
        }

        switch status {
        case .haveData, .inputRanDry:
            return output
        case .endOfStream:
            // Unreachable as written: `OneShotInput` only ever answers
            // `.haveData` then `.noDataNow`, and measurement across 48k and
            // 44.1k sources at four buffer sizes never produced this. Kept
            // rather than trapped, and returning `output` untouched rather than
            // zeroing it, because zeroing would throw away frames the converter
            // had already written. The caller drops an empty buffer anyway.
            return output
        case .error:
            throw SpeechError.runtime(
                "audio conversion failed: \(conversionError?.localizedDescription ?? "unknown")")
        @unknown default:
            throw SpeechError.runtime("audio conversion returned an unknown status")
        }
    }

    /// A private copy of a capture buffer.
    ///
    /// Copied through the `AudioBufferList` rather than through
    /// `floatChannelData` and friends, because those accessors only exist for
    /// the formats they name. A device presenting packed 24-bit integers - which
    /// several USB interfaces and virtual drivers do - has `commonFormat ==
    /// .otherFormat` and returns nil from all three, and a copy written against
    /// them would fail on every buffer and produce a session that looks live and
    /// is silent. Walking the buffer list and copying `mDataByteSize` per buffer
    /// works for every PCM layout, interleaved or planar, whatever the sample
    /// type, and is shorter besides.
    public static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: max(1, buffer.frameLength))
        else { return nil }
        // Before the copy: setting `frameLength` is what sizes each
        // `mDataByteSize` in the destination list.
        copy.frameLength = buffer.frameLength
        guard buffer.frameLength > 0 else { return copy }

        // The source is read through the read-only accessor: nothing here
        // writes to it, and asking for the mutable one would say otherwise.
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for index in 0..<source.count {
            guard let from = source[index].mData, let to = target[index].mData else { return nil }
            let bytes = min(Int(source[index].mDataByteSize), Int(target[index].mDataByteSize))
            to.copyMemory(from: from, byteCount: bytes)
        }
        return copy
    }

    /// Holds the source buffer for AVAudioConverter's `@Sendable` input block.
    ///
    /// `@unchecked Sendable` because the block is not concurrent at all: the
    /// converter invokes it synchronously from `convert`, on the calling
    /// thread, and never retains it. The box exists only to satisfy the
    /// closure's `Sendable` requirement without moving the state somewhere it
    /// would outlive the call.
    private final class OneShotInput: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var handed = false

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        /// The source buffer once, then nothing.
        ///
        /// `.noDataNow` and not `.endOfStream` for the second and later calls:
        /// end-of-stream tears down the converter's internal state, so the next
        /// `convert` on the same instance would resample from a cold start and
        /// put a click at every buffer boundary.
        func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if handed {
                outStatus.pointee = .noDataNow
                return nil
            }
            handed = true
            outStatus.pointee = .haveData
            return buffer
        }
    }

    /// Extra output frames per conversion, to let the resampler's delay line
    /// drain. 4096 frames is 256 ms at 16 kHz and 16 KB of memory.
    private static let headroom: AVAudioFrameCount = 4096

    static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Hz / \(format.channelCount) ch"
    }
}

/// The 16 kHz mono Float32 format the whole project measures on. Any engine
/// that has no opinion gets this, so a live run is fed the same audio shape a
/// batch run would have been.
public enum LiveAudioFormat {
    public static var canonical: AVAudioFormat {
        // `commonFormat: .pcmFormatFloat32, interleaved: false` is the only
        // layout every consumer here reads, and the initializer is
        // non-failing for these arguments.
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioDecoder.sampleRate,
            channels: 1,
            interleaved: false)!
    }

    /// Flattens a buffer to the mono Float32 array the engines take.
    /// Multi-channel input is averaged rather than left-channel-only: a stereo
    /// interface with the microphone on the right channel would otherwise
    /// record silence.
    public static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return [] }
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        if buffer.stride == 1 {
            // Non-interleaved: one pointer per channel.
            var mixed = [Float](repeating: 0, count: frames)
            for channel in 0..<channels {
                let source = data[channel]
                for frame in 0..<frames { mixed[frame] += source[frame] }
            }
            let scale = 1 / Float(channels)
            for frame in 0..<frames { mixed[frame] *= scale }
            return mixed
        }
        // Interleaved: one pointer, `channels` values per frame.
        let source = data[0]
        var mixed = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += source[frame * channels + channel] }
            mixed[frame] = sum * scale
        }
        return mixed
    }
}

#if os(macOS)

/// A running microphone tap.
///
/// `@unchecked Sendable` because every stored property is read and written
/// under `lock`, and the tap block runs on a real-time audio thread that cannot
/// await anything. That thread does allocate (one buffer per callback) and does
/// take a lock (`AsyncStream.yield`, downstream, takes one of its own), which is
/// not textbook real-time discipline; it is the same trade every AVAudioEngine
/// tap in a transcription tool makes, and it is why the queue downstream drops
/// rather than blocks. What is deliberately kept off this thread is the thing
/// with unbounded cost: `AVAudioConverter`.
public final class Microphone: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// `--device`: a UID, an exact name, or an unambiguous substring.
        /// nil means the system default input.
        public var device: String?
        /// Frames per tap callback. 4096 at 48 kHz is about 85 ms, which is
        /// short enough that a partial result feels live and long enough that
        /// the conversion is not called thousands of times a second.
        public var bufferSize: AVAudioFrameCount

        public init(device: String? = nil, bufferSize: AVAudioFrameCount = 4096) {
            self.device = device
            self.bufferSize = bufferSize
        }
    }

    /// What the tap actually opened, so the caller can report it and a
    /// measurement can record it. Valid after `start` returns.
    public var selectedDevice: AudioInputDevice? {
        lock.lock()
        defer { lock.unlock() }
        return openedDevice
    }

    public var inputFormat: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return openedFormat
    }

    private var openedDevice: AudioInputDevice?
    private var openedFormat: AVAudioFormat?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    /// The failure slot has its own lock, and that is not tidiness.
    ///
    /// It is written from the real-time audio thread. `stop()` has to call
    /// `removeTap` and `engine.stop()`, both of which wait for the render cycle
    /// in progress to return. If those two shared a lock, `stop()` could take
    /// it, wait for a render cycle that is itself blocked trying to take it, and
    /// hang with the microphone open - which is precisely the failure the stop
    /// path exists to prevent.
    private let failureLock = NSLock()
    private var running = false
    /// Set from the audio thread when a conversion throws, read by the owner.
    /// The tap cannot propagate an error, and a stream that has silently
    /// stopped delivering audio must not look like a quiet room.
    private var failure: String?

    public init() {}

    /// Whether this process may record, asking the user if it has not been
    /// asked before.
    ///
    /// The prompt names the responsible process, which from a terminal is the
    /// terminal. Nothing here can change that; the message when it fails says
    /// so, so a person can find the right row in System Settings.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Opens the device, installs the tap and starts the engine.
    ///
    /// Buffers are delivered in the *hardware's* format, as private copies.
    /// Conversion is deliberately not done here: a live run with `--refine`
    /// needs the same audio in two formats (the session's and the project's
    /// canonical 16 kHz mono), and a tap that can produce one of them would
    /// have to be taught to produce two. Doing it in the consumer also keeps
    /// `AVAudioConverter` - which is stateful and not thread-safe - off the
    /// real-time audio thread.
    /// - Parameter onFailure: called at most once, from the audio thread, when a
    ///   buffer cannot be copied. It must end the run. Without it the tap simply
    ///   stops delivering: the session stays open, no partial ever appears, and
    ///   the reason surfaces only when the user gives up and stops - after
    ///   speaking into what looked like a working recorder.
    public func start(
        configuration: Configuration = Configuration(),
        onFailure: (@Sendable (String) -> Void)? = nil,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw SpeechError.runtime("the microphone is already running") }

        let input = engine.inputNode

        // The device has to be chosen before the node's format is read: the
        // format belongs to the device, and reading it first then switching
        // would report the wrong hardware to the caller.
        if let requested = configuration.device {
            let device = try AudioInput.resolve(device: requested)
            do {
                try input.auAudioUnit.setDeviceID(AudioObjectID(device.id))
            } catch {
                throw SpeechError.unavailable(
                    "cannot record from '\(device.name)': \(error.localizedDescription)")
            }
            openedDevice = device
        } else if let id = AudioInput.defaultInputDeviceID() {
            openedDevice = AudioInput.devices().first { $0.id == id }
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechError.unavailable(
                "the input device reports no usable format;"
                + " check that microphone access is granted to the app running this tool")
        }
        openedFormat = format

        // `format: nil` asks for the node's own format. Passing a format the
        // hardware does not produce is the classic way to get a -10868 at
        // `installTap` time or, worse, silence.
        input.installTap(onBus: 0, bufferSize: configuration.bufferSize, format: nil) {
            [weak self] buffer, _ in
            guard let self else { return }
            guard let copy = AudioFormatConverter.copy(buffer) else {
                let message = "cannot read audio from this input device"
                    + " (\(Int(buffer.format.sampleRate)) Hz,"
                    + " \(buffer.format.channelCount) ch,"
                    + " sample format \(buffer.format.commonFormat.rawValue))"
                if self.recordFailure(message) { onFailure?(message) }
                return
            }
            guard copy.frameLength > 0 else { return }
            handler(copy)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SpeechError.unavailable(
                "cannot start audio capture: \(error.localizedDescription)."
                + " If this is a permission problem, grant microphone access to the app"
                + " running this tool in System Settings > Privacy & Security > Microphone.")
        }
        running = true
    }

    /// Stops the tap. Idempotent, and safe to call from a signal-driven path.
    ///
    /// The lock is released before the engine is touched. `removeTap` and
    /// `stop` both synchronize with the render thread, and holding a lock
    /// across them that the render thread might also want is a deadlock waiting
    /// for the right interleaving. Flipping `running` first is also what makes
    /// this idempotent under a concurrent second call.
    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The first error the tap hit, if any. Cleared by reading it, so a caller
    /// polling this reports each failure once.
    public func takeFailure() -> String? {
        failureLock.lock()
        defer { failureLock.unlock() }
        defer { failure = nil }
        return failure
    }

    /// Records the first failure and says whether it was the first, so the
    /// caller's `onFailure` fires once rather than on every buffer.
    @discardableResult
    private func recordFailure(_ message: String) -> Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        guard failure == nil else { return false }
        failure = message
        return true
    }
}

#endif
