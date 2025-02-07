//
// Created by user on 07.02.2025.
//

import Foundation

public struct WhisperGrammarElement {
    public let type: WhisperGrammarElementType
    public let value: UInt32

    public init(type: WhisperGrammarElementType, value: UInt32) {
        self.type = type
        self.value = value
    }

    func toC() -> whisper_grammar_element {
        return whisper_grammar_element(type: whisper_gretype(rawValue: UInt32(type.rawValue)),
                                       value: value)
    }
}