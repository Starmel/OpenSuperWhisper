//
// Created by user on 07.02.2025.
//

import Foundation

public struct WhisperAheads {
    public let heads: [WhisperAhead]

    public init(heads: [WhisperAhead]) {
        self.heads = heads
    }

    func toC() -> whisper_aheads {
        var cHeads = heads.map { $0.toC() }
        return cHeads.withUnsafeMutableBufferPointer { buffer in
            whisper_aheads(n_heads: heads.count, heads: buffer.baseAddress)
        }
    }

    static func fromC(_ cAheads: whisper_aheads) -> WhisperAheads {
        let buffer = UnsafeBufferPointer(start: cAheads.heads, count: cAheads.n_heads)
        let heads = buffer.map { WhisperAhead.fromC($0) }
        return WhisperAheads(heads: heads)
    }
}