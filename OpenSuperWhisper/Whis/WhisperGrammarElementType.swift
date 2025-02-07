//
// Created by user on 07.02.2025.
//

import Foundation

public enum WhisperGrammarElementType: Int32 {
    case end = 0
    case alt = 1
    case ruleRef = 2
    case char = 3
    case charNot = 4
    case charRangeUpper = 5
    case charAlt = 6
}