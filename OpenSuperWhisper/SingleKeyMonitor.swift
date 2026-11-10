import AppKit
import KeyboardShortcuts

/// Watches one plain key (any key code, e.g. the apostrophe) and uses it purely as
/// a recording trigger. The bound key is consumed so it does not also type; the key
/// combined with ⌘/⌥/⌃/⇧ passes through untouched (so ⇧' still types a quote).
class SingleKeyMonitor {
    static let shared = SingleKeyMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyCode: Int = -1
    private var isKeyPressed = false

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    init(keyCode: Int = -1) { self.keyCode = keyCode }

    @MainActor static func displayName(for keyCode: Int) -> String {
        keyCode < 0 ? "" : KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode).description
    }

    func start(keyCode: Int) {
        stop()
        guard keyCode >= 0 else { return }
        self.keyCode = keyCode

        let eventMask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SingleKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let consumed = monitor.handle(
                    isDown: type == .keyDown,
                    keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                    flags: event.flags,
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("SingleKeyMonitor: Failed to create event tap. Check accessibility permissions.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("SingleKeyMonitor: Started monitoring key code \(keyCode)")
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isKeyPressed = false
    }

    /// Returns `true` when the event belongs to the bound key and should be consumed.
    func handle(isDown: Bool, keyCode: Int, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        guard keyCode == self.keyCode else { return false }
        if isDown {
            if isKeyPressed { return true } // auto-repeat while held
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            guard flags.intersection(modifiers).isEmpty, !isRepeat else { return false }
            isKeyPressed = true
            DispatchQueue.main.async { self.onKeyDown?() }
            return true
        }
        guard isKeyPressed else { return false }
        isKeyPressed = false
        DispatchQueue.main.async { self.onKeyUp?() }
        return true
    }

    deinit { stop() }
}
