import Foundation
import AVFoundation

/// Live, "pipelined" transcription: audio is fed to whisper incrementally while it is
/// still being recorded, driving whisper's own 30s-window seek loop via the resumable API
/// (`whisper_append_audio` + `whisper_full_resumable`). Work overlaps with recording, so
/// when the user stops only the trailing (<30s) window remains to decode.
///
/// This is NOT word-by-word real-time: whisper needs a full 30s window before it emits a
/// block, so committed text advances roughly every ~30s of speech. The benefit is "near
/// instant on stop" while keeping full large-model quality.
///
/// Quality vs. mel normalization:
///  - `.global` is byte-identical to a single `whisper_full()` pass (batch quality).
///  - `.window` is an envelope-follower AGC meant for live audio (prevents silence from
///    amplifying background noise). Recommended default for the live mic path.
///
/// NOTE: this engine is self-contained and does not flow through the file-based
/// `TranscriptionEngine` protocol. It is driven directly by the recording layer.
///
/// It is a shared singleton with ONE serial whisper queue. That single queue is also
/// what guarantees ordering across back-to-back recordings: appends, finalizes and resets
/// all run in FIFO order, so recordings are transcribed (and therefore inserted) strictly
/// in the order they were made. The model is loaded once.
final class StreamingWhisperEngine {

    static let shared = StreamingWhisperEngine()
    private init() {}

    enum MelNormMode: Int32 {
        case global = 0
        case window = 1
    }

    /// Mel normalization for the live path. `.window` is recommended for mic input.
    var melNormMode: MelNormMode = .window
    /// WINDOW-mode release half-life in seconds of audio time (ignored for `.global`).
    var melNormHalfLife: Float = 2.0

    private var context: MyWhisperContext?

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000,
                                             channels: 1,
                                             interleaved: false)

    // All whisper calls (append + resumable) are serialized here; they must never run
    // concurrently on the same context, and must never run on the audio render thread.
    private let whisperQueue = DispatchQueue(label: "streaming.whisper", qos: .userInitiated)

    private var settings = Settings()
    private var committedSegments = 0
    private var runningText = ""
    private var isRunning = false
    private var isCancelled = false

    var isModelLoaded: Bool { context != nil }

    // MARK: - Lifecycle

    /// Optional preload so the model is hot before the first recording.
    func initialize() throws {
        var thrown: Error?
        whisperQueue.sync {
            do { try self.loadContextIfNeeded() } catch { thrown = error }
        }
        if let thrown = thrown { throw thrown }
    }

    /// Loads the whisper context if not already loaded. Must run on whisperQueue.
    private func loadContextIfNeeded() throws {
        if context != nil { return }
        let modelPath = AppPreferences.shared.selectedWhisperModelPath ?? AppPreferences.shared.selectedModelPath
        guard let modelPath = modelPath else {
            throw TranscriptionError.contextInitializationFailed
        }
        let params = WhisperContextParams()
        guard let ctx = MyWhisperContext.initFromFile(path: modelPath, params: params) else {
            throw TranscriptionError.contextInitializationFailed
        }
        context = ctx
    }

    /// Begin capturing from the default input and transcribing live. Returns
    /// immediately; the model may still be loading — captured audio is buffered on
    /// the serial whisper queue, so no lead-in is lost.
    func start(settings: Settings) throws {
        guard !isRunning else { return }

        self.settings = settings
        self.isCancelled = false

        let input = audioEngine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        guard let targetFormat = targetFormat,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw TranscriptionError.audioConversionFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        self.converter = converter

        // Queue the (possibly slow) model load + reset FIRST. Because whisperQueue is
        // serial, this runs only after any previous recording's finalize has completed
        // (so the previous result is captured before we reset), and audio appended by
        // the tap below is processed only after this block — recording starts instantly
        // without dropping the lead-in, and ordering across recordings is preserved.
        whisperQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.loadContextIfNeeded()
            } catch {
                print("Streaming model load failed: \(error)")
                return
            }
            self.committedSegments = 0
            self.runningText = ""
            self.context?.resumableReset()
        }

        // ~100ms buffers. The tap runs on the audio render thread: do the cheap
        // format conversion here, then hand the samples to the whisper queue.
        let tapBufferSize: AVAudioFrameCount = 4800
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.handleIncoming(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
    }

    /// Stop capturing, flush the trailing window, and return the final transcription.
    func stop() -> String {
        guard isRunning else { return finalText() }
        isRunning = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        guard !isCancelled else { return finalText() }

        // Runs after all queued appends, so the whole recording is accounted for. The
        // final text is captured INSIDE the sync block so the next recording's reset
        // (also queued) can't clear it first.
        var captured = ""
        whisperQueue.sync {
            guard let context = self.context else { return }
            var params = self.makeParams()
            // finalize = true: decode the remaining <30s window (padded), like the last
            // iteration of whisper_full's internal loop.
            let nNew = context.fullResumable(params: &params, finalize: true)
            if nNew > 0 {
                self.appendNewSegments(from: context)
            }
            captured = self.finalText()
        }
        return captured.isEmpty ? "No speech detected in the audio" : captured
    }

    func cancel() {
        isCancelled = true
        if isRunning {
            isRunning = false
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }

    // MARK: - Audio pipeline

    private func handleIncoming(buffer: AVAudioPCMBuffer) {
        guard let converter = converter, let targetFormat = targetFormat, !isCancelled else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        outBuffer.frameLength = 0
        converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
        if convError != nil { return }

        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let channel = outBuffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: frames))

        // Hand off to the serialized whisper queue. Appends are cheap; the expensive
        // decode only happens inside fullResumable once a full 30s window is available.
        whisperQueue.async { [weak self] in
            guard let self = self, let context = self.context, !self.isCancelled else { return }
            _ = context.appendAudio(samples: samples)

            var params = self.makeParams()
            let nNew = context.fullResumable(params: &params, finalize: false)
            if nNew > 0 {
                self.appendNewSegments(from: context)
            }
        }
    }

    // MARK: - Results

    /// Reads segments [committedSegments ..< total) and appends them to runningText.
    /// Must be called on whisperQueue.
    private func appendNewSegments(from context: MyWhisperContext) {
        let total = context.fullNSegments
        guard total > committedSegments else { return }

        for i in committedSegments..<total {
            guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }
            if settings.showTimestamps {
                let t0 = context.fullGetSegmentT0(iSegment: i)
                let t1 = context.fullGetSegmentT1(iSegment: i)
                runningText += String(format: "[%.1f->%.1f] ", Float(t0) / 100.0, Float(t1) / 100.0)
            }
            runningText += segmentText
        }
        committedSegments = total
    }

    private func finalText() -> String {
        let text = cleaned(runningText)
        return text.isEmpty ? "No speech detected in the audio" : text
    }

    private func cleaned(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.shouldApplyAsianAutocorrect && !result.isEmpty {
            result = AutocorrectWrapper.format(result)
        }
        return result
    }

    // MARK: - Params

    private func makeParams() -> whisper_full_params {
        let nThreads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

        var params = WhisperFullParams()
        params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
        params.nThreads = Int32(nThreads)
        params.noTimestamps = !settings.showTimestamps
        params.suppressBlank = settings.suppressBlankAudio
        params.translate = settings.translateToEnglish
        let isAutoDetect = settings.selectedLanguage == "auto"
        params.language = isAutoDetect ? nil : settings.selectedLanguage
        params.detectLanguage = false
        params.temperature = Float(settings.temperature)
        params.noSpeechThold = Float(settings.noSpeechThreshold)
        params.initialPrompt = settings.initialPrompt.isEmpty ? nil : settings.initialPrompt
        if settings.useBeamSearch {
            params.beamSearchBeamSize = Int32(settings.beamSize)
        }

        // The resumable API manages cross-window seek + context itself, so we don't
        // print realtime or feed prompt tokens manually.
        params.printRealtime = false
        params.print_realtime = false

        params.melNormMode = melNormMode.rawValue
        params.melNormHalfLife = melNormHalfLife

        return params.toC()
    }
}
