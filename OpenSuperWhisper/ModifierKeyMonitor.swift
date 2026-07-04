import AppKit
import Carbon
import Foundation

enum ModifierKey: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case leftCommand = "leftCommand"
    case rightCommand = "rightCommand"
    case leftOption = "leftOption"
    case rightOption = "rightOption"
    case leftShift = "leftShift"
    case rightShift = "rightShift"
    case leftControl = "leftControl"
    case rightControl = "rightControl"
    case fn = "fn"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .none: return "None"
        case .leftCommand: return "Left ⌘ Command"
        case .rightCommand: return "Right ⌘ Command"
        case .leftOption: return "Left ⌥ Option"
        case .rightOption: return "Right ⌥ Option"
        case .leftShift: return "Left ⇧ Shift"
        case .rightShift: return "Right ⇧ Shift"
        case .leftControl: return "Left ⌃ Control"
        case .rightControl: return "Right ⌃ Control"
        case .fn: return "Fn"
        }
    }
    
    var shortSymbol: String {
        switch self {
        case .none: return ""
        case .leftCommand: return "⌘"
        case .rightCommand: return "⌘"
        case .leftOption: return "⌥"
        case .rightOption: return "⌥"
        case .leftShift: return "⇧"
        case .rightShift: return "⇧"
        case .leftControl: return "⌃"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        }
    }
    
    var keyCode: UInt16 {
        switch self {
        case .none: return 0
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftShift: return 56
        case .rightShift: return 60
        case .leftControl: return 59
        case .rightControl: return 62
        case .fn: return 63
        }
    }
    
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftControl, .rightControl: return .control
        case .fn: return .function
        }
    }
    
    var cgEventFlag: CGEventFlags {
        switch self {
        case .none: return []
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption: return .maskAlternate
        case .leftShift, .rightShift: return .maskShift
        case .leftControl, .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }
    
    var isCommandOrOption: Bool {
        switch self {
        case .leftCommand, .rightCommand, .leftOption, .rightOption:
            return true
        default:
            return false
        }
    }
}
