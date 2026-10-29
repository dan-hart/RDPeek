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

    /// The key ANSI keyboards have left of "1" sits between left Shift and Z on ISO keyboards.
    func testGraveKeyCodeFollowsTheKeyboardType() {
        let graveKey = UInt16(kVK_ANSI_Grave)
        XCTAssertEqual(
            MacRDPKeyboardMapping.scancode(forKeyCode: graveKey, isISOKeyboard: false),
            RDPKeyboardScancode(code: 0x29)
        )
        XCTAssertEqual(
            MacRDPKeyboardMapping.scancode(forKeyCode: graveKey, isISOKeyboard: true),
            RDPKeyboardScancode(code: 0x56)
        )
        XCTAssertEqual(
            MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ISO_Section), isISOKeyboard: true),
            RDPKeyboardScancode(code: 0x29)
        )
    }

    func testKeypadClearDoesNotSendNumLock() {
        XCTAssertNil(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_ANSI_KeypadClear)))
    }

    func testScancodeRuleCoversFunctionKeysAndModifiedKeys() {
        func sendsScancode(_ keyCode: Int, _ modifierFlags: NSEvent.ModifierFlags) -> Bool {
            MacRDPKeyboardMapping.shouldSendScancode(
                forKeyCode: UInt16(keyCode),
                modifierFlags: modifierFlags,
                isHeldAsScancode: false
            )
        }
        XCTAssertTrue(sendsScancode(kVK_F2, []))
        XCTAssertTrue(sendsScancode(kVK_F4, []))
        XCTAssertFalse(sendsScancode(kVK_ANSI_A, []))
        XCTAssertTrue(sendsScancode(kVK_ANSI_A, .option))
    }

    // MARK: - Characters typed with Option

    func testOptionTypesOnlyWhereItChangesWhatTheKeyTypes() {
        /// `deadKey` nil fails the test if the dead-key check is asked at all.
        func optionTypes(
            _ characters: String,
            ignoringModifiers: String,
            _ modifierFlags: NSEvent.ModifierFlags = .option,
            deadKey: Bool? = nil
        ) -> Bool {
            MacRDPKeyboardMapping.optionTypes(
                characters,
                charactersIgnoringModifiers: ignoringModifiers,
                modifierFlags: modifierFlags,
                isDeadKey: {
                    guard let deadKey else {
                        XCTFail("Asked whether a key that types something is a dead key")
                        return false
                    }
                    return deadKey
                }()
            )
        }
        // German Option-L and Shift-Option-7.
        XCTAssertTrue(optionTypes("@", ignoringModifiers: "l"))
        XCTAssertTrue(optionTypes("\\", ignoringModifiers: "/", [.option, .shift]))
        // US Option-E, a dead key: it types nothing, and the next key the accent.
        XCTAssertTrue(optionTypes("", ignoringModifiers: "e", deadKey: true))
        // A key a custom layout gives no output with Option, which is no dead key.
        XCTAssertFalse(optionTypes("", ignoringModifiers: "e", deadKey: false))
        // Option changed nothing, or typed a control or private-use character
        // (F4, the Apple logo).
        XCTAssertFalse(optionTypes("l", ignoringModifiers: "l"))
        XCTAssertFalse(optionTypes("\u{1B}", ignoringModifiers: "["))
        XCTAssertFalse(optionTypes("\u{F707}", ignoringModifiers: "\u{F707}"))
        XCTAssertFalse(optionTypes("\u{F8FF}", ignoringModifiers: "K", [.option, .shift]))
        // Without Option, or with ⌘ or ⌃ making the key a shortcut.
        XCTAssertFalse(optionTypes("é", ignoringModifiers: "e", []))
        XCTAssertFalse(optionTypes("@", ignoringModifiers: "l", [.option, .command]))
        XCTAssertFalse(optionTypes("@", ignoringModifiers: "l", [.option, .control]))
    }

    func testDeadKeysFollowTheMacLayoutsKeyTranslation() throws {
        // The US layout, looked up by its ID rather than the Mac's current one.
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
        let sources = try XCTUnwrap(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
        let deadKeys = try XCTUnwrap(sources.first.flatMap(MacRDPDeadKeys.init))
        let eKey = UInt16(kVK_ANSI_E)
        // Option-E starts "´"; Option-L types "¬", Shift-Option-E "´" itself and E "e".
        XCTAssertTrue(deadKeys.isDeadKey(keyCode: eKey, modifierFlags: .option))
        XCTAssertFalse(deadKeys.isDeadKey(keyCode: UInt16(kVK_ANSI_L), modifierFlags: .option))
        XCTAssertFalse(deadKeys.isDeadKey(keyCode: eKey, modifierFlags: [.option, .shift]))
        XCTAssertFalse(deadKeys.isDeadKey(keyCode: eKey, modifierFlags: []))
        // With no dead key pending, A types "a", Shift-A "A" and Option-E nothing.
        XCTAssertEqual(deadKeys.output(keyCode: UInt16(kVK_ANSI_A), modifierFlags: []), "a")
        XCTAssertEqual(deadKeys.output(keyCode: UInt16(kVK_ANSI_A), modifierFlags: .shift), "A")
        XCTAssertEqual(deadKeys.output(keyCode: eKey, modifierFlags: .option), "")
    }

    // MARK: - A dead key's accent ahead of a key it does not compose with

    func testDeadKeyPrefixIsWhatADeadKeyLeftAheadOfTheKeysOutput() {
        func prefix(_ characters: String?) -> String {
            MacRDPKeyboardMapping.deadKeyPrefix(characters)
        }
        // Return, Tab and Esc after US Option-E, keypad Enter after German "^".
        XCTAssertEqual(prefix("´\r"), "´")
        XCTAssertEqual(prefix("´\t"), "´")
        XCTAssertEqual(prefix("´\u{1B}"), "´")
        XCTAssertEqual(prefix("^\u{03}"), "^")
        // No dead key before the key, or one that composed with it.
        XCTAssertEqual(prefix("\r"), "")
        XCTAssertEqual(prefix("é"), "")
        XCTAssertEqual(prefix("^"), "")
        // Nothing printable ahead of the key's output, or no control
        // character to be the key's output.
        XCTAssertEqual(prefix("\u{1B}\r"), "")
        XCTAssertEqual(prefix("\u{F702}\r"), "")
        XCTAssertEqual(prefix("´a"), "")
        XCTAssertEqual(prefix(nil), "")
    }

    // MARK: - Characters the announced layout types

    /// A remote IME commits its candidate with Space, so it goes as its scancode on every layout,
    /// and as Unicode only when a dead key composed with it.
    func testSpaceSendsItsScancodeUnlessADeadKeyComposedWithIt() {
        XCTAssertEqual(MacRDPKeyboardMapping.scancode(forKeyCode: UInt16(kVK_Space)), RDPKeyboardScancode(code: 0x39))
        for layout: UInt32 in [0x0000_0409, 0x0000_0407, 0x0000_0419, 0x1234_5678] {
            XCTAssertTrue(windowsTypes(" ", scancode: 0x39, layout: layout))
            XCTAssertTrue(windowsTypes(" ", scancode: 0x39, .shift, layout: layout))
        }
        XCTAssertFalse(windowsTypes("^", ignoringModifiers: " ", scancode: 0x39, layout: 0x0000_0407))
    }

    func testCharactersUSWindowsTypesForTheScancodeGoAsScancodes() {
        XCTAssertTrue(windowsTypes("a", scancode: 0x1E))
        XCTAssertTrue(windowsTypes("A", scancode: 0x1E, .shift))
        XCTAssertTrue(windowsTypes(";", scancode: 0x27))
        XCTAssertTrue(windowsTypes(":", scancode: 0x27, .shift))
        XCTAssertTrue(windowsTypes("`", scancode: 0x29))
        // Caps Lock shifts letters only, as on Windows.
        XCTAssertTrue(windowsTypes("A", scancode: 0x1E, .capsLock))
        XCTAssertTrue(windowsTypes("1", scancode: 0x02, .capsLock))
        XCTAssertTrue(windowsTypes("a", scancode: 0x1E, [.capsLock, .shift]))
        // AppKit may report the letter Caps Lock did not capitalize as the key's own.
        XCTAssertTrue(windowsTypes("A", ignoringModifiers: "a", scancode: 0x1E, .capsLock))
        XCTAssertFalse(windowsTypes("É", ignoringModifiers: "e", scancode: 0x12, .capsLock))
    }

    func testCharactersWindowsTypesDifferentlyGoAsUnicode() {
        // The ISO key between left Shift and Z goes as 0x56, which US Windows types as "\".
        XCTAssertFalse(windowsTypes("`", scancode: 0x56))
        XCTAssertFalse(windowsTypes("§", scancode: 0x29))
        XCTAssertFalse(windowsTypes("a", scancode: 0x1E, .shift))
        XCTAssertFalse(windowsTypes("ab", scancode: 0x1E))
        // A character a dead key composed.
        XCTAssertFalse(windowsTypes("é", ignoringModifiers: "e", scancode: 0x12))
        XCTAssertFalse(windowsTypes("e", ignoringModifiers: "é", scancode: 0x12))
        // JIS keys type nothing with the US layout, and a layout with no table sends Unicode.
        XCTAssertFalse(windowsTypes("¥", scancode: 0x7D))
        XCTAssertFalse(windowsTypes("a", scancode: 0x1E, layout: 0x1234_5678))
    }

    func testTheScancodeCheckFollowsTheAnnouncedLayout() {
        // German: QWERTZ, and "^" is a dead key on Windows.
        XCTAssertTrue(windowsTypes("z", scancode: 0x15, layout: 0x0000_0407))
        XCTAssertFalse(windowsTypes("z", scancode: 0x15))
        XCTAssertTrue(windowsTypes("ß", scancode: 0x0C, layout: 0x0000_0407))
        XCTAssertTrue(windowsTypes("<", scancode: 0x56, layout: 0x0000_0407))
        XCTAssertFalse(windowsTypes("^", scancode: 0x29, layout: 0x0000_0407))
        // French (Belgian, what Apple's French maps to) has digits on Shift.
        XCTAssertTrue(windowsTypes("a", scancode: 0x10, layout: 0x0000_080C))
        XCTAssertTrue(windowsTypes("1", scancode: 0x02, .shift, layout: 0x0000_080C))
        XCTAssertTrue(windowsTypes("&", scancode: 0x02, layout: 0x0000_080C))
        // Russian.
        XCTAssertTrue(windowsTypes("ф", scancode: 0x1E, layout: 0x0000_0419))
    }

    func testMacInputSourcesMapToWindowsLayoutsWithCapturedTables() {
        func layout(_ name: String) -> UInt32 {
            MacRDPKeyboardLayout.windowsLayout(forInputSourceID: "com.apple.keylayout." + name).rawValue
        }
        XCTAssertEqual(layout("US"), 0x0000_0409)
        XCTAssertEqual(layout("German"), 0x0000_0407)
        XCTAssertEqual(layout("British"), 0x0000_0809)
        XCTAssertEqual(layout("French"), 0x0000_080C)
        XCTAssertEqual(layout("Dvorak"), 0x0001_0409)
        XCTAssertEqual(layout("Australian"), 0x0000_0409)
        XCTAssertEqual(layout("ABC"), 0x0000_0409)
        XCTAssertEqual(
            MacRDPKeyboardLayout.windowsLayout(forInputSourceID: "com.apple.inputmethod.Kotoeri.Japanese"),
            .unitedStates
        )
        // Every layout that can be announced has a table, so the scancode check covers it.
        for klid in Set(MacRDPKeyboardLayout.windowsLayouts.values) {
            XCTAssertNotNil(MacRDPWindowsKeyboardLayout.layout(RDPKeyboardLayout(rawValue: klid)), "KLID \(klid)")
        }
        let keyCount = MacRDPWindowsKeyboardLayout.scancodes.count
        for table in MacRDPWindowsKeyboardLayout.layouts.values {
            XCTAssertEqual(table.unshifted.unicodeScalars.count, keyCount)
            XCTAssertEqual(table.shifted.unicodeScalars.count, keyCount)
            XCTAssertEqual(table.capsLock.unicodeScalars.count, keyCount)
        }
    }

    private func windowsTypes(
        _ characters: String,
        ignoringModifiers: String? = nil,
        scancode: UInt16,
        _ modifierFlags: NSEvent.ModifierFlags = [],
        layout: UInt32 = 0x0000_0409
    ) -> Bool {
        MacRDPKeyboardMapping.windowsTypes(
            characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            for: RDPKeyboardScancode(code: scancode),
            modifierFlags: modifierFlags,
            layout: RDPKeyboardLayout(rawValue: layout)
        )
    }

    // MARK: - Toggle keys

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
