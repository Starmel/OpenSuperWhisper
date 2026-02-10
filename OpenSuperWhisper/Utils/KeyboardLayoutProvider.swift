import Carbon
import AppKit

struct KeyboardLayoutInfo {
    let labels: [UInt16: String]
    let physicalType: PhysicalKeyboardType
    
    enum PhysicalKeyboardType {
        case ansi
        case iso
        case jis
    }
}

final class KeyboardLayoutProvider {
    
    static let shared = KeyboardLayoutProvider()
    private init() {}
    
    static let ansiKeycodes: [UInt16] = [
        50,                                         // row0: ` ~
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29,   // row0: 1-0
        27, 24,                                     // row0: - =
        12, 13, 14, 15, 17, 16, 32, 34, 31, 35,   // row1: Q-P
        33, 30,                                     // row1: [ ]
        42,                                         // row1: backslash
        0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39,     // row2: A-'
        6, 7, 8, 9, 11, 45, 46, 43, 47, 44,       // row3: Z-/
    ]
    
    func detectPhysicalType() -> KeyboardLayoutInfo.PhysicalKeyboardType {
        let kbType = Int16(LMGetKbdType())
        let layoutType = KBGetLayoutType(kbType)
        if layoutType == UInt32(kKeyboardISO) {
            return .iso
        } else if layoutType == UInt32(kKeyboardJIS) {
            return .jis
        } else {
            return .ansi
        }
    }
    
    func resolveLabels() -> [UInt16: String]? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        
        let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )
        
        let kbType = UInt32(LMGetKbdType())
        var result: [UInt16: String] = [:]
        
        for keycode in Self.ansiKeycodes {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            
            let status = UCKeyTranslate(
                keyboardLayout,
                keycode,
                UInt16(kUCKeyActionDisplay),
                0,
                kbType,
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
            
            if status == noErr && length > 0 {
                let char = String(utf16CodeUnits: Array(chars.prefix(length)), count: length)
                result[keycode] = char.uppercased()
            }
        }
        
        return result
    }
    
    func resolveInfo() -> KeyboardLayoutInfo? {
        let physicalType = detectPhysicalType()
        guard physicalType == .ansi else { return nil }
        guard let labels = resolveLabels() else { return nil }
        guard labels.count == Self.ansiKeycodes.count else { return nil }
        return KeyboardLayoutInfo(labels: labels, physicalType: physicalType)
    }
    
    func labelForKeycode(_ keycode: UInt16, in info: KeyboardLayoutInfo) -> String {
        info.labels[keycode] ?? ""
    }
    
    static func inputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }
}
