// decoder.bin reader and the compiled greedy decoder (PhononTDT, a prebuilt library in Binaries/).
// The tables are parsed once (DecoderTables) into ONE C handle; every decoder (workers, the single-window handle) is a clone that
// shares those tables, so the file's 17.7 MB live once in memory. Format v2 stores the 6-bit codes packed (4 codes in 3 bytes).
import Foundation
import PhononTDT

public final class DecoderTables {
    struct Header: Decodable {
        struct Arr: Decodable { let name: String; let dtype: String; let shape: [Int]; let offset: Int; let bytes: Int }
        let format: String; let arrays: [Arr]; let vocab: [String]; let durations: [Int32]; let blank: Int32; let max_symbols: Int32
        let V: Int32; let E: Int32; let H: Int32; let nhead: Int32; let container_sha256: String
    }
    let header: Header
    let base: UnsafeMutableRawPointer
    public var vocab: [String] { header.vocab }
    public var containerSHA256: String { header.container_sha256 }

    public init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        let hlen = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        let header = try JSONDecoder().decode(Header.self, from: d.subdata(in: 4..<(4 + hlen)))
        self.header = header
        guard header.format == "phonon2-decoder-bin-v1" || header.format == "phonon2-decoder-bin-v2" else { throw NSError(domain: "PhononCoreML", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown decoder.bin format \(header.format)"]) }
        var idx: [String: Header.Arr] = [:]; for a in header.arrays { idx[a.name] = a }
        let body = 4 + hlen
        var unpacked: [String: [Int8]] = [:]          // v2: 6-bit packed codes -> int8 (temporary; the C side copies)
        for a in header.arrays where a.dtype == "int6p" {
            let n = a.shape.reduce(1, *); var out = [Int8](repeating: 0, count: n)
            d.withUnsafeBytes { raw in
                let p = raw.baseAddress!.advanced(by: body + a.offset).assumingMemoryBound(to: UInt8.self)
                var i = 0, j = 0
                while i < n {   // 4 codes (two's complement 6 bit) in 3 bytes, little-endian bit order
                    let w = UInt32(p[j]) | (UInt32(p[j + 1]) << 8) | (UInt32(p[j + 2]) << 16)
                    for k in 0..<4 where i + k < n { let v = Int32((w >> (6 * UInt32(k))) & 63); out[i + k] = Int8(v >= 32 ? v - 64 : v) }
                    i += 4; j += 3
                }
            }
            unpacked[a.name] = out
        }
        var keep: [[Int8]] = []
        func p(_ n: String) -> UnsafeRawPointer {
            if let u = unpacked[n] { keep.append(u); return keep.last!.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress!) } }
            return d.withUnsafeBytes { $0.baseAddress! }.advanced(by: body + idx[n]!.offset)
        }
        var durs = header.durations
        let h = durs.withUnsafeMutableBufferPointer { dp in
            phonon2_tdt_create(header.V, header.E, header.H, header.nhead, Int32(header.durations.count), dp.baseAddress, header.blank, header.max_symbols,
                p("decoder.embedding.weight.q").assumingMemoryBound(to: Int8.self), p("decoder.embedding.weight.scale").assumingMemoryBound(to: UInt16.self),
                p("decoder.lstm.weight_ih_l0.q").assumingMemoryBound(to: Int8.self), p("decoder.lstm.weight_ih_l0.scale").assumingMemoryBound(to: UInt16.self), p("decoder.lstm.bias_ih_l0").assumingMemoryBound(to: UInt16.self),
                p("decoder.lstm.weight_hh_l0.q").assumingMemoryBound(to: Int8.self), p("decoder.lstm.weight_hh_l0.scale").assumingMemoryBound(to: UInt16.self), p("decoder.lstm.bias_hh_l0").assumingMemoryBound(to: UInt16.self),
                p("decoder.lstm.weight_ih_l1.q").assumingMemoryBound(to: Int8.self), p("decoder.lstm.weight_ih_l1.scale").assumingMemoryBound(to: UInt16.self), p("decoder.lstm.bias_ih_l1").assumingMemoryBound(to: UInt16.self),
                p("decoder.lstm.weight_hh_l1.q").assumingMemoryBound(to: Int8.self), p("decoder.lstm.weight_hh_l1.scale").assumingMemoryBound(to: UInt16.self), p("decoder.lstm.bias_hh_l1").assumingMemoryBound(to: UInt16.self),
                p("decoder.decoder_projector.weight.q").assumingMemoryBound(to: Int8.self), p("decoder.decoder_projector.weight.scale").assumingMemoryBound(to: UInt16.self), p("decoder.decoder_projector.bias").assumingMemoryBound(to: UInt16.self),
                p("joint.head.weight.q").assumingMemoryBound(to: Int8.self), p("joint.head.weight.scale").assumingMemoryBound(to: UInt16.self), p("joint.head.bias").assumingMemoryBound(to: UInt16.self))
        }
        withExtendedLifetime(keep) {}
        guard let h else { throw NSError(domain: "PhononCoreML", code: 2, userInfo: [NSLocalizedDescriptionKey: "phonon2_tdt_create failed"]) }
        base = h
    }
    deinit { phonon2_tdt_destroy(base) }
}

public final class TDTDecoder {
    let tables: DecoderTables
    var handle: UnsafeMutableRawPointer?
    public var vocab: [String] { tables.vocab }
    public var containerSHA256: String { tables.containerSHA256 }

    public convenience init(url: URL, threads: Int32 = 1) throws { try self.init(tables: DecoderTables(url: url), threads: threads) }
    public init(tables: DecoderTables, threads: Int32 = 1) throws {
        self.tables = tables
        handle = phonon2_tdt_clone(tables.base)
        guard handle != nil else { throw NSError(domain: "PhononCoreML", code: 2, userInfo: [NSLocalizedDescriptionKey: "phonon2_tdt_clone failed"]) }
        phonon2_tdt_handle_threads(handle, threads)
    }
    public func setThreads(_ n: Int32) { phonon2_tdt_handle_threads(handle, n) }
    deinit { if let h = handle { phonon2_tdt_destroy(h) } }

    /// enc: [T * 640] Float row-major (projector output, true frames only). Returns token ids.
    public func decode(_ enc: [Float], frames T: Int) -> [Int32] {
        var out = [Int32](repeating: 0, count: max(64, 12 * T))
        let n = enc.withUnsafeBufferPointer { ep in out.withUnsafeMutableBufferPointer { op in phonon2_tdt_decode(handle, ep.baseAddress, Int32(T), op.baseAddress, Int32(op.count)) } }
        return Array(out[0..<Int(n)])
    }
    /// Timed decode: token ids with the encoder frame (80 ms) each was emitted at and its predicted duration in frames.
    public func decodeTimed(_ enc: [Float], frames T: Int) -> (tokens: [Int32], frame: [Int32], duration: [Int32]) {
        let cap = max(64, 12 * T)
        var out = [Int32](repeating: 0, count: cap), fr = [Int32](repeating: 0, count: cap), du = [Int32](repeating: 0, count: cap)
        let n = enc.withUnsafeBufferPointer { ep in out.withUnsafeMutableBufferPointer { op in fr.withUnsafeMutableBufferPointer { fp in du.withUnsafeMutableBufferPointer { dp in
            phonon2_tdt_decode_timed(handle, ep.baseAddress, Int32(T), op.baseAddress, fp.baseAddress, dp.baseAddress, Int32(cap)) } } } }
        return (Array(out[0..<Int(n)]), Array(fr[0..<Int(n)]), Array(du[0..<Int(n)]))
    }
    /// Pieces with the SentencePiece marker turned into a leading space; special tokens dropped (the pip engines' token text).
    public func timedTokens(_ d: (tokens: [Int32], frame: [Int32], duration: [Int32])) -> [TimedToken] {
        var out: [TimedToken] = []
        for i in 0..<d.tokens.count {
            let piece = vocab[Int(d.tokens[i])]
            if (piece.hasPrefix("<|") && piece.hasSuffix("|>")) || piece == "<unk>" || piece == "<pad>" { continue }
            out.append(TimedToken(piece: piece.replacingOccurrences(of: "\u{2581}", with: " "), start: Double(d.frame[i]) * Words.frameS, duration: Double(d.duration[i]) * Words.frameS))
        }
        return out
    }
    public func text(_ toks: [Int32]) -> String {
        var s = ""
        for t in toks {
            let piece = vocab[Int(t)]
            if (piece.hasPrefix("<|") && piece.hasSuffix("|>")) || piece == "<unk>" || piece == "<pad>" { continue }
            s += piece
        }
        return s.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

