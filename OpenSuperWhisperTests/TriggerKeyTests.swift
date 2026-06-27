import XCTest
@testable import OpenSuperWhisper

final class TriggerKeyTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let key = TriggerKey(keyCode: 63, kind: .modifier, displayName: "Fn", symbol: "fn")
        let data = try JSONEncoder().encode([key])
        let decoded = try JSONDecoder().decode([TriggerKey].self, from: data)
        XCTAssertEqual(decoded, [key])
    }

    func testIdentityIsKindPlusKeyCode() {
        let a = TriggerKey(keyCode: 61, kind: .modifier, displayName: "Right ⌥", symbol: "⌥")
        let b = TriggerKey(keyCode: 61, kind: .regular, displayName: "x", symbol: "x")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.id, "modifier-61")
    }

    func testFromModifierKeyBridge() {
        let tk = TriggerKey(modifierKey: .rightOption)
        XCTAssertEqual(tk.keyCode, 61)
        XCTAssertEqual(tk.kind, .modifier)
    }

    // Twin-modifier fix: device-specific bits distinguish left vs right of a pair,
    // so a release of one ⌘ is detected even while the other ⌘ is held.
    func testIsModifierPressedDistinguishesLeftAndRight() {
        let leftCmdOnly: UInt64 = 0x0000_0008 // NX_DEVICELCMDKEYMASK
        XCTAssertEqual(TriggerKey.isModifierPressed(keyCode: 55, flagsRawValue: leftCmdOnly), true)
        XCTAssertEqual(TriggerKey.isModifierPressed(keyCode: 54, flagsRawValue: leftCmdOnly), false)

        let bothCmd: UInt64 = 0x0000_0018 // left | right
        XCTAssertEqual(TriggerKey.isModifierPressed(keyCode: 54, flagsRawValue: bothCmd), true)

        // Releasing right ⌘ while left ⌘ stays held: right reads not-pressed.
        XCTAssertEqual(TriggerKey.isModifierPressed(keyCode: 54, flagsRawValue: leftCmdOnly), false)
    }

    func testIsModifierPressedNilForNonModifier() {
        XCTAssertNil(TriggerKey.isModifierPressed(keyCode: 0, flagsRawValue: 0))
    }

    func testRegularKeyLabelKnownAndUnknown() {
        XCTAssertEqual(TriggerKey.regularKeyLabel(forKeyCode: 49).name, "Space")
        XCTAssertEqual(TriggerKey.regularKeyLabel(forKeyCode: 105).name, "F13")
        XCTAssertEqual(TriggerKey.regularKeyLabel(forKeyCode: 200).name, "Key 200")
    }
}
