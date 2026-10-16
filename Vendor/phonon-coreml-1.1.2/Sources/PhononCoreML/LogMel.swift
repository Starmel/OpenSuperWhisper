// Log-mel front end = the HF ParakeetFeatureExtractor arithmetic the Phonon-2 engines use:
// pre-emphasis 0.97, 512-point STFT (hop 160, symmetric Hann 400 centred in the 512 frame, zero padding 256 each side),
// power spectrum, slaney mel 128 (fmin 0, fmax 8 kHz), log(x + 2^-24), per-feature mean/std over the true frames (std + 1e-5).
// T = n/160 frames by default ("hf", the extractor's valid length) or 1 + n/160 ("pip"). Output [128][T] row-major as Float.
import Accelerate
import Foundation

public struct LogMel {
    public static let nFFT = 512, hop = 160, win = 400, nMels = 128, sampleRate = 16000
    static let preemph: Float = 0.97
    static let logGuard: Float = 5.960464477539063e-08   // 2^-24

    let window: [Float]          // 512, Hann(400, symmetric) centred
    let melF: [Float]            // [128 * 257]
    let fft: vDSP.FFT<DSPSplitComplex>

    public init() {
        var w = [Float](repeating: 0, count: LogMel.nFFT)
        let l = (LogMel.nFFT - LogMel.win) / 2
        for i in 0..<LogMel.win { w[l + i] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(LogMel.win - 1))) }
        window = w
        melF = LogMel.slaneyMel()
        fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self)!
    }

    static func hzToMel(_ f: Double) -> Double {
        let fsp = 200.0 / 3.0, minLogHz = 1000.0, minLogMel = minLogHz / fsp, logstep = log(6.4) / 27.0
        return f >= minLogHz ? minLogMel + log(max(f, 1e-30) / minLogHz) / logstep : f / fsp
    }
    static func melToHz(_ m: Double) -> Double {
        let fsp = 200.0 / 3.0, minLogHz = 1000.0, minLogMel = minLogHz / fsp, logstep = log(6.4) / 27.0
        return m >= minLogMel ? minLogHz * exp(logstep * (m - minLogMel)) : fsp * m
    }
    static func slaneyMel() -> [Float] {
        let nb = nFFT / 2 + 1
        let fftFreqs = (0..<nb).map { Double($0) * Double(sampleRate) / 2.0 / Double(nb - 1) }
        let m0 = hzToMel(0), m1 = hzToMel(Double(sampleRate) / 2)
        let melPts = (0..<(nMels + 2)).map { melToHz(m0 + (m1 - m0) * Double($0) / Double(nMels + 1)) }
        var w = [Float](repeating: 0, count: nMels * nb)
        for i in 0..<nMels {
            let lo = melPts[i], c = melPts[i + 1], hi = melPts[i + 2]
            let enorm = 2.0 / (hi - lo)
            for k in 0..<nb {
                let lower = (fftFreqs[k] - lo) / (c - lo), upper = (hi - fftFreqs[k]) / (hi - c)
                w[i * nb + k] = Float(max(0.0, min(lower, upper)) * enorm)
            }
        }
        return w
    }

    /// wave: mono 16 kHz Float samples. Returns (features [128*T] row-major, T).
    /// rule "pip": T = 1 + n/160 (the fermion engines: every STFT frame incl. the last partial one); "hf": T = n/160 (the HF extractor's valid length).
    public func features(_ wave: [Float], rule: String = "hf") -> ([Float], Int) {
        let n = wave.count
        let T = rule == "hf" ? n / LogMel.hop : 1 + n / LogMel.hop
        if T < 1 { return ([], 0) }
        var x = [Float](repeating: 0, count: n + LogMel.nFFT)
        // pre-emphasis then centre pad 256
        x[256] = wave[0]
        for i in 1..<n { x[256 + i] = wave[i] - LogMel.preemph * wave[i - 1] }
        let nb = LogMel.nFFT / 2 + 1
        var power = [Float](repeating: 0, count: T * nb)
        var frame = [Float](repeating: 0, count: LogMel.nFFT)
        var re = [Float](repeating: 0, count: LogMel.nFFT / 2), im = [Float](repeating: 0, count: LogMel.nFFT / 2)
        var ore = [Float](repeating: 0, count: LogMel.nFFT / 2), oim = [Float](repeating: 0, count: LogMel.nFFT / 2)
        for t in 0..<T {
            let s = t * LogMel.hop
            for k in 0..<LogMel.nFFT { frame[k] = x[s + k] * window[k] }
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: LogMel.nFFT / 2) { cp in vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(LogMel.nFFT / 2)) }
                }
                ore.withUnsafeMutableBufferPointer { orp in oim.withUnsafeMutableBufferPointer { oip in
                    var out = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                    fft.forward(input: split, output: &out)
                    // vDSP real FFT packing: out.real[0] = 2*DC, out.imag[0] = 2*Nyquist, others scaled by 2
                    let dc = orp[0] * 0.5, ny = oip[0] * 0.5
                    power[t * nb] = dc * dc
                    power[t * nb + nb - 1] = ny * ny
                    for k in 1..<(LogMel.nFFT / 2) { let r = orp[k] * 0.5, i = oip[k] * 0.5; power[t * nb + k] = r * r + i * i }
                } }
            } }
        }
        // mel [T x 128] = power [T x 257] @ melF^T
        var mel = [Float](repeating: 0, count: T * LogMel.nMels)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(T), Int32(LogMel.nMels), Int32(nb), 1.0, power, Int32(nb), melF, Int32(nb), 0.0, &mel, Int32(LogMel.nMels))
        for i in 0..<mel.count { mel[i] = log(mel[i] + LogMel.logGuard) }
        // per-feature normalisation over T frames (unbiased variance), then transpose to [128][T]
        var out = [Float](repeating: 0, count: LogMel.nMels * T)
        for f in 0..<LogMel.nMels {
            var mean: Float = 0
            for t in 0..<T { mean += mel[t * LogMel.nMels + f] }
            mean /= Float(T)
            var v: Float = 0
            for t in 0..<T { let d = mel[t * LogMel.nMels + f] - mean; v += d * d }
            let std = T > 1 ? sqrt(v / Float(T - 1)) : 0
            let inv = 1.0 / (std + 1e-5)
            for t in 0..<T { out[f * T + t] = (mel[t * LogMel.nMels + f] - mean) * inv }
        }
        return (out, T)
    }
}

