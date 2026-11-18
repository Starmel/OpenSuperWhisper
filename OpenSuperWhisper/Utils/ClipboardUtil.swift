import Cocoa
import ApplicationServices
import Carbon

class ClipboardUtil {

    typealias PasteboardContents = ([NSPasteboard.PasteboardType: Any], [NSPasteboard.PasteboardType])

    /// Slow consumers (browsers, Electron apps) can service the synthesized
    /// Cmd+V long after the event is posted. Restoring the original clipboard
    /// earlier makes them paste the old contents instead of the transcription.
    static let clipboardRestoreDelay: TimeInterval = 1.5

    /// Copies text to clipboard without pasting or restoring
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    /// Pastes text and keeps it in clipboard (does not restore original clipboard)
    static func insertTextAndKeepInClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        simulatePaste()
    }

    /// Pastes text and restores original clipboard (legacy behavior)
    static func insertText(_ text: String) {
        insertText(text, postEvent: { $0.post(tap: .cghidEventTap) }, pasteboard: .general)
    }

    /// Pastes `text` on `pasteboard` and restores what was there before.
    ///
    /// `pasteboard` is the general one in the app and a pasteboard of its own in
    /// the tests, so a case can prove the restore without racing every other
    /// process on the machine for the system clipboard.
    ///
    /// The restore is an in-process block, so the delivery can die before it
    /// runs and leave the transcription on the clipboard with the user's contents
    /// gone. `ClipboardRecovery` closes that: the displaced contents are written
    /// to disk **before** the pasteboard is touched, and the next launch puts them
    /// back if the record is still there. The record is cleared as soon as the
    /// delivery restores the clipboard itself, which is the ordinary case.
    static func insertText(_ text: String,
                           postEvent: (CGEvent) -> Void,
                           pasteboard: NSPasteboard = .general) {
        // A test host must never write the machine's own clipboard. Every case
        // that exercises this path passes a pasteboard of its own; the general
        // board is left alone whenever this process is a test host, which is the
        // same rule the event sink applies. The check is written with the test
        // bundle's own marker rather than the app's flag because this file is
        // compiled on its own into the crash-test child, which must not drag the
        // rest of the app in.
        guard !(NSClassFromString("XCTestCase") != nil && pasteboard.name == .general) else { return }

        // Save current pasteboard contents — to disk first, because everything
        // below this line can die with the process.
        let savedContents = saveCurrentPasteboardContents(from: pasteboard)
        let record = ClipboardRecovery.record(for: pasteboard, writtenText: text)
        if let record {
            ClipboardRecovery.write(record)
        } else {
            // Nothing to restore, so a crash would have nothing to bring back;
            // make sure no stale record from an earlier delivery is left behind.
            ClipboardRecovery.clear()
        }

        // Set new text to pasteboard
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        let changeCountAfterCopy = pasteboard.changeCount

        // Simulate Cmd+V using layout-aware keycode resolution
        sendCmdV(postEvent: postEvent)

        // Put the clipboard back only after the target app had a chance to
        // process the paste, and only if the pasteboard still holds our text:
        // a different changeCount means the user (or another app) took over
        // the clipboard and putting anything back would clobber their data.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            if let contents = savedContents {
                restoreIfUnchanged(contents, expectedChangeCount: changeCountAfterCopy, pasteboard: pasteboard)
            } else {
                // There was nothing on the clipboard to save, so there is nothing
                // to put back — but the transcription is not the user's to keep
                // either. Without this, a paste onto an empty clipboard left the
                // dictation there with nothing scheduled to take it off, which is
                // the wrong outcome for the app's own text: it should end up where
                // the clipboard started.
                clearIfUnchanged(pasteboard, expectedChangeCount: changeCountAfterCopy)
            }
            // The delivery has done its own restore (or decided not to), so the
            // crash-recovery record has nothing left to do and must not survive to
            // put stale contents back on a later launch.
            ClipboardRecovery.clear()
        }
    }

    /// Empties `pasteboard` when it still holds what this app put there.
    ///
    /// - Returns: Whether it cleared, which is also whether the pasteboard was
    ///   untouched by anyone else since the copy.
    @discardableResult
    static func clearIfUnchanged(_ pasteboard: NSPasteboard = .general,
                                 expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        return true
    }

    @discardableResult
    static func restoreIfUnchanged(_ contents: PasteboardContents,
                                   expectedChangeCount: Int,
                                   pasteboard: NSPasteboard = .general) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        restorePasteboardContents(contents, to: pasteboard)
        return true
    }
    
    private static func simulatePaste() {
        sendCmdV(postEvent: { $0.post(tap: .cghidEventTap) })
    }
    
    private static func sendCmdV(postEvent: (CGEvent) -> Void) {
        // QWERTY keycode for V
        let qwertyKeyCodeV: CGKeyCode = 9
        
        // Determine the correct keycode for Cmd+V
        let keyCodeV: CGKeyCode
        
        if isQwertyCommandLayout() {
            // For layouts like "Dvorak - QWERTY ⌘" that use QWERTY for Command shortcuts
            keyCodeV = qwertyKeyCodeV
        } else if let foundKeycode = findKeycodeForCharacter("v") {
            // For layouts where shortcuts follow the layout (Dvorak Left/Right Hand)
            keyCodeV = foundKeycode
        } else {
            // Fallback for non-Latin layouts (Russian, etc.) - use QWERTY keycode
            keyCodeV = qwertyKeyCodeV
        }
        
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else { return }
        
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        
        postEvent(keyDown)
        postEvent(keyUp)
    }
    
    static func isQwertyCommandLayout() -> Bool {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return false }
        
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        
        // "Dvorak - QWERTY ⌘" uses QWERTY positions for Command shortcuts
        // Its ID contains "DVORAK-QWERTY" or similar patterns
        // Also standard QWERTY, ABC, US layouts use keycode 9 for V
        let qwertyCommandLayouts = [
            "DVORAK-QWERTY",  // Dvorak - QWERTY ⌘
            "US",             // US QWERTY
            "ABC",            // ABC
            "Australian",     // Australian
            "British",        // British
            "Canadian",       // Canadian
            "USInternational" // US International
        ]
        
        let upperID = sourceID.uppercased()
        return qwertyCommandLayouts.contains { upperID.contains($0.uppercased()) }
    }
    
    /// A key and the modifiers the active layout needs to produce a character.
    struct ResolvedKey: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    /// The key the active layout produces `character` with, and the modifiers that
    /// layer needs.
    ///
    /// The layers are tried in the order a keyboard would prefer them: none,
    /// shift, option, then option+shift. `findKeycodeForCharacter` above walks the
    /// base layer only, which is what a caller after a bare key needs; this is
    /// what a *delivery* needs, because a target that rebuilds characters from key
    /// codes instead of reading the event's Unicode field (a Citrix session, a
    /// virtual machine, a remote desktop) gets a character only if the event
    /// carries the key the layout uses for it **and** the modifiers held for that
    /// layer. Measured on this machine's layout: `ą` is Option+A, `ó` Option+O,
    /// `ź` Option+X, `Ś` Option+Shift+S — and every one of those diacritics used
    /// to be sent as key code `0x7F` with no modifiers, which no target can turn
    /// into a character.
    ///
    /// **What this cannot do.** Nothing here consults the *target's* keyboard
    /// layout, and the sender cannot see it. Correct key code plus correct
    /// modifiers is exactly what a physical keyboard sends and what a
    /// HID-forwarding client forwards; if the target's layout is not the sender's,
    /// the character it produces is not the one that was dictated. That gap is the
    /// client's to close or the user's to work around, and it is stated in the
    /// Readme with the other unclosed paths.
    static func findKey(for character: Character) -> ResolvedKey? {
        let layers: [CGEventFlags] = [[], .maskShift, .maskAlternate, [.maskAlternate, .maskShift]]
        for flags in layers {
            if let keyCode = keyCode(producing: character, layer: flags) {
                return ResolvedKey(keyCode: keyCode, flags: flags)
            }
        }
        return nil
    }

    /// The key code that produces exactly `character` on the current layout with
    /// `layer` held, or `nil` when no key does.
    ///
    /// Carbon wants the modifier state as the Event Manager constant shifted right
    /// by eight — the classic `UCKeyTranslate` convention — and the *down* action,
    /// which is the one that applies modifiers (the display action this file's
    /// other lookup uses reports the base layer's character whatever is held).
    private static func keyCode(producing character: Character, layer: CGEventFlags) -> CGKeyCode? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )

        var modifierState: UInt32 = 0
        if layer.contains(.maskShift) { modifierState |= UInt32(shiftKey >> 8) }
        if layer.contains(.maskAlternate) { modifierState |= UInt32(optionKey >> 8) }

        let wanted = String(character)
        // 0…127 rather than the 0…50 the base-layer walk uses: the layers above
        // the base are not confined to the letter rows (Option+Shift+8, the
        // character keys, the punctuation keys).
        for keycode: UInt16 in 0...127 {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0
            let status = UCKeyTranslate(
                keyboardLayout,
                keycode,
                UInt16(kUCKeyActionDown),
                modifierState,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            if status == noErr, length > 0,
               String(utf16CodeUnits: chars, count: length) == wanted {
                return CGKeyCode(keycode)
            }
        }
        return nil
    }

    static func findKeycodeForCharacter(_ char: Character) -> CGKeyCode? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        
        let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )
        
        let targetLower = char.lowercased()
        
        // Iterate through common keycodes (0-50 covers all letter keys)
        for keycode: UInt16 in 0...50 {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            
            let status = UCKeyTranslate(
                keyboardLayout,
                keycode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
            
            if status == noErr && length > 0 {
                let resultChar = Character(UnicodeScalar(chars[0])!)
                if resultChar.lowercased() == targetLower {
                    return CGKeyCode(keycode)
                }
            }
        }
        return nil
    }
    
    static func saveCurrentPasteboardContents(from pasteboard: NSPasteboard = .general) -> PasteboardContents? {
        let types = pasteboard.types ?? []
        
        guard !types.isEmpty else { return nil }
        
        var savedContents: [NSPasteboard.PasteboardType: Any] = [:]
        
        for type in types {
            if let data = pasteboard.data(forType: type) {
                savedContents[type] = data
            } else if let string = pasteboard.string(forType: type) {
                savedContents[type] = string
            } else if let urls = pasteboard.propertyList(forType: type) as? [String] {
                savedContents[type] = urls
            }
        }
        
        return (!savedContents.isEmpty) ? (savedContents, types) : nil
    }
    
    static func restorePasteboardContents(_ contents: PasteboardContents, to pasteboard: NSPasteboard = .general) {
        let (savedContents, types) = contents
        
        pasteboard.declareTypes(types, owner: nil)
        
        for (type, content) in savedContents {
            if let data = content as? Data {
                pasteboard.setData(data, forType: type)
            } else if let string = content as? String {
                pasteboard.setString(string, forType: type)
            } else if let urls = content as? [String] {
                pasteboard.setPropertyList(urls, forType: type)
            }
        }
    }
    
    @available(*, deprecated, renamed: "insertText")
    static func insertTextUsingPasteboard(_ text: String) {
        insertText(text)
    }
    
    // MARK: - Testing Helpers
    
    static func getCurrentInputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }
    
    static func switchToInputSource(withID targetID: String) -> Bool {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            
            if sourceID.contains(targetID) || targetID.contains(sourceID) || sourceID == targetID {
                let result = TISSelectInputSource(source)
                usleep(100000) // 100ms delay for layout switch
                return result == noErr
            }
        }
        return false
    }
    
    static func getAvailableInputSources() -> [String] {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        
        var result: [String] = []
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let selectablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            else { continue }
            
            let isSelectable = unsafeBitCast(selectablePtr, to: CFBoolean.self) == kCFBooleanTrue
            if isSelectable {
                let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                result.append(sourceID)
            }
        }
        return result
    }
}
