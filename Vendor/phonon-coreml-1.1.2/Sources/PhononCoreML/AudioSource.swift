// Audio sources for the transcriber: whole arrays, or files read window by window so an hour of audio never sits in memory at once.
import AVFoundation
import Foundation

public protocol AudioSource {
    var count: Int { get }                                   // samples at 16 kHz mono
    func read(_ range: Range<Int>) throws -> [Float]         // samples of the range (mono, 16 kHz)
}

public struct ArraySource: AudioSource {
    public let samples: [Float]
    public init(_ s: [Float]) { samples = s }
    public var count: Int { samples.count }
    public func read(_ r: Range<Int>) throws -> [Float] { Array(samples[r]) }
}

/// Errors a file source reports in words a person can act on.
public enum AudioFileError: LocalizedError {
    case notFound(String), notReadable(String), conversionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "\(p): no such file"
        case .notReadable(let p): return "\(p): not an audio file this Mac can read (wav, m4a, mp3, aiff, caf and flac work)"
        case .conversionFailed(let p): return "\(p): could not convert the audio to 16 kHz mono"
        }
    }
}

/// Any audio file AVAudioFile reads (wav, m4a, mp3, aiff, caf, flac; any sample rate, any channel count). Channels are averaged.
/// 16 kHz files are read in place; other rates are converted once, streaming, to a 16 kHz mono temporary file that is removed when
/// the source is released. Reads are seeks + short reads, 10 s at a time, so an hour of audio never sits in memory at once.
public final class FileSource: AudioSource {
    public static let sampleRate = 16000.0
    let file: AVAudioFile; let channels: Int; public let count: Int
    let temporary: URL?
    let lock = NSLock()
    public init(url: URL) throws {
        let src = try FileSource.open(url)
        if src.processingFormat.sampleRate == FileSource.sampleRate { file = src; temporary = nil }
        else {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("phonon-coreml-\(UUID().uuidString).caf")
            do { try FileSource.convert(src, to: tmp) } catch { try? FileManager.default.removeItem(at: tmp); throw AudioFileError.conversionFailed(url.relativePath) }
            do { file = try AVAudioFile(forReading: tmp) } catch { try? FileManager.default.removeItem(at: tmp); throw AudioFileError.conversionFailed(url.relativePath) }
            temporary = tmp
        }
        channels = Int(file.processingFormat.channelCount); count = Int(file.length)
    }
    deinit { if let t = temporary { try? FileManager.default.removeItem(at: t) } }

    /// Opens `url` for reading, or throws `AudioFileError` (missing file, or a file that is not audio). Cheap: a caller can check every
    /// input before loading the model.
    @discardableResult public static func open(_ url: URL) throws -> AVAudioFile {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { throw AudioFileError.notFound(url.relativePath) }
        do { return try AVAudioFile(forReading: url) } catch { throw AudioFileError.notReadable(url.relativePath) }
    }

    /// Streams `src` through AVAudioConverter (channels averaged first, then the sample rate converted) into a 16 kHz mono Float32 file.
    static func convert(_ src: AVAudioFile, to out: URL) throws {
        let inFmt = src.processingFormat, ch = Int(inFmt.channelCount)
        guard let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFmt.sampleRate, channels: 1, interleaved: false),
              let monoOut = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: FileSource.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: monoIn, to: monoOut) else { throw AudioFileError.conversionFailed(src.url.path) }
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let dst = try AVAudioFile(forWriting: out, settings: monoOut.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioFrameCount(max(1024, Int(inFmt.sampleRate)))   // one second of input per read
        let outCap = AVAudioFrameCount(Double(chunk) * FileSource.sampleRate / inFmt.sampleRate) + 4096
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk),
              let monoBuf = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: monoOut, frameCapacity: outCap) else { throw AudioFileError.conversionFailed(src.url.path) }
        let feed = ConverterFeed(src: src, readBuf: readBuf, monoBuf: monoBuf, channels: ch, chunk: chunk)
        let expected = Int((Double(src.length) * FileSource.sampleRate / inFmt.sampleRate).rounded())
        var written = 0
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { n, st in feed.next(n, st) }
            if let e = feed.error { throw e }
            if status == .error { throw err ?? AudioFileError.conversionFailed(src.url.path) }
            let m = min(Int(outBuf.frameLength), max(0, expected - written))   // the converter's tail never runs past the true length
            if m > 0 { outBuf.frameLength = AVAudioFrameCount(m); try dst.write(from: outBuf); written += m }
            if status == .endOfStream || (status == .inputRanDry && outBuf.frameLength == 0) { break }
        }
    }

    public func read(_ r: Range<Int>) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        var out = [Float](repeating: 0, count: r.count); var pos = r.lowerBound
        let chunk = 16000 * 10
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(chunk, max(1, r.count))))!
        file.framePosition = AVAudioFramePosition(r.lowerBound)
        while pos < r.upperBound {
            try file.read(into: buf, frameCount: AVAudioFrameCount(min(chunk, r.upperBound - pos)))
            let m = Int(buf.frameLength); if m == 0 { break }
            let o = pos - r.lowerBound
            if let fd = buf.floatChannelData { for c in 0..<channels { let p = fd[c]; for i in 0..<m { out[o + i] += p[i] / Float(channels) } } }
            else if let id = buf.int16ChannelData { for c in 0..<channels { let p = id[c]; for i in 0..<m { out[o + i] += Float(p[i]) / 32768.0 / Float(channels) } } }
            pos += m
        }
        return out
    }
    /// The whole file, 16 kHz mono, in memory.
    public func readAll() throws -> [Float] { try read(0..<count) }
}

/// Supplies the converter one second of channel-averaged input per call, then end of stream.
final class ConverterFeed: @unchecked Sendable {
    let src: AVAudioFile, readBuf: AVAudioPCMBuffer, monoBuf: AVAudioPCMBuffer, channels: Int, chunk: AVAudioFrameCount
    var done = false; var error: Error? = nil
    init(src: AVAudioFile, readBuf: AVAudioPCMBuffer, monoBuf: AVAudioPCMBuffer, channels: Int, chunk: AVAudioFrameCount) {
        self.src = src; self.readBuf = readBuf; self.monoBuf = monoBuf; self.channels = channels; self.chunk = chunk
    }
    func next(_ n: AVAudioPacketCount, _ st: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let left = src.length - src.framePosition
        if done || left <= 0 { done = true; st.pointee = .endOfStream; return nil }
        do { try src.read(into: readBuf, frameCount: min(chunk, AVAudioFrameCount(min(Int64(max(1, n)), left)))) }
        catch { self.error = error; done = true; st.pointee = .endOfStream; return nil }
        let m = Int(readBuf.frameLength)
        if m == 0 { done = true; st.pointee = .endOfStream; return nil }
        let dst = monoBuf.floatChannelData![0], scale = 1 / Float(channels)
        if let fd = readBuf.floatChannelData {
            for i in 0..<m { dst[i] = fd[0][i] }
            if channels > 1 { for c in 1..<channels { let p = fd[c]; for i in 0..<m { dst[i] += p[i] } }; for i in 0..<m { dst[i] *= scale } }
        } else if let id = readBuf.int16ChannelData {
            for i in 0..<m { var s: Float = 0; for c in 0..<channels { s += Float(id[c][i]) }; dst[i] = s / 32768.0 * scale }
        } else { self.error = AudioFileError.conversionFailed(src.url.path); done = true; st.pointee = .endOfStream; return nil }
        monoBuf.frameLength = AVAudioFrameCount(m)
        st.pointee = .haveData; return monoBuf
    }
}

extension AudioSource {
    /// RMS of 50 ms blocks over the whole source, streamed (10 s at a time); the windower's only whole-file input.
    public func blockRMS(block: Int = 800) throws -> [Float] {
        let nBlocks = (count + block - 1) / block; var rms = [Float](repeating: 0, count: nBlocks)
        let step = 16000 * 10; var start = 0
        while start < count {
            let end = min(count, start + step); let x = try read(start..<end)
            var b = start / block
            while b * block < end {
                let lo = b * block, hi = min(end, lo + block); var s: Float = 0
                for i in lo..<hi { s += x[i - start] * x[i - start] }
                rms[b] += s / Float(block); b += 1
            }
            start = end
        }
        for i in 0..<nBlocks { rms[i] = rms[i].squareRoot() }
        return rms
    }
}

