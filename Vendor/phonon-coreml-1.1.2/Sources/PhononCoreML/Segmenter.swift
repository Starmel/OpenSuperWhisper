// Long-audio rule, ported line for line from the Phonon engines (fermion._speech.segment): audio up to 35 s is one window; otherwise
// each cut is searched inside [25 s, 35 s] after the window start — RMS over 50 ms blocks, gate = max(0.004, 0.18 x peak RMS since the
// window start), cut in the middle of the LONGEST run of quiet blocks (ties: nearest 30 s); no quiet block -> cut at 30 s. Silence test:
// max|x| < 1e-4 means "nothing to decode". No padding with silence anywhere.
import Foundation

public enum Segmenter {
    public static let sampleRate = 16000
    public static let singleShotMaxS = 35.0, bandMinS = 25.0, bandMaxS = 35.0, targetS = 30.0, blockS = 0.05
    public static let noiseFloorRMS: Float = 0.004, gateRatio: Float = 0.18

    public static func isSilent(_ a: ArraySlice<Float>) -> Bool { if a.isEmpty { return true }; var m: Float = 0; for v in a { m = max(m, abs(v)) }; return m < 1e-4 }

    public static func plan(_ audio: [Float]) -> [(Int, Int)] {
        let n = audio.count, block = Int(blockS * Double(sampleRate)); let nBlocks = (n + block - 1) / block
        if n <= Int(singleShotMaxS * Double(sampleRate)) { return [(0, n)] }
        var rms = [Float](repeating: 0, count: nBlocks)
        for b in 0..<nBlocks { var s: Float = 0; let lo = b * block, hi = min(n, lo + block); for i in lo..<hi { s += audio[i] * audio[i] }; rms[b] = (s / Float(block)).squareRoot() }   // zero-padded last block, as numpy
        return plan(rms: rms, count: n)
    }
    public static func plan(rms: [Float], count n: Int) -> [(Int, Int)] {
        let sr = sampleRate
        let single = Int(singleShotMaxS * Double(sr))
        if n <= single { return [(0, n)] }
        let block = Int(blockS * Double(sr)); let nBlocks = rms.count
        var windows: [(Int, Int)] = []; var start = 0
        while n - start > single {
            let lo = start + Int(bandMinS * Double(sr)), hi = start + Int(bandMaxS * Double(sr))
            let b0 = (lo + block - 1) / block, b1 = hi / block, bs = start / block
            let peak: Float = b1 > bs ? rms[bs..<min(b1, nBlocks)].max() ?? 0 : 0
            let gate = max(noiseFloorRMS, gateRatio * peak)
            let target = start + Int(targetS * Double(sr))
            var cut = target
            if b0 < b1 {
                let quiet = (b0..<min(b1, nBlocks)).map { rms[$0] <= gate }
                var best: (Int, Int, Int)? = nil   // (length, -distance, mid)
                var i = 0
                while i < quiet.count {
                    if !quiet[i] { i += 1; continue }
                    var j = i; while j < quiet.count && quiet[j] { j += 1 }
                    let mid = ((b0 + i) + (b0 + j)) * block / 2
                    let cand = (j - i, -abs(mid - target), mid)
                    if best == nil || cand.0 > best!.0 || (cand.0 == best!.0 && (cand.1 > best!.1 || (cand.1 == best!.1 && cand.2 > best!.2))) { best = cand }
                    i = j
                }
                if let b = best { cut = b.2 }
            }
            cut = max(lo, min(hi, cut, n))
            windows.append((start, cut)); start = cut
        }
        windows.append((start, n))
        return windows
    }
}

