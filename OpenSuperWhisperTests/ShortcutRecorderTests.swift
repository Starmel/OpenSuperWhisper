import AppKit
import KeyboardShortcuts
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The Settings sheet's shortcut recorder, driven in this process.
///
/// The recorder is an AppKit view whose keyboard monitor only exists once it is
/// the window's first responder, so this case presents the sheet the app
/// presents — the real `SettingsView`, as a sheet on a window of the app's own
/// shape — clicks the field with a synthetic mouse event and presses a
/// combination on the app's own event path. Nothing here touches the window
/// server, the screen or another application.
///
/// The click goes through `NSWindow.sendEvent`, which is what makes the view
/// hierarchy decide who receives it — the defect this covers was exactly a click
/// that ended up somewhere else. The keystroke goes through `NSApp.sendEvent`,
/// the app-level path a real key press takes after the window server has handed
/// it over, so the recorder's local monitor sees it. (`NSApp.postEvent` does not
/// reach a process that is not the active application: measured on this machine,
/// a posted key was seen neither by a probe monitor nor by the field editor.)
///
/// A recorded shortcut is not an `AppPreferences` value: it is the library's own
/// storage in `UserDefaults.standard`, which stays the app's domain even under
/// test. Every case here therefore plants that one key and restores it.
@MainActor
final class ShortcutRecorderTests: XCTestCase {

    private static let shortcutDefaultsKey = "KeyboardShortcuts_toggleRecord"

    private func runLoopTurn(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The recorder inside a view tree, by its class name: the app never names
    /// the type, so the type is what has to be looked for.
    private func recorders(in view: NSView?) -> [NSSearchField] {
        guard let view else { return [] }
        var found: [NSSearchField] = []
        if String(describing: type(of: view)).contains("RecorderCocoa"), let field = view as? NSSearchField {
            found.append(field)
        }
        for subview in view.subviews {
            found.append(contentsOf: recorders(in: subview))
        }
        return found
    }

    /// Presents `SettingsView` the way `ContentView` does — a sheet on a window
    /// shaped like the main window — and hands back both windows.
    private func presentSettingsSheet(tabIndex: Int = 0) throws -> (parent: NSWindow, sheet: NSWindow) {
        let parent = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 450, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        parent.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SettingsSheetHost(tabIndex: tabIndex))
        hosting.sizingOptions = []
        parent.contentView = hosting
        parent.orderFrontRegardless()

        var sheet: NSWindow?
        let deadline = Date().addingTimeInterval(6)
        while sheet == nil, Date() < deadline {
            runLoopTurn(0.05)
            sheet = parent.attachedSheet
        }
        guard let sheet else {
            parent.close()
            throw XCTSkip("the Settings sheet never appeared")
        }
        runLoopTurn(0.8)
        return (parent, sheet)
    }

    private func close(_ windows: (parent: NSWindow, sheet: NSWindow)) {
        windows.parent.endSheet(windows.sheet)
        windows.sheet.close()
        windows.parent.close()
        runLoopTurn(0.2)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: location,
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber,
                           context: nil,
                           eventNumber: 1,
                           clickCount: 1,
                           pressure: 1)!
    }

    /// Clicks `view` the way a person does: a mouse down and up at the same point
    /// inside it.
    private func click(_ view: NSView, in window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        window.sendEvent(mouseEvent(.leftMouseDown, at: point, in: window))
        runLoopTurn(0.1)
        window.sendEvent(mouseEvent(.leftMouseUp, at: point, in: window))
        runLoopTurn(0.3)
    }

    /// Presses ⌥⇧K on the app's key path.
    private func pressOptionShiftK(in window: NSWindow) {
        let point = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        let event = NSEvent.keyEvent(with: .keyDown,
                                     location: point,
                                     modifierFlags: [.option, .shift],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber,
                                     context: nil,
                                     characters: "K",
                                     charactersIgnoringModifiers: "k",
                                     isARepeat: false,
                                     keyCode: 40)!
        NSApp.sendEvent(event)
        runLoopTurn(0.3)
    }

    /// The library reports its own recording state, which is the only honest sign
    /// that its monitor exists at all.
    private func recorderActivity(_ body: () -> Void) -> [Bool] {
        var events: [Bool] = []
        let probe = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange"),
            object: nil,
            queue: nil
        ) { note in
            events.append((note.userInfo?["isActive"] as? Bool) ?? false)
        }
        defer { NotificationCenter.default.removeObserver(probe) }
        body()
        return events
    }

    // MARK: - The defect

    /// Clicking the recorder has to start it listening, and the combination the
    /// user presses has to end up recorded and shown — that is the whole of
    /// “recording a shortcut works”.
    ///
    /// Before the fix the click left the field editor in charge: the recorder's
    /// monitor was never installed (the library reported no recording at all, see
    /// `testTheLibraryRecorderAsItComesCapturesNothing`), and ⌥⇧K was inserted into
    /// the field as the text “K” with nothing stored.
    func testClickingTheRecorderCapturesThePressedCombination() throws {
        let planted = UserDefaults.standard.object(forKey: Self.shortcutDefaultsKey)
        defer {
            if let planted {
                UserDefaults.standard.set(planted, forKey: Self.shortcutDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.shortcutDefaultsKey)
            }
        }
        UserDefaults.standard.set(false, forKey: Self.shortcutDefaultsKey)

        let windows = try presentSettingsSheet()
        defer { close(windows) }

        guard let field = recorders(in: windows.sheet.contentView).first else {
            throw XCTSkip("the Settings sheet has no shortcut recorder")
        }

        let recording = recorderActivity { click(field, in: windows.sheet) }
        TestFixtures.report("[recorder] after clicking the field: recording=\(recording) "
                            + "firstResponder=\(String(describing: type(of: windows.sheet.firstResponder!)))")
        XCTAssertTrue(recording.contains(true), "clicking the recorder did not start it listening")

        pressOptionShiftK(in: windows.sheet)
        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord)
        // What was pressed, described without naming this machine's keyboard
        // layout: the combination itself, and the text the library renders for it.
        let pressed = KeyboardShortcuts.Shortcut(.k, modifiers: [.option, .shift])
        TestFixtures.report("[recorder] after ⌥⇧K: stored=\(String(describing: shortcut)) "
                            + "shown=\(String(describing: field.stringValue))")

        XCTAssertEqual(shortcut?.carbonKeyCode, pressed.carbonKeyCode, "the pressed key was not recorded")
        XCTAssertEqual(shortcut?.carbonModifiers, pressed.carbonModifiers, "the pressed modifiers were not recorded")
        XCTAssertEqual(field.stringValue, pressed.description, "the recorder does not show the combination it recorded")
    }

    /// The control: the library's recorder used as the app used it — no host,
    /// nothing in the way. Kept as a case so that the reason the host exists
    /// cannot quietly stop being true: as it comes, a click captures nothing and
    /// the combination is typed into the field as text.
    ///
    /// Only the two user-visible facts are asserted. The library's own recording
    /// trace is reported rather than asserted: around window setup it is racy
    /// (measured here: it starts and stops again before anything is clicked), and
    /// it is not what the user sees.
    func testTheLibraryRecorderAsItComesCapturesNothing() throws {
        let planted = UserDefaults.standard.object(forKey: Self.shortcutDefaultsKey)
        defer {
            if let planted {
                UserDefaults.standard.set(planted, forKey: Self.shortcutDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.shortcutDefaultsKey)
            }
        }
        UserDefaults.standard.set(false, forKey: Self.shortcutDefaultsKey)

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 120),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: KeyboardShortcuts.Recorder("", name: .toggleRecord))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.orderFrontRegardless()
        runLoopTurn(0.8)
        defer { window.close(); runLoopTurn(0.2) }

        guard let field = recorders(in: window.contentView).first else { throw XCTSkip("no recorder") }

        let recording = recorderActivity { click(field, in: window) }
        TestFixtures.report("[recorder] the library's recorder as it comes, clicked: recording=\(recording)")

        pressOptionShiftK(in: window)
        TestFixtures.report("[recorder] the library's recorder as it comes, after ⌥⇧K: "
                            + "stored=\(String(describing: KeyboardShortcuts.getShortcut(for: .toggleRecord))) "
                            + "typed=\(String(describing: field.stringValue))")
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .toggleRecord),
                     "the library's recorder captured a combination after all — check whether the host "
                     + "in Settings.swift is still needed")
        XCTAssertEqual(field.stringValue, "K", "the pressed combination did not land in the field as text")
    }

    // MARK: - The mode that could be selected with nothing behind it

    /// Choosing the key-combination mode used to be able to leave the app with no
    /// trigger at all: the picker wipes the modifier hotkey, and the library's
    /// stored `false` — what it writes when a combination is cleared — keeps
    /// `Name.init` from ever applying the initial this app declares. The mode is
    /// the one the user picked, so `ShortcutManager` arms its declared
    /// combination instead of monitoring nothing.
    func testKeyCombinationModeIsArmedWhenNothingIsStored() {
        let plantedModifier = AppPreferences.shared.modifierOnlyHotkey
        let plantedMouse = AppPreferences.shared.mouseButtonHotkey
        let plantedShortcut = UserDefaults.standard.object(forKey: Self.shortcutDefaultsKey)
        defer {
            AppPreferences.shared.modifierOnlyHotkey = plantedModifier
            AppPreferences.shared.mouseButtonHotkey = plantedMouse
            if let plantedShortcut {
                UserDefaults.standard.set(plantedShortcut, forKey: Self.shortcutDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.shortcutDefaultsKey)
            }
            ModifierKeyMonitor.shared.stop()
        }

        AppPreferences.shared.modifierOnlyHotkey = ModifierKey.none.rawValue
        AppPreferences.shared.mouseButtonHotkey = MouseButton.none.rawValue
        UserDefaults.standard.set(false, forKey: Self.shortcutDefaultsKey)

        let manager = ShortcutManager()
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord)
        TestFixtures.report("[trigger] key-combination mode, nothing stored: shortcut=\(String(describing: shortcut)) "
                            + "armed=\(KeyboardShortcuts.isEnabled(for: .toggleRecord))")
        XCTAssertNotNil(shortcut, "the key-combination mode was left with no shortcut")
        XCTAssertTrue(KeyboardShortcuts.isEnabled(for: .toggleRecord),
                      "the key-combination mode was left with no armed trigger")

        // What the recorder does with what the user pressed: the combination is
        // stored under the same name, and the mode has to end up armed on it.
        let recorded = KeyboardShortcuts.Shortcut(.k, modifiers: [.option, .shift])
        KeyboardShortcuts.setShortcut(recorded, for: .toggleRecord)
        TestFixtures.report("[trigger] a combination recorded in that mode: "
                            + "shortcut=\(String(describing: KeyboardShortcuts.getShortcut(for: .toggleRecord))) "
                            + "armed=\(KeyboardShortcuts.isEnabled(for: .toggleRecord))")
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .toggleRecord)?.carbonKeyCode, recorded.carbonKeyCode)
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .toggleRecord)?.carbonModifiers, recorded.carbonModifiers)
        XCTAssertTrue(KeyboardShortcuts.isEnabled(for: .toggleRecord),
                      "the recorded combination was not armed")
        withExtendedLifetime(manager) {}
    }

    /// The three modes stay mutually exclusive: with a modifier hotkey armed, the
    /// key combination must not be armed as well — the state the picker hands
    /// over from, and the one this fix must not blur.
    func testAModifierHotkeyLeavesTheKeyCombinationUnarmed() {
        let plantedModifier = AppPreferences.shared.modifierOnlyHotkey
        let plantedMouse = AppPreferences.shared.mouseButtonHotkey
        let plantedShortcut = UserDefaults.standard.object(forKey: Self.shortcutDefaultsKey)
        defer {
            AppPreferences.shared.modifierOnlyHotkey = plantedModifier
            AppPreferences.shared.mouseButtonHotkey = plantedMouse
            if let plantedShortcut {
                UserDefaults.standard.set(plantedShortcut, forKey: Self.shortcutDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.shortcutDefaultsKey)
            }
            ModifierKeyMonitor.shared.stop()
            MouseButtonMonitor.shared.stop()
        }

        AppPreferences.shared.mouseButtonHotkey = MouseButton.none.rawValue
        AppPreferences.shared.modifierOnlyHotkey = ModifierKey.leftOption.rawValue
        KeyboardShortcuts.reset(.toggleRecord)

        let manager = ShortcutManager()
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)

        TestFixtures.report("[trigger] modifier mode: shortcut=\(String(describing: KeyboardShortcuts.getShortcut(for: .toggleRecord))) "
                            + "armed=\(KeyboardShortcuts.isEnabled(for: .toggleRecord))")
        XCTAssertFalse(KeyboardShortcuts.isEnabled(for: .toggleRecord),
                       "the modifier hotkey mode also armed the key combination")
        withExtendedLifetime(manager) {}
    }
}

/// `ContentView` in a window shaped like the app's main window, presenting the
/// Settings sheet as soon as it appears — the same path the Settings… menu item
/// takes, without input automation.
private struct SettingsSheetHost: View {
    let tabIndex: Int

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: .constant(true)) {
                SettingsView(selectedTab: tabIndex)
                    .environmentObject(AppState())
            }
    }
}
