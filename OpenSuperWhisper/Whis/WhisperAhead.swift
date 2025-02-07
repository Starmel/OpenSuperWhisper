//
// Created by user on 07.02.2025.
//

import Foundation

public struct WhisperAhead {
    public let nTextLayer: Int32
    public let nHead: Int32

    public init(nTextLayer: Int32, nHead: Int32) {
        self.nTextLayer = nTextLayer
        self.nHead = nHead
    }

    func toC() -> whisper_ahead {
        return whisper_ahead(n_text_layer: nTextLayer,
                             n_head: nHead)
    }

    static func fromC(_ cAhead: whisper_ahead) -> WhisperAhead {
        return WhisperAhead(nTextLayer: cAhead.n_text_layer,
                            nHead: cAhead.n_head)
    }
}