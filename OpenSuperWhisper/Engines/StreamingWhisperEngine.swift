import AVFoundation
import Foundation

/// Live preview transcriber used only while recording is in progress. It taps
/// the microphone with its own AVAudioEngine and runs a second, independent
/// whisper context over a sliding window, so partial text can be shown in the
/// indicator without touching the file-based batch pipeline that still produces
/// the final inserted text. It is deliberately outside the TranscriptionEngine
/// protocol: that protocol is URL/batch oriented, this one is push/streaming.
final class StreamingWhisperEngine {
    /// Emits (committed, pending) on the main queue. Committed text is stable and
    /// only ever grows; pending is the tail of the window and is rewritten every
    /// step. The consumer renders committed opaque and pending dimmed.
    var onUpdate: (@MainActor (String, String) -> Void)?

    /// Window/step geometry, mirroring examples/stream: decode a bounded window
    /// whenever enough new audio has arrived, keep the newest
    /// `commitDelaySeconds` as unstable (pending) and finalize anything older.
    /// The step adapts to the hardware: it never goes below `minStepSeconds`,
    /// and never below the previous decode's duration, so fast models update
    /// several times a second while slow ones fall back to a coarser cadence
    /// instead of piling up work. A slow preview never affects the final text.
    private static let sampleRate: Double = 16000
    private static let minStepSeconds: Double = 0.5
    private static let commitDelaySeconds: Double = 1.5
    private static let maxWindowSeconds: Double = 15.0

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    /// Serial queue owning the whisper context and all accumulated audio: the
    /// realtime tap only deep-copies its buffer and hands it off here, so whisper
    /// never runs on the audio thread and the buffers need no extra locking.
    private let processingQueue = DispatchQueue(label: "com.opensuperwhisper.streaming", qos: .userInitiated)

    private var context: MyWhisperContext?
    private let language: String?

    // Owned by processingQueue only.
    private var window: [Float] = []
    private var samplesSinceStep = 0
    private var lastDecodeSeconds: Double = 0
    private var committedText = ""
    private var isStopped = false

    init() {
        let lang = AppPreferences.shared.whisperLanguage
        self.language = (lang == "auto" || lang.isEmpty) ? nil : lang
    }

    /// Loads a dedicated model context and starts tapping the microphone. Any
    /// failure is reported through the return value; the caller keeps recording
    /// regardless, since this is preview-only.
    @discardableResult
    func start() -> Bool {
        guard let modelPath = AppPreferences.shared.selectedWhisperModelPath ?? AppPreferences.shared.selectedModelPath else {
            return false
        }

        let params = WhisperContextParams()
        guard let ctx = MyWhisperContext.initFromFile(path: modelPath, params: params) else {
            return false
        }
        context = ctx

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inputFormat, to: target) else {
            context = nil
            return false
        }
        targetFormat = target
        converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            return true
        } catch {
            print("StreamingWhisperEngine failed to start audio engine: \(error)")
            inputNode.removeTap(onBus: 0)
            context = nil
            return false
        }
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.isStopped = true
            self.context = nil
            self.window = []
        }
    }

    // MARK: - Audio capture

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        // The tap buffer is only valid for the duration of this callback, so a
        // deep copy is handed to the processing queue; nothing heavy runs here.
        guard let copy = Self.copyBuffer(buffer) else { return }
        processingQueue.async { [weak self] in
            self?.ingest(copy)
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: frames)
            }
        } else {
            return nil
        }
        return copy
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard !isStopped, let converter = converter, let targetFormat = targetFormat else { return }

        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if convError != nil { return }

        let frames = Int(out.frameLength)
        guard frames > 0, let channel = out.floatChannelData?[0] else { return }
        window.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        samplesSinceStep += frames

        let stepSeconds = max(Self.minStepSeconds, lastDecodeSeconds)
        if samplesSinceStep >= Int(stepSeconds * Self.sampleRate) {
            samplesSinceStep = 0
            runStep()
        }
    }

    // MARK: - Inference

    private func runStep() {
        guard !isStopped, let context = context, !window.isEmpty else { return }

        var params = WhisperFullParams()
        params.strategy = .greedy
        params.nThreads = Int32(max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8)))
        params.noContext = true
        params.noTimestamps = false
        params.singleSegment = false
        params.printProgress = false
        params.printRealtime = false
        params.printTimestamps = false
        params.printSpecial = false
        params.suppressBlank = true
        params.temperature = 0.0
        params.language = language
        params.detectLanguage = false

        var cParams = params.toC()
        let decodeStart = CFAbsoluteTimeGetCurrent()
        guard context.full(samples: window, params: &cParams) else { return }
        lastDecodeSeconds = CFAbsoluteTimeGetCurrent() - decodeStart

        let windowDuration = Double(window.count) / Self.sampleRate
        let commitBoundary = windowDuration - Self.commitDelaySeconds

        var committedThisStep = ""
        var pending = ""
        var commitUpToSeconds = 0.0

        let nSegments = context.fullNSegments
        for i in 0..<nSegments {
            guard let raw = context.fullGetSegmentText(iSegment: i) else { continue }
            let text = Self.clean(raw)
            let segEnd = Double(context.fullGetSegmentT1(iSegment: i)) / 100.0

            // Finalize a segment once its end is comfortably in the past.
            if segEnd <= commitBoundary {
                if !text.isEmpty {
                    committedThisStep = Self.joined(committedThisStep, text)
                }
                commitUpToSeconds = segEnd
            } else if !text.isEmpty {
                pending = Self.joined(pending, text)
            }
        }

        if !committedThisStep.isEmpty {
            committedText = Self.joined(committedText, committedThisStep)
        }

        // Drop the committed prefix from the window so it is not decoded again.
        if commitUpToSeconds > 0 {
            let dropCount = min(Int(commitUpToSeconds * Self.sampleRate), window.count)
            if dropCount > 0 {
                window.removeFirst(dropCount)
            }
        }

        // Continuous speech can yield a single segment spanning the whole window,
        // whose end never crosses the commit boundary; without a fallback the
        // window would grow without bound and each decode would take longer.
        // The whole window has been decoded at this point (ingest and decode share
        // one serial queue), so folding the pending tail into the committed text
        // and starting a fresh window loses nothing and cannot duplicate output.
        if window.count > Int(Self.maxWindowSeconds * Self.sampleRate) {
            if !pending.isEmpty {
                committedText = Self.joined(committedText, pending)
                pending = ""
            }
            window = []
        }

        let committedSnapshot = committedText
        let pendingSnapshot = pending
        if let onUpdate = onUpdate {
            Task { @MainActor in
                onUpdate(committedSnapshot, pendingSnapshot)
            }
        }
    }

    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins two transcript fragments with a space, except at CJK boundaries:
    /// there the fragments are parts of one unspaced sentence and inserting a
    /// space would corrupt the text. Never modifies `head`, so joined output
    /// only ever grows by a suffix — the streaming input delta logic relies on
    /// that.
    static func joined(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        if isCJK(head.last!) || isCJK(tail.first!) {
            return head + tail
        }
        return head + " " + tail
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x30FF,  // CJK punctuation, hiragana, katakana
             0x3400...0x9FFF,  // CJK unified ideographs
             0xF900...0xFAFF,  // CJK compatibility ideographs
             0xFF00...0xFF9F:  // full-width forms, half-width katakana
            return true
        default:
            return false
        }
    }
}
