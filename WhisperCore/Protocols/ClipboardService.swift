import Foundation

/// Platform-agnostic protocol for clipboard operations.
/// macOS: Implemented by ClipboardUtil (NSPasteboard)
/// iOS: Implemented by iOSClipboardService (UIPasteboard) in future cycle
public protocol ClipboardService {
    func copyToClipboard(_ text: String)
    func getClipboardText() -> String?
}
