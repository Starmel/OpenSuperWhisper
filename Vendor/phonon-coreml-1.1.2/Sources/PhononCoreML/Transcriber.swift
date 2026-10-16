// Phonon-2 on Core ML.
// log-mel (Accelerate) -> ONE multifunction package (exact five-value palettes; a ladder of encoder functions 3/5/10/15/25/35 s over one
// weight blob, 16-bit float I/O, relative positions in-graph) on the Neural Engine -> the C greedy-TDT loop. A short utterance runs the
// smallest function that holds it and decodes on a multi-threaded handle; long audio runs in 15 s windows cut at pauses with mel, Neural
// Engine requests (several in flight) and decoder workers overlapped, and a window with an unexplained blank run is re-decoded inside the
// worker that found it. Earlier bundles (fp32 inputs, `pos` input, functions 15/35) load unchanged.
import Accelerate
import CoreML
import Foundation

public struct Manifest: Decodable {
    public let name: String; public let container_sha256: String; public let program_prefix: String
    public let multifunction: String
    public let functions_s: [Double]            // encoder functions in the package, by window length in seconds
    public let frames_rule: String?             // "hf" (n/160 frames; default) or "pip" (1 + n/160)
    public let long_audio: String?              // "windows15" (default) or "reference" (25-35 s pause segmenter + the 35 s function)
    public let residual_scale: Double?
    public let version: String?
    public let single_shot_max_s: Double?       // the single-shot rule (35 s); larger functions are for hosts that ask for them
}

public struct Transcript {
    public var text: String
    public var words: [Word]
    public var segments: [Segment]
    public var audioSeconds: Double
    public var decodeSeconds: Double
    public var windows: Int
}

public final class Transcriber {
    public struct Options {
        public var computeUnits: MLComputeUnits = .cpuAndNeuralEngine
        public var decoderThreads: Int32 = 1          // threads inside ONE decode for the long-audio workers
        public var decoderWorkers: Int = 4            // windows decoded concurrently (each on its own C handle)
        public var fastDecoderThreads: Int32 = 4      // a single window decodes on its own handle with this many threads
        public var encoderInFlight: Int = 2           // Neural Engine requests in flight on long audio
        public var longAudio: String? = nil           // nil = manifest default
        public var singleShotMaxSeconds: Double? = nil   // one window up to this length (default: the largest function; iOS: 15)
        public var functions: [Double]? = nil         // which functions to make available (default: all in the manifest; iOS: <= 15 s)
        public var eagerFunctions: [Double]? = nil    // loaded in init (default: 15 s if present, else the smallest)
        public var parallelLoad = false               // background loads run concurrently (one compile per function at a time otherwise)
        public var backgroundLoad = false             // load (and on first run compile) the other functions on a background queue;
                                                      // until one is ready the next larger ready function serves its windows
        public var windowSeconds = 15.0, bandMinSeconds = 10.0, overlapSeconds = 2.0
        public var rescue = true                      // long audio only: re-decode a window when >= rescueGapSeconds of speech energy carries no word
        public var rescueMode = "halves"              // "halves" (default), "shift" (15 s window centred on the gap), "wide" (35 s window centred on the gap), "halves+shift"
        public var rescueGapSeconds = 1.5, rescueMinDensity = 2.4
        public var progress: ((String, Double) -> Void)? = nil   // (phase, seconds since init) for first-run UI: "compiling" (first run only),
                                                                 // "compiled", "loading enc_5s" (slow once per Mac), "loaded enc_5s", ...
        public init() {}
    }
    public struct Timing { public var melS = 0.0, encS = 0.0, decS = 0.0, wallS = 0.0, audioS = 0.0, windows = 0, overlapped = 0, rescued = 0, rescueTried = 0, rescueWords = 0 }
    public private(set) var timing = Timing()
    public let manifest: Manifest
    public let options: Options
    public private(set) var loadSeconds = 0.0, compileSeconds = 0.0
    public private(set) var functionLoadSeconds: [Int: Double] = [:]
    public private(set) var compiledURL: URL
    let bundle: URL
    let decoders: [TDTDecoder]
    let fastDecoder: TDTDecoder
    let fastLock = NSLock()
    let logMel = LogMel()
    var models: [Int: MLModel] = [:]
    var loading: Set<Int> = []
    let modelLock = NSLock(), timingLock = NSLock()
    let t0Init = Date()
    let bgLoads = DispatchGroup()
    /// Block until background function loads are done (first-run measurement, or an app that wants every function ready).
    public func waitForBackgroundLoads() { bgLoads.wait() }

    public static func framesFor(seconds: Double) -> Int { 1 + Int((seconds * 16000).rounded()) / 160 }
    public static func subLen(_ n: Int) -> Int { var m = n; for _ in 0..<3 { m = (m - 1) / 2 + 1 }; return m }
    public var framesRule: String { manifest.frames_rule ?? "hf" }
    public var functionSeconds: [Double] { (options.functions ?? manifest.functions_s).sorted() }
    var singleShotMax: Double { options.singleShotMaxSeconds ?? min(manifest.single_shot_max_s ?? .infinity, functionSeconds.last!) }
    var longAudioMode: String { options.longAudio ?? manifest.long_audio ?? "windows15" }

    public init(bundle: URL, options: Options = Options()) throws {
        self.bundle = bundle
        var o = options
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: bundle.appendingPathComponent("manifest.json")))
        #if os(iOS) || os(tvOS) || os(visionOS)
        if o.functions == nil { o.functions = manifest.functions_s.filter { $0 <= 15 } }
        if o.singleShotMaxSeconds == nil { o.singleShotMaxSeconds = 15 }
        #endif
        self.options = o
        var ds: [TDTDecoder] = []
        let decURL = bundle.appendingPathComponent("decoder.bin")
        let shared = try DecoderTables(url: decURL)
        for _ in 0..<max(1, o.decoderWorkers) { ds.append(try TDTDecoder(tables: shared, threads: o.decoderThreads)) }
        decoders = ds
        fastDecoder = try TDTDecoder(tables: shared, threads: max(1, o.fastDecoderThreads))
        guard ds[0].containerSHA256 == manifest.container_sha256 else { throw NSError(domain: "PhononCoreML", code: 3, userInfo: [NSLocalizedDescriptionKey: "decoder.bin was exported from a different container than the manifest; refusing"]) }
        // compile once, keep the compiled model at a STABLE path (the Neural Engine cache is keyed on path + configuration):
        // beside the bundle if writable, else ~/Library/Caches/phonon-coreml/<container sha16>-<package digest>/
        let mf = manifest.multifunction
        let p = bundle.appendingPathComponent(mf)
        let local = bundle.appendingPathComponent((mf as NSString).deletingPathExtension).appendingPathExtension("mlmodelc")
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("phonon-coreml").appendingPathComponent(Transcriber.cacheKey(bundle: bundle, manifest: manifest))
        let cached = cacheDir.appendingPathComponent((mf as NSString).deletingPathExtension).appendingPathExtension("mlmodelc")
        let tc = Date()
        if FileManager.default.fileExists(atPath: local.path) { compiledURL = local }
        else if FileManager.default.fileExists(atPath: cached.path) { compiledURL = cached }
        else {
            o.progress?("compiling", Date().timeIntervalSince(t0Init))
            let tmp = try MLModel.compileModel(at: p)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: tmp, to: cached)) != nil { compiledURL = cached } else { compiledURL = tmp }
        }
        compileSeconds = Date().timeIntervalSince(tc)
        o.progress?("compiled", Date().timeIntervalSince(t0Init))
        let fs = functionSeconds
        let eager = o.eagerFunctions ?? (fs.contains(15) ? [15] : [fs.first!])
        for s in eager where fs.contains(s) { _ = try loadFunction(Int(s)) }
        loadSeconds = Date().timeIntervalSince(t0Init)
        if o.backgroundLoad {
            let rest = fs.map { Int($0) }.filter { !eager.map { Int($0) }.contains($0) }
            modelLock.lock(); loading.formUnion(rest); modelLock.unlock()
            let par = o.parallelLoad
            bgLoads.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                if par { DispatchQueue.concurrentPerform(iterations: rest.count) { i in guard let self else { return }; _ = try? self.loadFunction(rest[i]); self.modelLock.lock(); self.loading.remove(rest[i]); self.modelLock.unlock() } }
                else { for k in rest { guard let self else { break }; _ = try? self.loadFunction(k); self.modelLock.lock(); self.loading.remove(k); self.modelLock.unlock() } }
                self?.bgLoads.leave()
            }
        }
    }
    /// The compiled-model cache key: the container (which weights) + the program itself (format, functions) + the weight blob's size.
    /// Keyed on the container alone, two packages of the same weights (another palette format, or a package that gained a function)
    /// would share one compiled model and the second would silently run the first.
    public static func cacheKey(bundle: URL, manifest: Manifest) -> String {
        let pkg = bundle.appendingPathComponent(manifest.multifunction).appendingPathComponent("Data/com.apple.CoreML")
        var h = Hasher64()
        if let spec = try? Data(contentsOf: pkg.appendingPathComponent("model.mlmodel")) { h.add(spec) }
        let wsize = (try? FileManager.default.attributesOfItem(atPath: pkg.appendingPathComponent("weights/weight.bin").path)[.size] as? NSNumber)?.int64Value ?? 0
        withUnsafeBytes(of: wsize.littleEndian) { h.add(Data($0)) }
        return String(manifest.container_sha256.prefix(16)) + "-" + String(format: "%016llx", h.value)
    }
    /// Load one function (on first use per machine this compiles it for the Neural Engine).
    @discardableResult func loadFunction(_ key: Int) throws -> MLModel {
        modelLock.lock(); if let m = models[key] { modelLock.unlock(); return m }; modelLock.unlock()
        let t = Date()
        let cfg = MLModelConfiguration(); cfg.computeUnits = options.computeUnits; cfg.functionName = "\(manifest.program_prefix)\(key)s"
        options.progress?("loading \(manifest.program_prefix)\(key)s", Date().timeIntervalSince(t0Init))
        let m = try MLModel(contentsOf: compiledURL, configuration: cfg)
        modelLock.lock(); if models[key] == nil { models[key] = m; functionLoadSeconds[key] = Date().timeIntervalSince(t) }; let r = models[key]!; modelLock.unlock()
        options.progress?("loaded \(manifest.program_prefix)\(key)s", Date().timeIntervalSince(t0Init))
        return r
    }
    /// The function for a window of `sec` seconds: the smallest one that holds it; while a background load is still running, the smallest
    /// READY function that holds it (texts are the same: every function computes the same masked encoder).
    func model(forSeconds sec: Double) throws -> (MLModel, Int) {
        let fits = functionSeconds.filter { $0 >= sec }.map { Int($0) }
        guard let want = fits.first else { throw NSError(domain: "PhononCoreML", code: 4, userInfo: [NSLocalizedDescriptionKey: "window of \(sec) s exceeds the largest encoder function"]) }
        modelLock.lock()
        if let m = models[want] { modelLock.unlock(); return (m, want) }
        if loading.contains(want), let k = fits.first(where: { models[$0] != nil }) { let m = models[k]!; modelLock.unlock(); return (m, k) }
        modelLock.unlock()
        return (try loadFunction(want), want)
    }
    /// Preload every available function (for measurement; costs resident memory).
    public func preloadAllFunctions() throws { for s in functionSeconds { try loadFunction(Int(s)) } }
    public var loadedFunctions: [Int] { modelLock.lock(); defer { modelLock.unlock() }; return models.keys.sorted() }

    // MARK: encoder
    var posCache: [Int: MLMultiArray] = [:]
    func posEmbedding(T3: Int) -> MLMultiArray {   // revision-2 bundles take the relative-position table as an input
        modelLock.lock(); defer { modelLock.unlock() }
        if let c = posCache[T3] { return c }
        let P = 2 * T3 - 1
        let a = try! MLMultiArray(shape: [1, NSNumber(value: P), 1024], dataType: .float32)
        let p = a.dataPointer.assumingMemoryBound(to: Float.self)
        for j in 0..<P {
            let pos = Double(T3 - 1 - j)
            for i in 0..<512 { let f = pos * pow(10000.0, -Double(2 * i) / 1024.0); p[j * 1024 + 2 * i] = Float(sin(f)); p[j * 1024 + 2 * i + 1] = Float(cos(f)) }
        }
        posCache[T3] = a; return a
    }
    static func fill(_ a: MLMultiArray, count: Int, _ f: (Int) -> Float) {
        if a.dataType == .float16 { let p = a.dataPointer.assumingMemoryBound(to: Float16.self); for i in 0..<count { p[i] = Float16(f(i)) } }
        else { let p = a.dataPointer.assumingMemoryBound(to: Float.self); for i in 0..<count { p[i] = f(i) } }
    }
    func hostInputs(_ feats: [Float], nFrames n: Int, T: Int, model: MLModel) throws -> MLDictionaryFeatureProvider {
        let ins = model.modelDescription.inputDescriptionsByName
        let dt = ins["mel"]?.multiArrayConstraint?.dataType ?? .float32
        let mel = try MLMultiArray(shape: [1, 128, NSNumber(value: T)], dataType: dt)
        if dt == .float16 {
            let mp = mel.dataPointer.assumingMemoryBound(to: Float16.self)
            mp.initialize(repeating: 0, count: 128 * T)
            feats.withUnsafeBufferPointer { fp in
                for f in 0..<128 {
                    var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: fp.baseAddress! + f * n), height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                    var dst = vImage_Buffer(data: UnsafeMutableRawPointer(mp + f * T), height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
                    vImageConvert_PlanarFtoPlanar16F(&src, &dst, 0)
                }
            }
        } else {
            let mp = mel.dataPointer.assumingMemoryBound(to: Float.self)
            mp.initialize(repeating: 0, count: 128 * T)
            for f in 0..<128 { for t in 0..<n { mp[f * T + t] = feats[f * n + t] } }
        }
        var lens = [n], Ts = [T]
        for _ in 0..<3 { lens.append((lens.last! - 1) / 2 + 1); Ts.append((Ts.last! - 1) / 2 + 1) }
        var d: [String: MLFeatureValue] = ["mel": MLFeatureValue(multiArray: mel)]
        for (i, name) in ["m1", "m2", "m3"].enumerated() {
            let m = try MLMultiArray(shape: [1, 1, NSNumber(value: Ts[i + 1]), 1], dataType: ins[name]?.multiArrayConstraint?.dataType ?? dt)
            let L = lens[i + 1]; Transcriber.fill(m, count: Ts[i + 1]) { $0 < L ? 1 : 0 }
            d[name] = MLFeatureValue(multiArray: m)
        }
        let km = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: Ts[3])], dataType: ins["kmask"]?.multiArrayConstraint?.dataType ?? dt)
        let L3 = lens[3]; Transcriber.fill(km, count: Ts[3]) { $0 < L3 ? 0 : -1e4 }
        d["kmask"] = MLFeatureValue(multiArray: km)
        if ins["pos"] != nil { d["pos"] = MLFeatureValue(multiArray: posEmbedding(T3: Ts[3])) }
        return try MLDictionaryFeatureProvider(dictionary: d)
    }
    func mel(_ wave: ArraySlice<Float>) -> ([Float], Int) {
        let t0 = Date(); let r = logMel.features(Array(wave), rule: framesRule)
        timingLock.lock(); timing.melS += Date().timeIntervalSince(t0); timingLock.unlock(); return r
    }
    /// Features of one window -> (projector output [n3 * 640], n3) on the Neural Engine. Thread-safe (several requests may be in flight).
    func encodeFeatures(_ feats: [Float], n: Int) throws -> ([Float], Int) {
        let sec = Double(n) * 0.01 + 0.02
        let (m, fs) = try model(forSeconds: sec); let T = Transcriber.framesFor(seconds: Double(fs))
        var n3 = n; for _ in 0..<3 { n3 = (n3 - 1) / 2 + 1 }
        var enc = [Float](repeating: 0, count: n3 * 640)
        var t1 = Date()
        try autoreleasepool {   // inputs AND outputs inside the pool: the feature-value factories return autoreleased objects (a leak per call on threads without a pool)
            let inputs = try hostInputs(feats, nFrames: n, T: T, model: m)
            t1 = Date()
            let out = try m.prediction(from: inputs).featureValue(for: "enc")!.multiArrayValue!
            let rs = out.strides.count == 3 ? out.strides[1].intValue : 640
            enc.withUnsafeMutableBufferPointer { ep in
                if out.dataType == .float16 {
                    let hp = out.dataPointer.assumingMemoryBound(to: UInt16.self)
                    if rs == 640 {
                        var src = vImage_Buffer(data: UnsafeMutableRawPointer(hp), height: 1, width: vImagePixelCount(n3 * 640), rowBytes: n3 * 640 * 2)
                        var dst = vImage_Buffer(data: UnsafeMutableRawPointer(ep.baseAddress!), height: 1, width: vImagePixelCount(n3 * 640), rowBytes: n3 * 640 * 4)
                        vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                    } else { for t in 0..<n3 { for c in 0..<640 { ep[t * 640 + c] = Float(Float16(bitPattern: hp[t * rs + c])) } } }
                } else {
                    let fp = out.dataPointer.assumingMemoryBound(to: Float.self)
                    for t in 0..<n3 { for c in 0..<640 { ep[t * 640 + c] = fp[t * rs + c] } }
                }
            }
        }
        timingLock.lock(); timing.encS += Date().timeIntervalSince(t1); timingLock.unlock()
        return (enc, n3)
    }
    /// One window -> encoder output; nil for silence.
    func encode(_ wave: ArraySlice<Float>) throws -> ([Float], Int)? {
        if Segmenter.isSilent(wave) { return nil }
        let (feats, n) = mel(wave)
        return try encodeFeatures(feats, n: n)
    }
    func decode(_ d: TDTDecoder, _ e: ([Float], Int)) -> [TimedToken] {
        let t0 = Date(); let toks = d.timedTokens(d.decodeTimed(e.0, frames: e.1))
        timingLock.lock(); timing.decS += Date().timeIntervalSince(t0); timingLock.unlock(); return toks
    }

    // MARK: pipeline
    /// Mono 16 kHz samples -> transcript with words.
    public func transcribe(_ wave: [Float]) throws -> Transcript { try transcribe(source: ArraySource(wave)) }
    /// A file read window by window (an hour of audio never sits in memory at once).
    public func transcribe(url: URL) throws -> Transcript { try transcribe(source: FileSource(url: url)) }
    public func plan(source: AudioSource) throws -> [Window] {
        let n = source.count
        if n <= Int(singleShotMax * 16000) && longAudioMode != "reference" { return [Window(start: 0, end: n, overlapFromPrevious: false, splitSample: nil)] }
        let rms = try source.blockRMS()
        if longAudioMode == "reference" { return Segmenter.plan(rms: rms, count: n).map { Window(start: $0.0, end: $0.1, overlapFromPrevious: false, splitSample: nil) } }
        return Windower.plan(rms: rms, count: n, windowS: options.windowSeconds, bandMinS: options.bandMinSeconds, overlapS: options.overlapSeconds, singleShotMaxS: singleShotMax)
    }
    public func transcribe(source: AudioSource) throws -> Transcript {
        let tStart = Date()
        let windows = try plan(source: source)
        var results = [[TimedToken]?](repeating: nil, count: windows.count)
        try run(windows: windows, source: source, into: &results)
        return finishTranscript(windows: windows, results: results, count: source.count, tStart: tStart)
    }
    /// Encode + decode `windows` (indices with a non-nil result are skipped). One window: mel -> encoder -> the multi-threaded decoder.
    /// Several: the calling thread reads + computes mel for window i while up to `encoderInFlight` Neural Engine requests run and up to
    /// `decoderWorkers` windows decode (and, if needed, rescue) on CPU threads.
    func run(windows: [Window], source: AudioSource, into results: inout [[TimedToken]?]) throws {
        let todo = windows.indices.filter { results[$0] == nil }
        if todo.isEmpty { return }
        let longAudio = windows.count > 1
        if todo.count == 1 && !longAudio {
            let w = windows[todo[0]]
            let samples = try source.read(w.start..<w.end)
            guard let e = try encode(samples[...]) else { results[todo[0]] = []; return }
            fastLock.lock(); results[todo[0]] = decode(fastDecoder, e); fastLock.unlock(); return
        }
        let lock = NSLock(); let group = DispatchGroup()
        let encQ = DispatchQueue(label: "phonon.encode", qos: .userInitiated, attributes: .concurrent)
        let decQ = DispatchQueue(label: "phonon.decode", qos: .userInitiated, attributes: .concurrent)
        let encSlots = DispatchSemaphore(value: max(1, options.encoderInFlight))
        let decSlots = DispatchSemaphore(value: decoders.count)
        var free = Array(decoders.indices); var firstError: Error? = nil
        var local = results
        for i in todo {
            let w = windows[i]
            let samples = try source.read(w.start..<w.end)
            if Segmenter.isSilent(samples[...]) { lock.lock(); local[i] = []; lock.unlock(); continue }
            let (feats, n) = mel(samples[...])
            encSlots.wait()
            group.enter()
            encQ.async { [self] in
                let e: ([Float], Int)
                do { e = try encodeFeatures(feats, n: n) } catch { lock.lock(); firstError = firstError ?? error; lock.unlock(); encSlots.signal(); group.leave(); return }
                encSlots.signal()
                decSlots.wait()
                lock.lock(); let di = free.removeLast(); lock.unlock()
                decQ.async { [self] in
                    let d = decoders[di]
                    var toks = decode(d, e)
                    if options.rescue && longAudio, let better = try? rescue(samples[...], tokens: toks, decoder: d, windowStart: w.start, source: source) { toks = better }
                    lock.lock(); local[i] = toks; free.append(di); lock.unlock()
                    decSlots.signal(); group.leave()
                }
            }
        }
        group.wait()
        if let e = firstError { throw e }
        results = local
    }
    func finishTranscript(windows: [Window], results: [[TimedToken]?], count n: Int, tStart: Date) -> Transcript {
        var words: [Word] = []; var segments: [Segment] = []; var overlapped = 0
        for (i, w) in windows.enumerated() {
            let offset = Double(w.start) / 16000, limit = Double(w.end - w.start) / 16000
            let ws = Words.fromTokens(results[i] ?? [], offset: offset, limit: limit)
            if w.overlapFromPrevious, let s = w.splitSample { Words.stitch(kept: &words, incoming: ws, split: Double(s) / 16000); overlapped += 1 }
            else { words.append(contentsOf: ws) }
            segments.append(Segment(id: i, start: (offset * 1000).rounded() / 1000, end: (Double(w.end) / 16000 * 1000).rounded() / 1000, text: ws.map { $0.text }.joined(separator: " ")))
        }
        let wall = Date().timeIntervalSince(tStart)
        timingLock.lock(); timing.wallS += wall; timing.audioS += Double(n) / 16000; timing.windows += windows.count; timing.overlapped += overlapped; timingLock.unlock()
        return Transcript(text: words.map { $0.text }.joined(separator: " "), words: words, segments: segments, audioSeconds: Double(n) / 16000, decodeSeconds: wall, windows: windows.count)
    }

    // MARK: rescue
    /// 50 ms blocks above the reference gate (max(0.004, 0.18 x peak RMS of the window)).
    static func speechBlocks(_ a: ArraySlice<Float>) -> [Bool] {
        let block = 800, n = a.count, nb = n / block; guard nb > 0 else { return [] }
        var rms = [Float](repeating: 0, count: nb); let base = a.startIndex
        for b in 0..<nb { var s: Float = 0; for i in 0..<block { let v = a[base + b * block + i]; s += v * v }; rms[b] = (s / Float(block)).squareRoot() }
        let gate = max(0.004, 0.18 * (rms.max() ?? 0)); return rms.map { $0 > gate }
    }
    /// The longest run of speech blocks (seconds) that no word covers; returns (start s, end s, speech s).
    static func worstGap(_ speech: [Bool], words: [Word], windowSeconds: Double) -> (Double, Double, Double)? {
        var covered = [Bool](repeating: false, count: speech.count)
        for w in words { let a = max(0, Int(w.start / 0.05)), b = min(speech.count, Int(w.end / 0.05) + 1); if a < b { for k in a..<b { covered[k] = true } } }
        var best: (Int, Int, Int)? = nil; var i = 0
        while i < speech.count {
            if covered[i] { i += 1; continue }
            var j = i, sp = 0
            while j < speech.count && !covered[j] { if speech[j] { sp += 1 }; j += 1 }
            if best == nil || sp > best!.2 { best = (i, j, sp) }
            i = j
        }
        guard let g = best else { return nil }
        return (Double(g.0) * 0.05, Double(g.1) * 0.05, Double(g.2) * 0.05)
    }
    /// The trigger: >= rescueGapSeconds of speech energy with no word, or fewer than rescueMinDensity words per speech-second.
    func rescueGap(_ wave: ArraySlice<Float>, tokens: [TimedToken]) -> (gap: (Double, Double, Double), words: Int)? {
        let secs = Double(wave.count) / 16000; guard secs >= 3.0 else { return nil }
        let speech = Transcriber.speechBlocks(wave); let speechS = Double(speech.filter { $0 }.count) * 0.05; guard speechS >= 2.0 else { return nil }
        let words = Words.fromTokens(tokens, offset: 0, limit: secs)
        let density = Double(words.count) / speechS
        guard let gap = Transcriber.worstGap(speech, words: words, windowSeconds: secs) else { return nil }
        guard gap.2 >= options.rescueGapSeconds || density < options.rescueMinDensity else { return nil }
        return (gap, words.count)
    }
    func rescue(_ wave: ArraySlice<Float>, tokens: [TimedToken], decoder d: TDTDecoder, windowStart: Int, source: AudioSource) throws -> [TimedToken]? {
        guard let (gap, nWords) = rescueGap(wave, tokens: tokens) else { return nil }
        timingLock.lock(); timing.rescueTried += 1; timingLock.unlock()
        var out: [TimedToken]? = nil
        switch options.rescueMode {
        case "shift": out = try rescueContext(tokens: tokens, gap: gap, windowStart: windowStart, windowCount: wave.count, seconds: 15, decoder: d, source: source)
        case "wide": out = try rescueContext(tokens: tokens, gap: gap, windowStart: windowStart, windowCount: wave.count, seconds: min(35, singleShotMax), decoder: d, source: source)
        case "halves+shift":
            out = try rescueHalves(wave, tokens: tokens, decoder: d, depth: 0)
            let cur = out ?? tokens
            if let (g2, _) = rescueGap(wave, tokens: cur), g2.2 >= options.rescueGapSeconds,
               let s = try rescueContext(tokens: cur, gap: g2, windowStart: windowStart, windowCount: wave.count, seconds: 15, decoder: d, source: source) { out = s }
        default: out = try rescueHalves(wave, tokens: tokens, decoder: d, depth: 0)
        }
        guard let o = out else { return nil }
        let newWords = Words.fromTokens(o, offset: 0, limit: Double(wave.count) / 16000).count
        guard newWords > nWords else { return nil }
        timingLock.lock(); timing.rescued += 1; timing.rescueWords += newWords - nWords; timingLock.unlock()
        return o
    }
    /// Split inside the gap at its quietest block, re-decode both halves (recursively once more), keep if more words.
    func rescueHalves(_ wave: ArraySlice<Float>, tokens: [TimedToken], decoder d: TDTDecoder, depth: Int) throws -> [TimedToken]? {
        let secs = Double(wave.count) / 16000; guard secs >= 3.0, depth < 2 else { return nil }
        guard let (gap, nWords) = rescueGap(wave, tokens: tokens) else { return nil }
        var cut = (gap.0 + gap.1) / 2
        if gap.1 - gap.0 > 0.4 {
            var bestV = Float.greatestFiniteMagnitude; let base = wave.startIndex
            var b = Int(gap.0 / 0.05) + 1
            while Double(b + 1) * 0.05 <= gap.1 { var s: Float = 0; for i in 0..<800 { let v = wave[base + b * 800 + i]; s += v * v }; if s < bestV { bestV = s; cut = Double(b) * 0.05 + 0.025 }; b += 1 }
        }
        cut = min(max(cut, 1.0), secs - 1.0); let m = wave.startIndex + Int(cut * 16000)
        var out: [TimedToken] = []
        for (a, b) in [(wave.startIndex, m), (m, wave.endIndex)] {
            let part = wave[a..<b]; var toks: [TimedToken] = []
            if let e = try encode(part) { toks = decode(d, e) }
            if let deeper = try rescueHalves(part, tokens: toks, decoder: d, depth: depth + 1) { toks = deeper }
            let off = Double(a - wave.startIndex) / 16000
            out.append(contentsOf: toks.map { TimedToken(piece: $0.piece, start: $0.start + off, duration: $0.duration) })
        }
        return Words.fromTokens(out, offset: 0, limit: secs).count > nWords ? out : nil
    }
    /// Decode a window of `seconds` centred on the gap (fresh left and right context from the file) and insert the words it hears
    /// INSIDE the gap; everything outside the gap stays as decoded.
    func rescueContext(tokens: [TimedToken], gap: (Double, Double, Double), windowStart: Int, windowCount: Int, seconds: Double, decoder d: TDTDecoder, source: AudioSource) throws -> [TimedToken]? {
        let L = Int(seconds * 16000) - 400, n = source.count
        let gA = windowStart + Int(gap.0 * 16000), gB = windowStart + Int(gap.1 * 16000)
        var s = (gA + gB) / 2 - L / 2; s = max(0, min(s, n - L)); let e = min(n, s + L)
        let samples = try source.read(s..<e)
        guard let enc = try encode(samples[...]) else { return nil }
        let newToks = decode(d, enc)
        // group the new tokens into words (same rule as Words.fromTokens) and keep whole words that start inside the gap
        var groups: [[TimedToken]] = []; var cur: [TimedToken] = []
        for t in newToks {
            let stripped = t.piece.trimmingCharacters(in: .whitespaces)
            if t.piece.hasPrefix(" ") && !cur.isEmpty && (stripped.isEmpty || !Words.isPunctuation(stripped)) { groups.append(cur); cur = [] }
            cur.append(t)
        }
        if !cur.isEmpty { groups.append(cur) }
        let shift = Double(s - windowStart) / 16000          // new-window seconds -> original-window seconds
        let lo = gap.0 - 0.05, hi = gap.1
        var add: [TimedToken] = []
        for g in groups { let st = g[0].start + shift; if st >= lo && st < hi { add.append(contentsOf: g.map { TimedToken(piece: $0.piece, start: $0.start + shift, duration: $0.duration) }) } }
        guard !add.isEmpty else { return nil }
        if !add[0].piece.hasPrefix(" ") { add[0] = TimedToken(piece: " " + add[0].piece, start: add[0].start, duration: add[0].duration) }
        var merged = tokens.filter { $0.start < lo } + add + tokens.filter { $0.start >= lo }
        merged.sort { $0.start < $1.start }
        _ = windowCount
        return merged
    }
    public func resetTiming() { timingLock.lock(); timing = Timing(); timingLock.unlock() }
}

/// FNV-1a 64 over bytes: a stable content fingerprint for the cache key (not a security hash).
struct Hasher64 {
    var value: UInt64 = 0xcbf29ce484222325
    mutating func add(_ d: Data) { d.withUnsafeBytes { for b in $0 { value ^= UInt64(b); value = value &* 0x100000001b3 } } }
}

