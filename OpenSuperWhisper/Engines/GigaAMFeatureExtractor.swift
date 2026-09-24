import Accelerate
import Foundation

/// Log-mel front-end for GigaAM-v3. Mirrors `gigaam.preprocess.FeatureExtractor`:
/// torchaudio `MelSpectrogram(sample_rate: 16000, n_fft: 320, win_length: 320,
/// hop_length: 160, n_mels: 64, center: false, mel_scale: "htk", norm: nil)`
/// followed by `log(clamp(x, 1e-9, 1e9))`, with no mean/variance normalization.
enum GigaAMFeatureExtractor {
    static let sampleRate = 16000
    static let nFFT = 320
    static let hopLength = 160
    static let melBins = 64
    static let freqBins = nFFT / 2 + 1

    static func frameCount(sampleCount: Int) -> Int {
        sampleCount < nFFT ? 0 : (sampleCount - nFFT) / hopLength + 1
    }

    /// Returns features laid out row-major as `[melBins][frames]`, ready to be
    /// copied into the encoder's `[1, 64, frames]` input.
    static func logMel(_ samples: [Float]) -> [Float] {
        let frames = frameCount(sampleCount: samples.count)
        guard frames > 0 else { return [] }

        // Overlapping frames, [frames x nFFT]. The Hann window is folded into
        // the DFT bases, so the frames are copied as-is.
        var framed = [Float](repeating: 0, count: frames * nFFT)
        samples.withUnsafeBufferPointer { src in
            framed.withUnsafeMutableBufferPointer { dst in
                for t in 0..<frames {
                    (dst.baseAddress! + t * nFFT)
                        .update(from: src.baseAddress! + t * hopLength, count: nFFT)
                }
            }
        }

        // One-sided DFT as two matrix products: [frames x nFFT] * [nFFT x freqBins].
        var real = [Float](repeating: 0, count: frames * freqBins)
        var imag = [Float](repeating: 0, count: frames * freqBins)
        vDSP_mmul(framed, 1, bases.cos, 1, &real, 1,
                  vDSP_Length(frames), vDSP_Length(freqBins), vDSP_Length(nFFT))
        vDSP_mmul(framed, 1, bases.sin, 1, &imag, 1,
                  vDSP_Length(frames), vDSP_Length(freqBins), vDSP_Length(nFFT))

        // Power spectrum: re^2 + im^2.
        var power = [Float](repeating: 0, count: frames * freqBins)
        vDSP_vmul(real, 1, real, 1, &power, 1, vDSP_Length(power.count))
        vDSP_vma(imag, 1, imag, 1, power, 1, &power, 1, vDSP_Length(power.count))

        // [frames x freqBins] * [freqBins x melBins] -> [frames x melBins].
        var mel = [Float](repeating: 0, count: frames * melBins)
        vDSP_mmul(power, 1, melFilterbank, 1, &mel, 1,
                  vDSP_Length(frames), vDSP_Length(melBins), vDSP_Length(freqBins))

        var low: Float = 1e-9
        var high: Float = 1e9
        vDSP_vclip(mel, 1, &low, &high, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlogf(&mel, mel, &count)

        var transposed = [Float](repeating: 0, count: mel.count)
        vDSP_mtrans(mel, 1, &transposed, 1, vDSP_Length(melBins), vDSP_Length(frames))
        return transposed
    }

    /// Periodic Hann window (torch.hann_window default) multiplied into
    /// cos/sin DFT bases, each laid out `[nFFT x freqBins]`.
    private static let bases: (cos: [Float], sin: [Float]) = {
        var cosBasis = [Float](repeating: 0, count: nFFT * freqBins)
        var sinBasis = [Float](repeating: 0, count: nFFT * freqBins)
        for n in 0..<nFFT {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(nFFT))
            for k in 0..<freqBins {
                let angle = 2 * Double.pi * Double(k * n % nFFT) / Double(nFFT)
                cosBasis[n * freqBins + k] = Float(window * cos(angle))
                sinBasis[n * freqBins + k] = Float(-window * sin(angle))
            }
        }
        return (cosBasis, sinBasis)
    }()

    /// torchaudio `melscale_fbanks(n_freqs: 161, f_min: 0, f_max: 8000,
    /// n_mels: 64, sample_rate: 16000, norm: nil, mel_scale: "htk")`,
    /// laid out `[freqBins x melBins]`.
    static let melFilterbank: [Float] = {
        func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

        let fMax = Double(sampleRate / 2)
        let melMax = hzToMel(fMax)
        let points = (0..<(melBins + 2)).map { melToHz(melMax * Double($0) / Double(melBins + 1)) }

        var bank = [Float](repeating: 0, count: freqBins * melBins)
        for f in 0..<freqBins {
            let hz = fMax * Double(f) / Double(freqBins - 1)
            for m in 0..<melBins {
                let down = (hz - points[m]) / (points[m + 1] - points[m])
                let up = (points[m + 2] - hz) / (points[m + 2] - points[m + 1])
                bank[f * melBins + m] = Float(max(0, min(down, up)))
            }
        }
        return bank
    }()
}
