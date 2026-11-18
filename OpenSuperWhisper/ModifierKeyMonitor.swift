import AppKit
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
    
    var isCommandOrOption: Bool {
        switch self {
        case .leftCommand, .rightCommand, .leftOption, .rightOption:
            return true
        default:
            return false
        }
    }
}

class ModifierKeyMonitor {
    static let shared = ModifierKeyMonitor()
    
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var selectedModifierKey: ModifierKey = .none
    private var isModifierPressed = false
    
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    
    init(modifierKey: ModifierKey = .none) { selectedModifierKey = modifierKey }
    
    func start(modifierKey: ModifierKey) {
        guard modifierKey != .none else {
            stop()
            return
        }
        
        stop()
        
        selectedModifierKey = modifierKey
        isModifierPressed = false
        
        // `NSEvent` global monitors are gated by Accessibility trust alone.
        // The previous `CGEvent` tap at `.cgSessionEventTap` with `.listenOnly`
        // saw the same `.flagsChanged` events but additionally required Input
        // Monitoring, so users had to grant two permissions for one hotkey.
        // The global monitor covers events going to other apps, the local one
        // covers events delivered to this app's own windows; neither consumes
        // the event, so normal Command usage is untouched.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
            return event
        }
        
        if globalMonitor == nil {
            print("ModifierKeyMonitor: Failed to install global monitor. Check accessibility permissions.")
        }
        
        print("ModifierKeyMonitor: Started monitoring for \(modifierKey.displayName)")
    }
    
    func stop() {
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        isModifierPressed = false
        print("ModifierKeyMonitor: Stopped")
    }
    
    func handleFlagsChanged(event: NSEvent) {
        handleFlagsChanged(keyCode: event.keyCode, flags: event.modifierFlags)
    }
    
    /// The press/release state machine, separated from the monitor plumbing so
    /// it can be driven without a real keyboard.
    ///
    /// `flags` is the modifier state *after* the change, and `AppKit` reports
    /// modifiers device-independently: both ⌘ keys produce `.command`. That is
    /// enough to tell the two sides apart, because `keyCode` already identifies
    /// which key changed, but not on its own to tell a press from a release:
    /// while the other side of the same pair is held, the family flag stays set
    /// for both. The event itself carries the answer — it was generated because
    /// *this* key changed — so an edge already seen in `isModifierPressed` is
    /// the release. Without that, releasing the bound side while the other side
    /// is held would leave the hold open.
    func handleFlagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard keyCode == selectedModifierKey.keyCode else { return }
        
        // `familyDown` is the state of the whole modifier family, both sides
        // included; `isModifierPressed` is the state of the bound side alone.
        // The event says the bound side changed, so a family that is still down
        // while this side was already down can only mean this side came up.
        let familyDown = flags.contains(selectedModifierKey.modifierFlag)
        let isPressed = familyDown && !isModifierPressed
        
        if isPressed {
            isModifierPressed = true
            DispatchQueue.main.async {
                self.onKeyDown?()
            }
        } else if isModifierPressed {
            isModifierPressed = false
            DispatchQueue.main.async {
                self.onKeyUp?()
            }
        }
    }
    
    deinit {
        stop()
    }
}
