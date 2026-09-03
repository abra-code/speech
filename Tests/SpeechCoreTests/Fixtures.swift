// Fixtures.swift - media generated at test time rather than committed.
//
// Nothing binary lives in this repository. Audio fixtures are synthesized here,
// which keeps the checkout small, keeps the repo free of samples whose license
// would have to be tracked, and makes the expected values arithmetic rather
// than measured: a three-second 440 Hz tone at 16 kHz is exactly 48000 samples,
// so a decoder that is off by a resampling factor cannot pass.

import AVFoundation
import Foundation
@testable import SpeechCore

enum Fixtures {
    /// One directory per test run, removed by `cleanUp`.
    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanUp(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func sineSamples(seconds: Double, frequency: Double = 440) -> [Float] {
        let count = Int(seconds * AudioDecoder.sampleRate)
        return (0..<count).map { index in
            Float(sin(2 * Double.pi * frequency * Double(index) / AudioDecoder.sampleRate) * 0.5)
        }
    }

    /// A 16 kHz mono Float32 wav, written through the same code path the tool
    /// uses for `speech decode`.
    static func makeWAV(in directory: URL, seconds: Double = 3, name: String = "tone.wav") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try AudioDecoder.writeWAV(samples: sineSamples(seconds: seconds), to: url)
        return url
    }

    /// A compressed, differently-sampled container, so the decoder's resampling
    /// path is exercised rather than a straight byte copy: 44.1 kHz stereo AAC.
    static func makeM4A(in directory: URL, seconds: Double = 3, name: String = "tone.m4a") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)
        else {
            throw SpeechError.runtime("cannot build the fixture format")
        }
        let frames = Int(seconds * 44100)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else {
            throw SpeechError.runtime("cannot allocate the fixture buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            guard let data = buffer.floatChannelData?[channel] else { continue }
            for index in 0..<frames {
                data[index] = Float(sin(2 * Double.pi * 440 * Double(index) / 44100) * 0.5)
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// A QuickTime movie holding both a video track and an audio track, which
    /// is the case that matters: the decoder must find the audio in a file
    /// whose first track is video.
    static func makeMovie(
        in directory: URL, seconds: Double = 3, name: String = "clip.mov"
    ) async throws -> URL {
        let source = try makeWAV(in: directory, seconds: seconds, name: "movie-source.wav")
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 64, height = 64
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        // The movie's sound track is 16-bit LPCM, not AAC. The compressed and
        // resampled path is already covered by the m4a fixture; what this
        // fixture is for is a file whose first track is video, and putting an
        // audio encoder in the way only adds a way for it to fail.
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioDecoder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw SpeechError.runtime("cannot configure the fixture movie writer")
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw SpeechError.runtime("fixture writer refused to start: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        // Collect the audio up front, as LPCM sample buffers re-read from the
        // wav. Handing real buffers to the AAC encoder is simpler and more
        // faithful than synthesizing CMSampleBuffers by hand.
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw SpeechError.runtime("the fixture source wav has no audio track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioDecoder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw SpeechError.runtime("fixture reader refused to start")
        }
        var audioBuffers: [CMSampleBuffer] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            audioBuffers.append(sampleBuffer)
        }

        // Feed both inputs from one loop, taking whichever is ready. An
        // AVAssetWriter interleaves its tracks, so it stops accepting video
        // until the audio catches up: appending every frame first and every
        // sample afterwards deadlocks, which is exactly what the first version
        // of this fixture did.
        let frameRate = 10
        let frameCount = Int(seconds * Double(frameRate))
        var frameIndex = 0
        var audioIndex = 0
        var videoFinished = false
        var audioFinished = false
        var deadline = Date().addingTimeInterval(30)
        while !videoFinished || !audioFinished {
            if writer.status == .failed {
                throw SpeechError.runtime(
                    "fixture writer failed: \(String(describing: writer.error))")
            }
            if Date() > deadline {
                throw SpeechError.runtime(
                    "fixture writer stalled at frame \(frameIndex) of \(frameCount),"
                    + " audio \(audioIndex) of \(audioBuffers.count)")
            }
            var progressed = false
            if frameIndex < frameCount, videoInput.isReadyForMoreMediaData {
                let buffer = try makePixelBuffer(width: width, height: height)
                let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(frameRate))
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw SpeechError.runtime(
                        "cannot append a fixture video frame: \(String(describing: writer.error))")
                }
                frameIndex += 1
                progressed = true
            }
            if audioIndex < audioBuffers.count, audioInput.isReadyForMoreMediaData {
                guard audioInput.append(audioBuffers[audioIndex]) else {
                    throw SpeechError.runtime(
                        "cannot append fixture audio: \(String(describing: writer.error))")
                }
                audioIndex += 1
                progressed = true
            }
            // Mark each input finished the moment its own source runs out,
            // inside the loop rather than after it. The writer holds back one
            // track while it waits for the other to catch up, so an exhausted
            // but unfinished audio input can stall the last video frames
            // forever - which it did, intermittently, under parallel test load.
            if frameIndex >= frameCount, !videoFinished {
                videoInput.markAsFinished()
                videoFinished = true
                progressed = true
            }
            if audioIndex >= audioBuffers.count, !audioFinished {
                audioInput.markAsFinished()
                audioFinished = true
                progressed = true
            }
            if progressed {
                deadline = Date().addingTimeInterval(30)
            } else {
                usleep(2000)
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SpeechError.runtime("fixture movie failed: \(String(describing: writer.error))")
        }
        return url
    }


    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw SpeechError.runtime("cannot create a fixture pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x40, CVPixelBufferGetDataSize(pixelBuffer))
        }
        return pixelBuffer
    }
}
