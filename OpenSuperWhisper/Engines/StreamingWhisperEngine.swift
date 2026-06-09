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
/// It is a shared singleton with ONE whisper context and ONE serial whisper queue, so it
/// handles a single recording at a time. Back-to-back recordings are serialized: the engine
/// graph is guarded by `engineLock`, and a recording's finalize is enqueued (under that lock)
/// before the next recording's reset is enqueued — so appends/finalizes/resets run in FIFO
/// order and a recording's text is captured before the next one resets the context. The
/// model is loaded once.
final class StreamingWhisperEngine {

    static let shared = StreamingWhisperEngine()
    private init() {}

    enum MelNormMode: Int32 {
        case global = 0
        case window = 1
    }

    /// Outcome of finalizing a streaming session.
    enum FinalizeResult {
        /// Streaming ran; the text is the transcription (may be a "no speech" placeholder).
        case transcribed(String)
        /// Streaming could never run (no model / mic / start error). The caller should
        /// fall back to a file-based transcription so the recording is not lost.
        case unavailable
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

    // Touched only on whisperQueue (serialized) — no lock needed.
    private var settings = Settings()
    private var committedSegments = 0
    private var runningText = ""

    // Touched from multiple threads (caller, audio render thread, main) — lock-guarded.
    private let stateLock = NSLock()
    private var _isRunning = false
    private var _isCancelled = false
    private var isRunning: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRunning }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isRunning = newValue }
    }
    private var isCancelled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isCancelled }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isCancelled = newValue }
    }

    private let tapBufferSize: AVAudioFrameCount = 4800 // ~100ms
    private var configObserver: NSObjectProtocol?

    // Serializes all AVAudioEngine graph mutations (start/stop/tap/converter/observer) AND the
    // whisperQueue submission of a recording's reset/finalize. This prevents an overlapping
    // start (recording B) and stop (recording A) from (1) touching the shared engine
    // concurrently — CoreAudio is not safe for that — or (2) reordering B's reset ahead of
    // A's finalize on the whisper queue (which would clear A's text before it is captured).
    // It is held only across the brief engine mutation / enqueue, NEVER across the whisper
    // decode, so B's capture is not delayed by A's finalize.
    private let engineLock = NSLock()

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
        engineLock.lock()
        defer { engineLock.unlock() }

        guard !isRunning else { return }

        // isCancelled is read on the audio thread before dispatching; clear it up front.
        self.isCancelled = false

        // Queue the (possibly slow) model load + per-recording reset FIRST, under engineLock.
        // Because whisperQueue is serial and stop() enqueues the previous recording's finalize
        // under this same lock, this reset is ordered strictly AFTER that finalize — so the
        // previous recording's text is captured before we clear the context. Audio appended by
        // the tap below is processed only after this block, so recording starts instantly
        // without dropping the lead-in.
        whisperQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.loadContextIfNeeded()
            } catch {
                print("Streaming model load failed: \(error)")
                return
            }
            self.settings = settings
            self.committedSegments = 0
            self.runningText = ""
            self.context?.resumableReset()
        }

        do {
            try configureCapture()

            // Rebuild the tap/converter if the input device or its format changes mid-stream
            // (e.g. the mic is unplugged). The resumable state is kept, so the stream continues.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: audioEngine,
                queue: .main
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            // Roll back partial setup so the shared engine is not left with a dangling tap or
            // observer that would corrupt the next live session. isRunning stays false, so the
            // caller's stop() returns .unavailable and the recording falls back to file
            // transcription instead of being lost.
            audioEngine.inputNode.removeTap(onBus: 0)
            removeConfigObserver()
            throw error
        }

        isRunning = true
    }

    /// (Re)installs the input tap and builds a converter matching the current input format.
    /// The tap runs on the audio render thread: it does the cheap format conversion and
    /// hands the samples to the whisper queue.
    /// MUST be called with `engineLock` held (callers: start() and handleConfigurationChange()).
    private func configureCapture() throws {
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)

        let inputFormat = input.inputFormat(forBus: 0)
        guard let targetFormat = targetFormat,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw TranscriptionError.audioConversionFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.handleIncoming(buffer: buffer)
        }
    }

    /// Input device/format changed (e.g. mic unplugged). Rebuild capture and resume.
    private func handleConfigurationChange() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard isRunning else { return }
        do {
            try configureCapture()
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
        } catch {
            print("Streaming reconfigure after device change failed: \(error)")
        }
    }

    /// Stop capturing, flush the trailing window, and return the final transcription.
    /// Returns `.unavailable` if streaming never actually ran (start failed or the model
    /// could not be loaded), so the caller can fall back to a file-based pass.
    func stop() -> FinalizeResult {
        engineLock.lock()

        let wasRunning = isRunning
        isRunning = false
        removeConfigObserver()
        if wasRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        // start() failed before the engine ever ran -> nothing was captured.
        guard wasRunning else { engineLock.unlock(); return .unavailable }
        if isCancelled { engineLock.unlock(); return .transcribed(finalText()) }

        // Enqueue the finalize WHILE STILL HOLDING engineLock so it is ordered ahead of any
        // overlapping start()'s reset (which also enqueues under engineLock). The expensive
        // decode runs on the serial queue AFTER the lock is released below, so the next
        // recording's engine setup is not blocked by it. The final text is captured INSIDE
        // the queued block, so the next recording's reset can't clear it first.
        let done = DispatchSemaphore(value: 0)
        var captured = ""
        var hadContext = false
        whisperQueue.async { [weak self] in
            defer { done.signal() }
            guard let self = self, let context = self.context else { return } // model load failed
            hadContext = true
            var params = self.makeParams()
            // finalize = true: decode the remaining <30s window (padded), like the last
            // iteration of whisper_full's internal loop.
            let nNew = context.fullResumable(params: &params, finalize: true)
            if nNew > 0 {
                self.appendNewSegments(from: context)
            }
            captured = self.finalText()
        }
        engineLock.unlock()

        // Block this (detached) caller until the finalize finishes, without holding engineLock.
        done.wait()

        guard hadContext else { return .unavailable }
        return .transcribed(captured)
    }

    func cancel() {
        engineLock.lock()
        defer { engineLock.unlock() }
        isCancelled = true
        removeConfigObserver()
        if isRunning {
            isRunning = false
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }

    /// Graceful teardown for app quit: stop capture, then free the whisper context on the
    /// serial whisper queue. Releasing the context runs `whisper_free`, which frees the
    /// model's Metal buffers and drains their macOS 15+ residency sets before the GPU
    /// device is torn down. The free is enqueued on `whisperQueue`, so it never races an
    /// in-flight decode, and this never blocks the calling (main) thread.
    func shutdown() async {
        cancel()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            whisperQueue.async { [weak self] in
                self?.context = nil
                self?.committedSegments = 0
                self?.runningText = ""
                cont.resume()
            }
        }
    }

    private func removeConfigObserver() {
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
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

        // The resumable API manages cross-window seek + context itself, so we never feed
        // prompt tokens manually. Realtime segment printing (whisper -> stderr) is gated on
        // the app's debug setting, matching the file path's verbosity when logging is on and
        // staying quiet otherwise.
        let verbose = AppPreferences.shared.debugMode
        params.printRealtime = verbose
        params.print_realtime = verbose
        if verbose {
            // Debug logging on: compute real segment timestamps so the realtime log shows valid
            // [t0 --> t1] times instead of a bogus header built from an unset timestamp token.
            // The stored transcription text still follows settings.showTimestamps; this only
            // affects the log (and adds timestamp tokens to decoding while debugging).
            params.noTimestamps = false
        }
        // Only print the [t0 --> t1] header when timestamps are actually computed.
        params.printTimestamps = verbose || settings.showTimestamps

        params.melNormMode = melNormMode.rawValue
        params.melNormHalfLife = melNormHalfLife

        return params.toC()
    }
}
