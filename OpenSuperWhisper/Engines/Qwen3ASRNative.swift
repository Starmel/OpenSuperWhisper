import Foundation

/// The C bridge behind the Qwen3-ASR engine, in Swift's terms.
///
/// The engine holds one of these for its lifetime. Everything here is a
/// translation: the weights' two paths in, the app's `Error` type out, and one
/// heap string copied into a Swift `String` on the way back.
final class Qwen3ASRNative {
    enum NativeError: Error, LocalizedError {
        /// `osw_qwen3asr_load` failed, with the bridge's own message (which
        /// names the file and what was wrong with it).
        case load(String)
        /// A transcription failed — the model's message, or "cancelled" when the
        /// engine's own cancellation stopped it.
        case transcribe(String)

        var errorDescription: String? {
            switch self {
            case .load(let message): return message
            case .transcribe(let message): return message
            }
        }
    }

    /// The rate the bridge wants its samples at — 16 kHz for Qwen3-ASR. Zero
    /// before the engine is loaded.
    let sampleRate: Int

    private var handle: UnsafeMutableRawPointer?

    /// Loads both halves of the engine. The model is ~2.5 GB; the call blocks
    /// for seconds, so it belongs off the main actor (the engine loads in a
    /// detached task).
    init(textModelPath: String, projectorPath: String, threadCount: Int) throws {
        var error: UnsafeMutablePointer<CChar>?
        let loaded: UnsafeMutableRawPointer? = textModelPath.withCString { text in
            projectorPath.withCString { projector in
                osw_qwen3asr_load(text, projector, Int32(threadCount), &error)
            }
        }
        guard let loaded else {
            throw NativeError.load(Self.consume(error) ?? "The Qwen3-ASR engine could not be loaded.")
        }
        handle = loaded
        sampleRate = Int(osw_qwen3asr_audio_sample_rate(loaded))
    }

    deinit {
        osw_qwen3asr_free(handle)
    }

    var isLoaded: Bool { handle != nil }

    /// One utterance. `samples` must be mono float PCM at `sampleRate`.
    ///
    /// `language` is a hint the model was not asked for: Qwen3-ASR detects the
    /// language of the audio itself, so the engine passes `nil` and lets it.
    func transcribe(samples: [Float], language: String? = nil) throws -> String {
        guard let handle else {
            throw NativeError.load("The Qwen3-ASR engine is not loaded.")
        }
        guard samples.count <= Int(Int32.max) else {
            throw NativeError.transcribe("This recording is too long for the Qwen3-ASR engine.")
        }

        var error: UnsafeMutablePointer<CChar>?
        let text: UnsafeMutablePointer<CChar>? = samples.withUnsafeBufferPointer { buffer in
            if let language {
                return language.withCString { hint in
                    osw_qwen3asr_transcribe(handle, buffer.baseAddress, Int32(buffer.count), hint, &error)
                }
            }
            return osw_qwen3asr_transcribe(handle, buffer.baseAddress, Int32(buffer.count), nil, &error)
        }

        guard let text else {
            throw NativeError.transcribe(Self.consume(error) ?? "The Qwen3-ASR transcription failed.")
        }
        defer { osw_qwen3asr_string_free(text) }
        return String(cString: text)
    }

    /// Asks the decode in flight to stop. Returns immediately; the decode fails
    /// with the bridge's "cancelled" message.
    func cancel() {
        osw_qwen3asr_cancel(handle)
    }

    /// Frees the weights. Idempotent, and the engine reloads on the next use.
    func unload() {
        osw_qwen3asr_free(handle)
        handle = nil
    }

    /// Copies a string the bridge allocated and frees the original.
    private static func consume(_ text: UnsafeMutablePointer<CChar>?) -> String? {
        guard let text else { return nil }
        defer { osw_qwen3asr_string_free(text) }
        return String(cString: text)
    }
}
