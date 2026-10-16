// Long-audio windows for the 15 s encoder function .
// Audio up to `singleShotMaxS` is one window (the reference engines' single-shot rule). Longer audio is cut into windows of at most
// `windowS` seconds: each cut is searched inside [bandMinS, windowS] after the window start at a QUIET point (the reference engines'
// rule: RMS over 50 ms blocks, gate = max(0.004, 0.18 x peak RMS since the window start), the middle of the longest quiet run, ties to
// the point nearest `windowS`). When there is no quiet block the cut falls at `windowS` and the next window starts `overlapS` earlier;
// that boundary is stitched at word level around a split time placed at the lowest-energy block of the overlap (see Stitcher).
import Foundation

public struct Window: Equatable {
    public let start: Int, end: Int          // samples
    public let overlapFromPrevious: Bool     // this window begins inside the previous one
    public let splitSample: Int?             // for an overlapped boundary: the absolute sample where ownership passes to this window
}

public enum Windower {
    public static let sampleRate = 16000
    public static let blockS = 0.05, noiseFloorRMS: Float = 0.004, gateRatio: Float = 0.18

    static func blockRMS(_ audio: [Float], block: Int) -> [Float] {
        let n = audio.count, nBlocks = (n + block - 1) / block
        var rms = [Float](repeating: 0, count: nBlocks)
        for b in 0..<nBlocks { var s: Float = 0; let lo = b * block, hi = min(n, lo + block); for i in lo..<hi { s += audio[i] * audio[i] }; rms[b] = (s / Float(block)).squareRoot() }
        return rms
    }

    /// The reference engines' quiet-point search in [lo, hi) samples after `start`; nil when no block is quiet.
    static func quietCut(rms: [Float], block: Int, start: Int, lo: Int, hi: Int, target: Int) -> Int? {
        let b0 = (lo + block - 1) / block, b1 = min(hi / block, rms.count), bs = start / block
        guard b0 < b1, b1 > bs else { return nil }
        let peak = rms[bs..<b1].max() ?? 0
        let gate = max(noiseFloorRMS, gateRatio * peak)
        var best: (Int, Int, Int)? = nil   // (run length, -distance to target, mid)
        var i = b0
        while i < b1 {
            if rms[i] > gate { i += 1; continue }
            var j = i; while j < b1 && rms[j] <= gate { j += 1 }
            let mid = (i + j) * block / 2
            let cand = (j - i, -abs(mid - target), mid)
            if best == nil || cand.0 > best!.0 || (cand.0 == best!.0 && (cand.1 > best!.1 || (cand.1 == best!.1 && cand.2 > best!.2))) { best = cand }
            i = j
        }
        return best?.2
    }

    /// Windows for `audio` (mono 16 kHz). `windowS` = the encoder function's length (15), `bandMinS` = earliest cut (10),
    /// `overlapS` = overlap when no quiet point exists (2.0), `singleShotMaxS` = one window up to this length (35 on macOS).
    public static func plan(_ audio: [Float], windowS: Double = 15.0, bandMinS: Double = 10.0, overlapS: Double = 2.0, singleShotMaxS: Double = 35.0) -> [Window] {
        let n = audio.count
        if n <= Int(singleShotMaxS * Double(sampleRate)) { return [Window(start: 0, end: n, overlapFromPrevious: false, splitSample: nil)] }
        return plan(rms: blockRMS(audio, block: Int(blockS * Double(sampleRate))), count: n, windowS: windowS, bandMinS: bandMinS, overlapS: overlapS, singleShotMaxS: singleShotMaxS)
    }
    /// Same plan from streamed 50 ms block RMS (see AudioSource.blockRMS) and the sample count.
    public static func plan(rms: [Float], count n: Int, windowS: Double = 15.0, bandMinS: Double = 10.0, overlapS: Double = 2.0, singleShotMaxS: Double = 35.0) -> [Window] {
        let sr = sampleRate
        if n <= Int(singleShotMaxS * Double(sr)) { return [Window(start: 0, end: n, overlapFromPrevious: false, splitSample: nil)] }
        var st = State(); var out: [Window] = []
        while n - st.start > windowSamples(windowS) { out.append(step(rms: rms, state: &st, windowS: windowS, bandMinS: bandMinS, overlapS: overlapS)) }
        out.append(Window(start: st.start, end: n, overlapFromPrevious: st.overlapped, splitSample: st.split))
        return out
    }
    public struct State: Equatable { public var start = 0, overlapped = false; public var split: Int? = nil; public init() {} }
    public static func maximumWindowSamples(forFunctionSeconds seconds: Double) -> Int {
        Int(seconds * Double(sampleRate)) - 400
    }

    public static func maximumWindowSeconds(forFunctionSeconds seconds: Double) -> Double {
        Double(maximumWindowSamples(forFunctionSeconds: seconds)) / Double(sampleRate)
    }

    static func windowSamples(_ windowS: Double) -> Int { maximumWindowSamples(forFunctionSeconds: windowS) }
    /// One cut of the long-audio rule from `state.start` (the loop body of `plan`).
    static func step(rms: [Float], state st: inout State, windowS: Double, bandMinS: Double, overlapS: Double) -> Window {
        let sr = sampleRate, block = Int(blockS * Double(sr)), W = windowSamples(windowS), overlap = Int(overlapS * Double(sr))
        let start = st.start
        let lo = start + Int(bandMinS * Double(sr)), hi = start + W
        if let cut = quietCut(rms: rms, block: block, start: start, lo: lo, hi: hi, target: hi) {
            let w = Window(start: start, end: cut, overlapFromPrevious: st.overlapped, splitSample: st.split)
            st.start = cut; st.overlapped = false; st.split = nil; return w
        }
        // no pause: full window, the next one starts `overlap` earlier; ownership passes at the quietest block of the overlap's middle part
        let cut = hi
        let w = Window(start: start, end: cut, overlapFromPrevious: st.overlapped, splitSample: st.split)
        let sLo = cut - overlap + Int(0.3 * Double(sr)), sHi = cut - Int(0.3 * Double(sr))
        var bestB = -1; var bestV = Float.greatestFiniteMagnitude
        var b = (sLo + block - 1) / block
        while (b + 1) * block <= sHi && b < rms.count { if rms[b] < bestV { bestV = rms[b]; bestB = b }; b += 1 }
        st.split = bestB >= 0 ? bestB * block + block / 2 : cut - overlap / 2
        st.start = cut - overlap; st.overlapped = true
        return w
    }
}

