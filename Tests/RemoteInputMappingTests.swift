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

    func testCommandSendsWindowsKeyOnlyWithAnotherKeyOrAsATap() {
        let leftWindows = RDPKeyboardScancode(code: 0x5B, isExtended: true)
        var inputState = RDPInputStateTracker()
        var windowsKey = MacRDPDeferredWindowsKey()

        // Command released alone: a Win tap.
        windowsKey.press(leftWindows)
        XCTAssertEqual(windowsKey.release(leftWindows), [
            .keyboard(scancode: leftWindows, isReleased: false),
            .keyboard(scancode: leftWindows, isReleased: true),
        ])

        // Another key while Command is held: Win down goes first and is then tracked as pressed.
        windowsKey.press(leftWindows)
        XCTAssertEqual(windowsKey.flush(&inputState), [.keyboard(scancode: leftWindows, isReleased: false)])
        XCTAssertTrue(inputState.isScancodePressed(leftWindows))
        XCTAssertEqual(windowsKey.release(leftWindows), [])

        // A shortcut handled locally, a missed release, or focus loss: nothing at all.
        windowsKey.press(leftWindows)
        windowsKey.noteChordedElsewhere()
        XCTAssertEqual(windowsKey.release(leftWindows), [])
        windowsKey.press(leftWindows)
        windowsKey.discard(leftWindows)
        XCTAssertFalse(windowsKey.isHeld(leftWindows))
        windowsKey.press(leftWindows)
        windowsKey.reset()
        XCTAssertFalse(windowsKey.isHeld(leftWindows))
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

    // MARK: - Key mapping

    func testNavigationAndKeypadKeysMapToExtendedScancodes() {
        let expected: [Int: RDPKeyboardScancode] = [
            kVK_UpArrow: RDPKeyboardScancode(code: 0x48, isExtended: true),
            kVK_Help: RDPKeyboardScancode(code: 0x52, isExtended: true),
            kVK_ForwardDelete: RDPKeyboardScancode(code: 0x53, isExtended: true),
            kVK_PageDown: RDPKeyboardScancode(code: 0x51, isExtended: true),
            kVK_ANSI_KeypadEnter: RDPKeyboardScancode(code: 0x1C, isExtended: true),
            kVK_ANSI_KeypadDivide: RDPKeyboardScancode(code: 0x35, isExtended: true),
            kVK_ContextualMenu: RDPKeyboardScancode(code: 0x5D, isExtended: true),
            kVK_ISO_Section: RDPKeyboardScancode(code: 0x29),
            kVK_F13: RDPKeyboardScancode(code: 0x64),
        ]
        for (keyCode, scancode) in expected {
            XCTAssertEqual(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(keyCode)), scancode, "key code \(keyCode)")
        }
    }

    func testFunctionKeysAlwaysSendScancodesWhileCharactersUseUnicode() {
        XCTAssertTrue(MacRDPKeyboardMapping.shouldSendScancode(forKeyCode: UInt16(kVK_F2), modifierFlags: []))
        XCTAssertTrue(MacRDPKeyboardMapping.shouldSendScancode(forKeyCode: UInt16(kVK_F4), modifierFlags: []))
        XCTAssertFalse(MacRDPKeyboardMapping.shouldSendScancode(forKeyCode: UInt16(kVK_ANSI_A), modifierFlags: []))
        XCTAssertTrue(MacRDPKeyboardMapping.shouldSendScancode(forKeyCode: UInt16(kVK_ANSI_A), modifierFlags: .option))
    }

    func testFocusSynchronizationKeepsNumLockOnAndMirrorsCapsLock() {
        XCTAssertEqual(MacRDPKeyboardMapping.toggleFlags(for: []), [.numLock])
        XCTAssertEqual(MacRDPKeyboardMapping.toggleFlags(for: [.capsLock, .shift]), [.numLock, .capsLock])
    }

    // MARK: - Scroll wheel

    func testScrollDeltasConvertToRDPRotationUnits() {
        let lines = MacRDPScrollWheel.rotationUnits(deltaX: 1, deltaY: 1, hasPreciseScrollingDeltas: false)
        let points = MacRDPScrollWheel.rotationUnits(deltaX: -0.5, deltaY: 2, hasPreciseScrollingDeltas: true)

        // AppKit's positive deltaX scrolls left; RDP's positive horizontal rotation scrolls right.
        XCTAssertEqual(lines.vertical, 120)
        XCTAssertEqual(lines.horizontal, -120)
        XCTAssertEqual(points.vertical, 20)
        XCTAssertEqual(points.horizontal, 5)
    }

    func testSmallTrackpadDeltasAddUpInsteadOfRoundingAway() {
        // Each 0.05-point delta is half a rotation unit, which rounding each
        // event on its own sent as a whole unit every time.
        var accumulator = RDPScrollWheelAccumulator()
        let point = RDPRemotePoint(x: 0, y: 0)
        var events: [RDPSlowPathInputEvent] = []
        for _ in 0 ..< 3 {
            let units = MacRDPScrollWheel.rotationUnits(deltaX: 0, deltaY: 0.05, hasPreciseScrollingDeltas: true)
            events += accumulator.events(vertical: units.vertical, horizontal: units.horizontal, at: point)
        }
        XCTAssertEqual(events, [.verticalWheel(rotation: 1, x: 0, y: 0)])
    }

    func testUnicodeEventsSkipAppKitFunctionKeyCharacters() {
        let functionKey = String(utf16CodeUnits: [0xF705], count: 1)

        XCTAssertEqual(MacRDPKeyboardMapping.unicodeEvents(for: functionKey), [])
        XCTAssertEqual(MacRDPKeyboardMapping.unicodeEvents(for: "a"), [
            .unicode(codeUnit: 0x61, isReleased: false),
            .unicode(codeUnit: 0x61, isReleased: true),
        ])
    }
}
