import AppKit
import Carbon.HIToolbox
import RDPKit
import XCTest

final class RemoteInputMappingTests: XCTestCase {
    // MARK: - Modifier keys

    func testModifierKeysTrackEachSideFromDeviceFlags() throws {
        let leftShift = try XCTUnwrap(MacRDPModifierKey(keyCode: UInt16(kVK_Shift)))
        let rightShift = try XCTUnwrap(MacRDPModifierKey(keyCode: UInt16(kVK_RightShift)))
        let bothDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2 | 0x4)
        let onlyRightDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x4)

        XCTAssertTrue(leftShift.isDown(in: bothDown))
        XCTAssertTrue(rightShift.isDown(in: bothDown))
        XCTAssertFalse(leftShift.isDown(in: onlyRightDown))
        XCTAssertTrue(rightShift.isDown(in: onlyRightDown))
        XCTAssertFalse(leftShift.isDown(in: []))
    }

    func testModifierKeysFallBackToSideIndependentFlags() throws {
        let control = try XCTUnwrap(MacRDPModifierKey(keyCode: UInt16(kVK_Control)))

        XCTAssertTrue(control.isDown(in: .control))
        XCTAssertFalse(control.isDown(in: []))
        // Without a side bit, the flag alone never names this side as held.
        XCTAssertFalse(control.isSideDown(in: .control))
        XCTAssertTrue(control.isSideDown(in: NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.control.rawValue | 0x1
        )))
    }

    func testRightSideAndCommandModifiersUseExtendedScancodes() throws {
        let expected: [Int: RDPKeyboardScancode] = [
            kVK_RightControl: RDPKeyboardScancode(code: 0x1D, isExtended: true),
            kVK_RightOption: RDPKeyboardScancode(code: 0x38, isExtended: true),
            kVK_Command: RDPKeyboardScancode(code: 0x5B, isExtended: true),
            kVK_RightCommand: RDPKeyboardScancode(code: 0x5C, isExtended: true),
            kVK_RightShift: RDPKeyboardScancode(code: 0x36),
        ]
        for (keyCode, scancode) in expected {
            XCTAssertEqual(try XCTUnwrap(MacRDPModifierKey(keyCode: UInt16(keyCode))).scancode, scancode)
        }
    }
}
