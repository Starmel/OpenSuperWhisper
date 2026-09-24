import Accelerate
import CoreML
import Foundation

/// Russian speech recognition with GigaAM-v3 e2e RNNT (punctuated, normalized output).
/// The Conformer encoder runs once per <= 30 s window; the prediction and joint
/// networks run in a host-side greedy transducer loop.
class GigaAMEngine: TranscriptionEngine {
    var engineName: String { "GigaAM" }

    static let windowSamples = 30 * GigaAMFeatureExtractor.sampleRate
    static let windowFrames = GigaAMFeatureExtractor.frameCount(sampleCount: windowSamples)
    static let blankID = 1024
    static let maxSymbolsPerFrame = 10
    private static let encoderDim = 768
    private static let predictionDim = 320

    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var vocabulary: [String] = []
    private var isCancelled = false

    var onProgressUpdate: ((Float) -> Void)?

    var isModelLoaded: Bool {
        encoder != nil
    }

    func initialize() async throws {
        guard GigaAMModel.isSupported else { throw GigaAMModel.ModelError.unsupportedOS }
        guard GigaAMModel.isInstalled else { throw GigaAMModel.ModelError.notInstalled }

        // The Neural Engine keeps the ~420 MB of encoder weights out of the app's
        // memory and is the fastest option; the first load compiles for the ANE once.
        // (CPU+GPU is token-exact with the PyTorch reference; the ANE's fp16
        // accumulation rarely flips a borderline emission.) The per-step networks
        // are tiny, so dispatching them anywhere but the CPU only adds latency.
        let encoderConfiguration = MLModelConfiguration()
        encoderConfiguration.computeUnits = .cpuAndNeuralEngine
        let stepConfiguration = MLModelConfiguration()
        stepConfiguration.computeUnits = .cpuOnly

        encoder = try await MLModel.load(contentsOf: GigaAMModel.compiledModelURL(GigaAMModel.encoder),
                                         configuration: encoderConfiguration)
        decoder = try await MLModel.load(contentsOf: GigaAMModel.compiledModelURL(GigaAMModel.decoder),
                                         configuration: stepConfiguration)
        joint = try await MLModel.load(contentsOf: GigaAMModel.compiledModelURL(GigaAMModel.joint),
                                       configuration: stepConfiguration)
        vocabulary = try JSONDecoder().decode([String].self, from: Data(contentsOf: GigaAMModel.vocabularyURL()))
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard isModelLoaded else { throw TranscriptionError.contextInitializationFailed }
        isCancelled = false
        onProgressUpdate?(0.02)

        // Reuses Whisper's 16 kHz mono conversion; it does not touch a whisper context.
        guard let samples = try await WhisperEngine().convertAudioToPCM(
            fileURL: url,
            cancellationCheck: { [weak self] in self?.isCancelled ?? true }
        ) else {
            if isCancelled { throw CancellationError() }
            throw TranscriptionError.audioConversionFailed
        }
        onProgressUpdate?(0.05)

        let windows = Self.windowRanges(for: samples)
        var texts: [String] = []
        for (index, range) in windows.enumerated() {
            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }
            let text = try transcribeWindow(samples[range])
            if !text.isEmpty { texts.append(text) }
            onProgressUpdate?(0.05 + 0.95 * Float(index + 1) / Float(windows.count))
        }
        return texts.joined(separator: " ")
    }

    func cancelTranscription() {
        isCancelled = true
    }

    func getSupportedLanguages() -> [String] {
        LanguageUtil.gigaAMLanguages
    }

    // MARK: - Windowing

    /// Splits audio into windows of at most 30 s, cutting long audio at the
    /// quietest 100 ms in the last 10 s of each window so words are not split.
    static func windowRanges(for samples: [Float]) -> [Range<Int>] {
        let blockSize = GigaAMFeatureExtractor.sampleRate / 10
        let searchSpan = 10 * GigaAMFeatureExtractor.sampleRate
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > windowSamples {
            var cut = start + windowSamples
            var quietest = Float.greatestFiniteMagnitude
            var blockStart = start + windowSamples - searchSpan
            samples.withUnsafeBufferPointer { buffer in
                while blockStart + blockSize <= start + windowSamples {
                    var energy: Float = 0
                    vDSP_svesq(buffer.baseAddress! + blockStart, 1, &energy, vDSP_Length(blockSize))
                    if energy < quietest {
                        quietest = energy
                        cut = blockStart + blockSize / 2
                    }
                    blockStart += blockSize / 4
                }
            }
            ranges.append(start..<cut)
            start = cut
        }
        if samples.count > start {
            ranges.append(start..<samples.count)
        }
        return ranges
    }

    // MARK: - Decoding

    private func transcribeWindow(_ window: ArraySlice<Float>) throws -> String {
        guard let encoder, let decoder, let joint else { throw TranscriptionError.contextInitializationFailed }
        let validFrames = GigaAMFeatureExtractor.frameCount(sampleCount: window.count)
        guard validFrames > 0 else { return "" }

        var padded = [Float](repeating: 0, count: Self.windowSamples)
        padded.replaceSubrange(0..<window.count, with: window)
        let features = GigaAMFeatureExtractor.logMel(padded)

        let featureArray = try MLMultiArray(
            shape: [1, NSNumber(value: GigaAMFeatureExtractor.melBins), NSNumber(value: Self.windowFrames)],
            dataType: .float32)
        Self.write(features, to: featureArray)
        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: validFrames)

        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "features": featureArray, "length": lengthArray,
        ]))
        guard let encodedArray = encoded.featureValue(for: "encoded")?.multiArrayValue,
              let encodedLength = encoded.featureValue(for: "encoded_len")?.multiArrayValue else {
            throw TranscriptionError.contextInitializationFailed
        }
        // [1, 768, T] -> frame-major [T][768] so each step reads a contiguous frame.
        let encoderFrames = Self.floats(from: encodedArray, transposingLastTwoAxes: true)
        let frameCount = min(Int(encodedLength[0].floatValue.rounded()), encodedArray.shape[2].intValue)

        let token = try MLMultiArray(shape: [1, 1], dataType: .int32)
        var hidden = try MLMultiArray(shape: [1, 1, NSNumber(value: Self.predictionDim)], dataType: .float32)
        var cell = try MLMultiArray(shape: [1, 1, NSNumber(value: Self.predictionDim)], dataType: .float32)
        Self.write([Float](repeating: 0, count: Self.predictionDim), to: hidden)
        Self.write([Float](repeating: 0, count: Self.predictionDim), to: cell)
        let encoderStep = try MLMultiArray(shape: [1, NSNumber(value: Self.encoderDim)], dataType: .float32)
        let decoderStep = try MLMultiArray(shape: [1, NSNumber(value: Self.predictionDim)], dataType: .float32)

        // The prediction network output depends only on (last token, state), so it
        // is recomputed only after a non-blank emission.
        var lastToken = Self.blankID
        var decoded: MLFeatureProvider?
        var ids: [Int] = []

        for t in 0..<frameCount {
            if isCancelled { throw CancellationError() }
            Self.write(encoderFrames[(t * Self.encoderDim)..<((t + 1) * Self.encoderDim)], to: encoderStep)

            for _ in 0..<Self.maxSymbolsPerFrame {
                if decoded == nil {
                    token[0] = NSNumber(value: lastToken)
                    let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                        "token": token, "h_in": hidden, "c_in": cell,
                    ]))
                    Self.write(Self.floats(from: output.featureValue(for: "dec_out")!.multiArrayValue!), to: decoderStep)
                    decoded = output
                }

                let logits = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "enc_t": encoderStep, "dec_t": decoderStep,
                ]))
                let best = Self.argmax(Self.floats(from: logits.featureValue(for: "logits")!.multiArrayValue!))
                if best == Self.blankID { break }

                ids.append(best)
                lastToken = best
                hidden = try Self.float32Copy(of: decoded!.featureValue(for: "h_out")!.multiArrayValue!)
                cell = try Self.float32Copy(of: decoded!.featureValue(for: "c_out")!.multiArrayValue!)
                decoded = nil
            }
        }

        return detokenize(ids)
    }

    func detokenize(_ ids: [Int]) -> String {
        ids.filter { $0 > 0 && $0 < vocabulary.count }
            .map { vocabulary[$0] }
            .joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - MLMultiArray helpers

    private static func argmax(_ values: [Float]) -> Int {
        var maxValue: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(values, 1, &maxValue, &index, vDSP_Length(values.count))
        return Int(index)
    }

    /// Reads a Float16/Float32 array honoring its strides (Core ML may pad rows).
    /// With `transposingLastTwoAxes`, a `[1, C, T]` array is returned as `[T][C]`.
    private static func floats(from array: MLMultiArray, transposingLastTwoAxes: Bool = false) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let rows = shape.count >= 2 ? shape[shape.count - 2] : 1
        let columns = shape.last ?? 0
        let rowStride = shape.count >= 2 ? strides[strides.count - 2] : 0
        let columnStride = strides.last ?? 1
        var result = [Float](repeating: 0, count: rows * columns)

        func fill<T>(_ pointer: UnsafeBufferPointer<T>, _ convert: (T) -> Float) {
            for row in 0..<rows {
                for column in 0..<columns {
                    let value = convert(pointer[row * rowStride + column * columnStride])
                    if transposingLastTwoAxes {
                        result[column * rows + row] = value
                    } else {
                        result[row * columns + column] = value
                    }
                }
            }
        }

        switch array.dataType {
        case .float16:
            // withUnsafeBufferPointer(ofType: Float16.self) needs macOS 15; read the raw bytes instead.
            array.withUnsafeBytes { fill($0.bindMemory(to: Float16.self)) { Float($0) } }
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { fill($0) { $0 } }
        default:
            for index in 0..<result.count { result[index] = array[index].floatValue }
        }
        return result
    }

    private static func write<C: Collection>(_ values: C, to array: MLMultiArray) where C.Element == Float {
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            _ = pointer.update(fromContentsOf: values)
        }
    }

    private static func float32Copy(of array: MLMultiArray) throws -> MLMultiArray {
        let copy = try MLMultiArray(shape: array.shape, dataType: .float32)
        write(floats(from: array), to: copy)
        return copy
    }
}
