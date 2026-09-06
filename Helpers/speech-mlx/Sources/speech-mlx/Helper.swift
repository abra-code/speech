// Helper.swift - the loop, and the two things that have to happen before it.
//
// Not main.swift, which would be the obvious name: a file called main.swift is
// a top-level-code file, and Swift refuses `@main` in a module that has one.
//
// The helper is a session: spawned once, loaded once, then a request per
// utterance. A FLEURS split is 647 to 862 utterances and these models take
// around a second to load, so a process per utterance would spend ten minutes
// of every evaluation cell loading weights it already had.
//
// Everything here is sequential on one task, deliberately. `generate` is a
// synchronous call into MLX that does not come back early, so a second
// concurrent request could not be served anyway, and answering strictly in
// order is what lets the parent match replies to requests without a
// correlation table.

import Foundation
import MLX
import SpeechMLXProtocol

@main
enum SpeechMLXHelper {
    static func main() async {
        // Before anything else: the response stream is taken away from every
        // library that might print. See ProtocolIO.swift.
        let out = ProtocolOutput.claimStdout()

        // And before promising anything: prove this build can reach the GPU.
        //
        // mlx-swift's Metal kernels are compiled into a bundle that has to sit
        // beside the binary. Without it the process links, launches, and then
        // dies on its first array operation with "Failed to load the default
        // metallib". A process with no GPU access at all - a restrictive
        // sandbox - dies differently and worse: an uncaught NSRangeException
        // from MTLCopyAllDevices() returning an empty array, which names
        // neither Metal nor a missing file.
        //
        // Neither can be caught and turned into an error event; one is a fatal
        // MLX error and the other an Objective-C exception. What they can be is
        // moved to startup, where the parent sees a helper that died before its
        // handshake rather than a measurement that stopped halfway.
        warmUpMetal()

        out.send(.ready(MLXResponse.Ready(
            helper: HelperVersion.helper,
            mlxAudio: HelperVersion.mlxAudio,
            mlxSwift: HelperVersion.mlxSwift,
            types: ModelSession.implementedTypes)))

        let session = ModelSession()
        var decoder = MLXFrameDecoder()
        let input = FileHandle.standardInput
        // Ending because the parent said so is success; ending because the
        // stream stopped being this protocol's is not, and a caller reading
        // only the exit code should be able to tell them apart.
        var status: Int32 = 0

        reading: while true {
            // A blocking read on the one task this program has. There is no
            // cooperative pool to starve: nothing else runs until a request
            // has been answered.
            let chunk = input.availableData
            if chunk.isEmpty {
                // End of stdin. The parent is gone or said everything it had
                // to say - but "said everything" and "was cut off mid-message"
                // are different endings, and only `finish` can tell them apart.
                // Without this a request whose audio never fully arrived would
                // end the run silently, with no reply and no error.
                do {
                    try decoder.finish()
                } catch {
                    out.send(.failure(MLXResponse.Failure(
                        op: "framing", message: String(describing: error))))
                    status = 1
                }
                break
            }

            // Whatever was whole before a failure comes back with it, so a
            // read that carried two good requests and a corrupt one still
            // answers the two. They are handled first, in order, and only then
            // is the failure reported - a caller waiting on the reply to
            // request five should get it before being told the stream died.
            let batch = decoder.push(chunk)

            for frame in batch.frames {
                let request: MLXRequest
                do {
                    request = try MLXWire.decoder().decode(MLXRequest.self, from: frame.line)
                } catch {
                    // The framing already delimited this message, so the stream
                    // is still readable and the run continues - unlike a
                    // framing error, which cannot know where the next message
                    // starts. But a request this process could not parse is a
                    // protocol violation, and the exit code has to say so or
                    // the claim above about telling the two endings apart is
                    // only true for one of them.
                    out.send(.failure(MLXResponse.Failure(
                        op: "request", message: String(describing: error))))
                    status = 1
                    continue
                }
                // Anything behind `bye` in the same read is dropped, including
                // bytes the decoder is still holding. That is what `bye` means,
                // and docs/mlx-helper.md says so.
                if case .bye = request { break reading }
                await handle(request, payload: frame.payload, session: session, out: out)
            }

            if let failure = batch.failure {
                // The stream is no longer this protocol's. Reporting and
                // exiting beats resynchronizing on a guess about where the next
                // message starts.
                out.send(.failure(MLXResponse.Failure(
                    op: "framing", message: String(describing: failure))))
                status = 1
                break
            }
        }

        session.unload()
        exit(status)
    }

    private static func handle(
        _ request: MLXRequest, payload: Data,
        session: ModelSession, out: ProtocolOutput
    ) async {
        switch request {
        case .load(let load):
            do {
                out.send(.loaded(try await session.load(load)))
            } catch {
                out.send(.failure(MLXResponse.Failure(
                    op: "load", message: String(describing: error))))
            }

        case .transcribe(let transcribe):
            // Two checks before any audio is believed. They are cheap, and
            // each one turns a wrong transcript into a reported error: a short
            // write would otherwise be transcribed as whatever arrived, and a
            // byte count that is not a whole number of samples would shift
            // every sample after it.
            guard payload.count == transcribe.bytes else {
                out.send(.failure(MLXResponse.Failure(
                    op: "transcribe", id: transcribe.id,
                    message: "expected \(transcribe.bytes) bytes of audio, received \(payload.count)")))
                return
            }
            // The multiplication is checked rather than written plainly.
            // `samples` arrives off a pipe, and in Swift a signed overflow is a
            // trap, not a wrong answer - so `samples * 4` on a corrupt or
            // hostile value would take the process down before any of these
            // guards could refuse it. The framing layer caps `bytes`; nothing
            // caps `samples` but this.
            let (expected, overflowed) = transcribe.samples.multipliedReportingOverflow(
                by: MemoryLayout<Float>.size)
            guard transcribe.samples >= 0, !overflowed, transcribe.bytes == expected,
                  let samples = MLXFrameWriter.samples(from: payload)
            else {
                out.send(.failure(MLXResponse.Failure(
                    op: "transcribe", id: transcribe.id,
                    message: "\(transcribe.bytes) bytes is not \(transcribe.samples) Float32 samples")))
                return
            }
            do {
                let result = try session.transcribe(transcribe, samples: samples)
                for segment in result.segments { out.send(.segment(segment)) }
                out.send(.done(result.done))
            } catch {
                out.send(.failure(MLXResponse.Failure(
                    op: "transcribe", id: transcribe.id, message: String(describing: error))))
            }

        case .unload:
            session.unload()
            out.send(.ok(MLXResponse.Ok(op: "unload")))

        case .bye:
            break  // handled by the caller, which has to stop reading
        }
    }

    /// The smallest operation that forces the Metal device to exist.
    private static func warmUpMetal() {
        let probe = MLXArray([1, 2, 3] as [Int32])
        let sum = (probe * probe).sum().item(Int32.self)
        precondition(sum == 14, "MLX returned \(sum) for a sum that is 14")
        MLX.Memory.clearCache()
    }
}
