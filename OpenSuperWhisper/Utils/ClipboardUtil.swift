import Cocoa

class ClipboardUtil {
    private static func saveCurrentPasteboardContents() -> ([NSPasteboard.PasteboardType: Any], [NSPasteboard.PasteboardType])? {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        
        // If pasteboard is empty, return nil
        guard !types.isEmpty else { return nil }
        
        var savedContents: [NSPasteboard.PasteboardType: Any] = [:]
        
        // Save data for each type
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
    
    private static func restorePasteboardContents(_ contents: ([NSPasteboard.PasteboardType: Any], [NSPasteboard.PasteboardType])) {
        let pasteboard = NSPasteboard.general
        let (savedContents, types) = contents
        
        pasteboard.declareTypes(types, owner: nil)
        
        // Restore data for each type
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
    
    static func insertTextUsingPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        
        // Save current pasteboard contents
        let savedContents = saveCurrentPasteboardContents()
        
        // Set new text to pasteboard
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        
        // Create event source
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("Failed to create event source")
            // Restore original contents if event source creation failed
            if let contents = savedContents {
                restorePasteboardContents(contents)
            }
            return
        }
        
        // Key codes (in dec):
        // - Command (left) — 55
        // - V — 9
        let keyCodeCmd: CGKeyCode = 55
        let keyCodeV: CGKeyCode = 9
        
        // Create events: press Command, press V, release V, release Command
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCmd, keyDown: true)
        
        // Set Command flag when pressing V
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        vDown?.flags = .maskCommand
        
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        vUp?.flags = .maskCommand
        
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCmd, keyDown: false)
        
        // Define event tap location
        let eventTapLocation = CGEventTapLocation.cghidEventTap
        
        // Post events to system
        cmdDown?.post(tap: eventTapLocation)
        vDown?.post(tap: eventTapLocation)
        vUp?.post(tap: eventTapLocation)
        cmdUp?.post(tap: eventTapLocation)
        
        // Add a small delay to ensure paste operation completes
        Thread.sleep(forTimeInterval: 0.1)
        
        // Restore original contents
        if let contents = savedContents {
            restorePasteboardContents(contents)
        }
    }
} 