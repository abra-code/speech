// AudioDecoder.swift - every engine is fed byte-identical audio.
//
// This matters more than it looks. The whole product rests on comparing WER
// between engines, and an engine that resampled with a different filter, or
// that took a different channel of a stereo file, would be measured on
// different audio than its rival. So nothing downstream ever opens a media
// file: AVFoundation decodes, downmixes and resamples once, here, to 16 kHz
// mono Float32, and every backend sees that array. `speech decode` writes the
// same array to a wav so the audio in question can be listened to.
//
// AVFoundation is the only decoder in the tool. That is a decision from part 2
// of the plan (no ffmpeg, no Python), and it costs us webm, mkv, ogg and opus,
// which are reported as unsupported rather than half-handled.

import AVFoundation
import Foundation

public enum AudioDecoder {
    /// Every engine in the catalog wants 16 kHz mono. Not a preference: it is
    /// the native rate of Parakeet, Canary, Whisper and Apple's analyzers.
    public static let sampleRate: Double = 16000

    /// Containers AVFoundation will not open, listed so the error can say what
    /// to do instead of "operation could not be completed".
    private static let knownUnsupportedExtensions: Set<String> = [
        "webm", "mkv", "ogg", "oga", "opus", "flac", "wma", "amr",
    ]

    public static func decode(url: URL) async throws -> [Float] {
        var samples: [Float] = []
        try await readAll(url: url, windowSeconds: 0) { samples.append(contentsOf: $0) }
        return samples
    }

    /// Media duration in seconds, without decoding. Used to size progress bars
    /// and to sanity-check the decoded sample count in tests.
    public static func duration(url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? max(0, seconds) : 0
        } catch {
            throw unsupported(url, underlying: error)
        }
    }

    /// Decode in windows so a three-hour recording never sits in RAM whole.
    /// One hour of 16 kHz Float32 is 230 MB, which is tolerable; three is not,
    /// and the streaming engines want chunks anyway.
    ///
    /// A closure rather than an AsyncStream, and that is the whole point of the
    /// API. `AsyncStream`'s continuation buffers without bound and `yield`
    /// never suspends, so a stream version reads the file to EOF at disk speed
    /// no matter how slowly the consumer works - which is exactly the
    /// full-file footprint this method exists to avoid. Awaiting `body` here
    /// makes the consumer the pacer: memory is one window, whatever it does.
    ///
    /// `seconds <= 0` hands over whatever each read produced, which is what
    /// `decode` uses: it is going to concatenate everything regardless, and
    /// re-chunking first would only copy twice.
    public static func forEachWindow(
        url: URL,
        seconds: Double = 30,
        _ body: ([Float]) async throws -> Void
    ) async throws {
        // Int(seconds * 16000) traps on infinity or anything past about 5.7e14.
        // No caller passes user input today; this is the public API's guard.
        guard seconds.isFinite, seconds < 86_400 else {
            throw SpeechError.usage("window size must be a finite number of seconds under a day")
        }
        try await readAll(url: url, windowSeconds: seconds, emit: body)
    }

    private static func readAll(
        url: URL,
        windowSeconds: Double,
        emit: ([Float]) async throws -> Void
    ) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpeechError.runtime("no such file: \(url.path)")
        }

        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw unsupported(url, underlying: error)
        }
        guard !tracks.isEmpty else {
            throw SpeechError.unsupportedFormat(
                "\(url.lastPathComponent) has no audio track")
        }

        // AVAssetReaderAudioMixOutput over *all* audio tracks, not the first:
        // a QuickTime movie with separate dialogue and music tracks would
        // otherwise lose half its sound. The mix downmixes to our mono output
        // format for free.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw unsupported(url, underlying: error)
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        // We copy the bytes out of every block buffer immediately, so there is
        // no reason to make AVFoundation copy them first.
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SpeechError.unsupportedFormat(
                "cannot decode \(url.lastPathComponent) to 16 kHz mono")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw unsupported(url, underlying: reader.error)
        }
        defer { reader.cancelReading() }

        let windowSamples = windowSeconds > 0 ? Int(windowSeconds * sampleRate) : 0
        var pending: [Float] = []
        if windowSamples > 0 { pending.reserveCapacity(windowSamples) }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount > 0 else { continue }
            let floatCount = byteCount / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: floatCount)
            let status: OSStatus = chunk.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }
                return CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: byteCount, destination: base)
            }
            guard status == kCMBlockBufferNoErr else {
                throw SpeechError.runtime(
                    "failed to read decoded audio from \(url.lastPathComponent) (status \(status))")
            }
            if windowSamples <= 0 {
                try await emit(chunk)
            } else {
                pending.append(contentsOf: chunk)
                while pending.count >= windowSamples {
                    try await emit(Array(pending[0..<windowSamples]))
                    pending.removeFirst(windowSamples)
                }
            }
        }

        if reader.status == .failed {
            throw unsupported(url, underlying: reader.error)
        }
        if !pending.isEmpty {
            try await emit(pending)
        }
    }

    /// Write 16 kHz mono Float32 samples as a wav. Two callers: `speech decode`,
    /// and the Apple engine, which only accepts an AVAudioFile and must be
    /// handed exactly the audio every other engine received rather than opening
    /// the original media itself.
    public static func writeWAV(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false)
        else {
            throw SpeechError.runtime("cannot build a 16 kHz mono audio format")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SpeechError.runtime("cannot write \(url.path): \(error.localizedDescription)")
        }

        // Write in blocks rather than one giant buffer: an hour of audio is a
        // 230 MB allocation that serves no purpose when the file writer is
        // happy with 64k frames at a time.
        let blockFrames = 65536
        var offset = 0
        while offset < samples.count {
            let count = min(blockFrames, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            else {
                throw SpeechError.runtime("cannot allocate an audio buffer")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            guard let destination = buffer.floatChannelData?[0] else {
                throw SpeechError.runtime("audio buffer has no float channel data")
            }
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress! + offset, count: count)
            }
            do {
                try file.write(from: buffer)
            } catch {
                throw SpeechError.runtime("cannot write \(url.path): \(error.localizedDescription)")
            }
            offset += count
        }
    }

    private static func unsupported(_ url: URL, underlying: Error?) -> SpeechError {
        let ext = url.pathExtension.lowercased()
        if knownUnsupportedExtensions.contains(ext) {
            return SpeechError.unsupportedFormat(
                "AVFoundation cannot decode .\(ext) files; convert to wav, m4a, mp3 or mov first")
        }
        let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
        return SpeechError.unsupportedFormat("cannot decode \(url.lastPathComponent)\(detail)")
    }
}
