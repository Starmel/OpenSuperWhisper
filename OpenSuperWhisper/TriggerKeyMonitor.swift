import AppKit
import CoreGraphics
import Foundation

enum TriggerEvent: Equatable {
    case flagsChanged(keyCode: UInt16, pressed: Bool)
    case keyDown(UInt16)
    case keyUp(UInt16)
}

enum TriggerAction: Equatable {
    case none
    case fireDown
    case fireUp
}

/// Pure state machine: first monitored key down -> fireDown; last monitored key up -> fireUp.
struct TriggerDispatchState {
    let monitored: Set<UInt16>
    private(set) var pressed: Set<UInt16> = []

    init(monitored: Set<UInt16>) {
        self.monitored = monitored
    }

    mutating func handle(_ event: TriggerEvent) -> TriggerAction {
        switch event {
        case let .flagsChanged(keyCode, pressed):
            guard monitored.contains(keyCode) else { return .none }
            return pressed ? down(keyCode) : up(keyCode)
        case let .keyDown(keyCode):
            guard monitored.contains(keyCode) else { return .none }
            return down(keyCode)
        case let .keyUp(keyCode):
            guard monitored.contains(keyCode) else { return .none }
            return up(keyCode)
        }
    }

    private mutating func down(_ keyCode: UInt16) -> TriggerAction {
        guard !pressed.contains(keyCode) else { return .none } // autorepeat / dup
        let wasEmpty = pressed.isEmpty
        pressed.insert(keyCode)
        return wasEmpty ? .fireDown : .none
    }

    private mutating func up(_ keyCode: UInt16) -> TriggerAction {
        guard pressed.contains(keyCode) else { return .none }
        pressed.remove(keyCode)
        return pressed.isEmpty ? .fireUp : .none
    }
}

final class TriggerKeyMonitor {
    static let shared = TriggerKeyMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var state = TriggerDispatchState(monitored: [])
    private var keysByCode: [UInt16: TriggerKey] = [:]

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private init() {}

    var isRunning: Bool { eventTap != nil }

    func start(keys: Set<TriggerKey>) {
        stop()
        guard !keys.isEmpty else { return }

        keysByCode = Dictionary(keys.map { ($0.keyCode, $0) }, uniquingKeysWith: { first, _ in first })
        state = TriggerDispatchState(monitored: Set(keys.map { $0.keyCode }))

        var mask: CGEventMask = 0
        if keys.contains(where: { $0.kind == .modifier }) {
            mask |= (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        }
        if keys.contains(where: { $0.kind == .regular }) {
            mask |= (CGEventMask(1) << CGEventType.keyDown.rawValue)
            mask |= (CGEventMask(1) << CGEventType.keyUp.rawValue)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<TriggerKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }
                if type == .tapDisabledByUserInput {
                    monitor.handleTapDisabledByUser()
                    return Unmanaged.passUnretained(event)
                }
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("TriggerKeyMonitor: Failed to create event tap. Check Input Monitoring permission.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            // Pin to the main run loop so events are always delivered on main,
            // regardless of which thread start() ran on.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("TriggerKeyMonitor: Started monitoring \(keys.count) key(s)")
        }
    }

    func stop() {
        let wasPressed = !state.pressed.isEmpty
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        state = TriggerDispatchState(monitored: [])
        keysByCode = [:]
        // If we tore down while a trigger was held, the release will never arrive —
        // synthesize an up so hold-to-record can't get stuck recording.
        if wasPressed { fire(.fireUp) }
    }

    private func reenableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// The user revoked Input Monitoring (or otherwise disabled the tap by input):
    /// re-enabling won't succeed, so release any held trigger and reset state.
    private func handleTapDisabledByUser() {
        stop()
    }

    private func fire(_ action: TriggerAction) {
        DispatchQueue.main.async { [weak self] in
            switch action {
            case .fireDown: self?.onKeyDown?()
            case .fireUp: self?.onKeyUp?()
            case .none: break
            }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keysByCode[keyCode] != nil else { return }

        let triggerEvent: TriggerEvent
        switch type {
        case .flagsChanged:
            // Side-specific detection: a release of one ⌘ is seen even if the other ⌘ is held.
            guard let pressed = TriggerKey.isModifierPressed(
                keyCode: keyCode, flagsRawValue: event.flags.rawValue
            ) else { return }
            triggerEvent = .flagsChanged(keyCode: keyCode, pressed: pressed)
        case .keyDown:
            triggerEvent = .keyDown(keyCode)
        case .keyUp:
            triggerEvent = .keyUp(keyCode)
        default:
            return
        }

        let action = state.handle(triggerEvent)
        guard action != .none else { return }
        fire(action)
    }

    deinit { stop() }
}
