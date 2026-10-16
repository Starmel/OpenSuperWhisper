// Words with timings from decoder tokens (the pip engine's rule, fermion._speech.segment.words_from_tokens) and the word-level
// stitch across an overlapped window boundary.
import Foundation

public struct Word: Codable, Equatable {
    public let text: String
    public let start: Double   // seconds from the start of the file
    public let end: Double
}
public struct Segment: Codable, Equatable { public let id: Int; public let start: Double; public let end: Double; public let text: String }

public struct TimedToken { public let piece: String; public let start: Double; public let duration: Double }   // seconds, window-relative; piece has "▁" as " "

enum Words {
    static let frameS = 0.08   // 8 x 10 ms after the three stride-2 stages

    static func isPunctuation(_ s: String) -> Bool { !s.isEmpty && !s.contains(where: { $0.isLetter || $0.isNumber }) }

    /// pip rule: a token with a leading space starts a word unless it is only punctuation (then it joins the word before); ends are
    /// clamped to `limit` (the window length) and never before the start; offset = the window's position in the file.
    static func fromTokens(_ toks: [TimedToken], offset: Double, limit: Double?) -> [Word] {
        var words: [Word] = []; var cur: [TimedToken] = []
        func flush() {
            guard !cur.isEmpty else { return }
            let text = cur.map { $0.piece }.joined().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                var end = cur.last!.start + cur.last!.duration
                if let l = limit { end = min(end, l) }
                let s = cur.first!.start
                words.append(Word(text: text, start: ((s + offset) * 1000).rounded() / 1000, end: ((max(end, s) + offset) * 1000).rounded() / 1000))
            }
            cur.removeAll(keepingCapacity: true)
        }
        for t in toks {
            let startsWord = t.piece.hasPrefix(" ")
            let stripped = t.piece.trimmingCharacters(in: .whitespaces)
            if startsWord && !cur.isEmpty && (stripped.isEmpty || !isPunctuation(stripped)) { flush() }
            cur.append(t)
        }
        flush()
        return words
    }

    /// Stitch window B's words onto the words kept so far at an overlapped boundary whose ownership passes at `split` seconds:
    /// the earlier window keeps words that START before the split; B keeps words that start at or after split - jitter and whose
    /// span does not intersect a word already kept from the earlier window (so a word both windows heard is kept once, by the
    /// window that had it with more right context, and a word only one window heard is kept by that window).
    static func stitch(kept: inout [Word], incoming: [Word], split: Double, jitter: Double = 0.25) {
        // 1) the earlier window owns only up to the split
        while let last = kept.last, last.start >= split { kept.removeLast() }
        // 2) B's words from split - jitter on, minus time-overlaps with what A kept near the seam
        var seamA: [Word] = []
        var k = kept.count - 1
        while k >= 0 && kept[k].end > split - jitter - 0.5 { seamA.append(kept[k]); k -= 1 }
        for w in incoming where w.start >= split - jitter {
            var dup = false
            for a in seamA {
                let ovStart = max(a.start, w.start), ovEnd = min(a.end, w.end)
                if ovStart >= ovEnd + 1e-9 { continue }                       // no time overlap
                let sameText = a.text.lowercased() == w.text.lowercased()
                let shorter: Double = min(a.end - a.start, w.end - w.start)
                let ov: Double = ovEnd - ovStart
                if sameText || ov > 0.5 * shorter { dup = true; break }
            }
            if !dup { kept.append(w) }
        }
    }
}

