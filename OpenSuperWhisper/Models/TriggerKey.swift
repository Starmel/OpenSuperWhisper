import Foundation

enum TriggerKeyKind: String, Codable {
    case modifier
    case regular
}

/// One bare key used by the event-tap trigger path.
struct TriggerKey: Codable, Equatable, Hashable, Identifiable {
    var keyCode: UInt16
    var kind: TriggerKeyKind
    var displayName: String
    var symbol: String

    var id: String { "\(kind.rawValue)-\(keyCode)" }

    /// Device-dependent CGEventFlags raw bits, distinct per physical key (left vs right).
    /// Unlike the aggregate masks (`.maskCommand` etc.), these let us tell which side
    /// changed, so a release of one ⌘ is detected even while the other ⌘ is held.
    private static let deviceMaskByKeyCode: [UInt16: UInt64] = [
        55: 0x0000_0008, // NX_DEVICELCMDKEYMASK
        54: 0x0000_0010, // NX_DEVICERCMDKEYMASK
        58: 0x0000_0020, // NX_DEVICELALTKEYMASK
        61: 0x0000_0040, // NX_DEVICERALTKEYMASK
        56: 0x0000_0002, // NX_DEVICELSHIFTKEYMASK
        60: 0x0000_0004, // NX_DEVICERSHIFTKEYMASK
        59: 0x0000_0001, // NX_DEVICELCTLKEYMASK
        62: 0x0000_2000, // NX_DEVICERCTLKEYMASK
        63: 0x0080_0000, // maskSecondaryFn (no left/right distinction)
    ]

    /// Whether the modifier identified by `keyCode` is currently pressed, given a
    /// CGEvent flags raw value. Returns nil if `keyCode` is not a known modifier.
    static func isModifierPressed(keyCode: UInt16, flagsRawValue: UInt64) -> Bool? {
        guard let mask = deviceMaskByKeyCode[keyCode] else { return nil }
        return (flagsRawValue & mask) != 0
    }

    /// Human-readable label + symbol for a non-modifier key code, US-ANSI layout.
    /// Falls back to a generic label for unmapped codes.
    static func regularKeyLabel(forKeyCode keyCode: UInt16) -> (name: String, symbol: String) {
        if let known = regularKeyNames[keyCode] {
            return known
        }
        return ("Key \(keyCode)", "⌨")
    }

    private static let regularKeyNames: [UInt16: (name: String, symbol: String)] = [
        36: ("Return", "⏎"), 48: ("Tab", "⇥"), 49: ("Space", "␣"),
        51: ("Delete", "⌫"), 53: ("Escape", "⎋"), 71: ("Clear", "⌧"),
        76: ("Enter", "⌅"), 117: ("Forward Delete", "⌦"),
        114: ("Help", "?"), 115: ("Home", "↖"), 116: ("Page Up", "⇞"),
        119: ("End", "↘"), 121: ("Page Down", "⇟"),
        123: ("Left", "←"), 124: ("Right", "→"), 125: ("Down", "↓"), 126: ("Up", "↑"),
        // Function row
        122: ("F1", "F1"), 120: ("F2", "F2"), 99: ("F3", "F3"), 118: ("F4", "F4"),
        96: ("F5", "F5"), 97: ("F6", "F6"), 98: ("F7", "F7"), 100: ("F8", "F8"),
        101: ("F9", "F9"), 109: ("F10", "F10"), 103: ("F11", "F11"), 111: ("F12", "F12"),
        105: ("F13", "F13"), 107: ("F14", "F14"), 113: ("F15", "F15"), 106: ("F16", "F16"),
        64: ("F17", "F17"), 79: ("F18", "F18"), 80: ("F19", "F19"), 90: ("F20", "F20"),
        // Letters
        0: ("A", "A"), 11: ("B", "B"), 8: ("C", "C"), 2: ("D", "D"), 14: ("E", "E"),
        3: ("F", "F"), 5: ("G", "G"), 4: ("H", "H"), 34: ("I", "I"), 38: ("J", "J"),
        40: ("K", "K"), 37: ("L", "L"), 46: ("M", "M"), 45: ("N", "N"), 31: ("O", "O"),
        35: ("P", "P"), 12: ("Q", "Q"), 15: ("R", "R"), 1: ("S", "S"), 17: ("T", "T"),
        32: ("U", "U"), 9: ("V", "V"), 13: ("W", "W"), 7: ("X", "X"), 16: ("Y", "Y"), 6: ("Z", "Z"),
        // Number row
        29: ("0", "0"), 18: ("1", "1"), 19: ("2", "2"), 20: ("3", "3"), 21: ("4", "4"),
        23: ("5", "5"), 22: ("6", "6"), 26: ("7", "7"), 28: ("8", "8"), 25: ("9", "9"),
    ]
}

extension TriggerKey {
    /// Bridge from the existing modifier catalog (used by migration + the picker).
    init(modifierKey: ModifierKey) {
        self.init(
            keyCode: modifierKey.keyCode,
            kind: .modifier,
            displayName: modifierKey.displayName,
            symbol: modifierKey.shortSymbol
        )
    }
}
