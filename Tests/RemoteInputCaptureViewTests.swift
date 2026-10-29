import AppKit
import Carbon.HIToolbox
import RDPKit
import XCTest

@MainActor
final class RemoteInputCaptureViewTests: XCTestCase {
    private struct Harness {
        let window: NSWindow
        let view: RemoteInputCaptureNSView
        let recorder: InputEventRecorder
    }

    // MARK: - Modifier state derived from event flags

    func testModifierPressAndReleaseFollowDeviceFlags() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftControl, isReleased: false)])

        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: []))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftControl, isReleased: true)])
    }

    func testModifierWithoutSideBitsFollowsSideIndependentFlag() {
        // Some keyboards report only .shift, with no left/right device bit;
        // the key code still names the side that changed.
        let harness = makeHarness()
        let leftShift = RDPKeyboardScancode(code: 0x2A)
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Shift), flags: .shift))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: leftShift, isReleased: false)])

        // Shift stays down for the key typed with it.
        harness.recorder.events.removeAll()
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_ANSI_A), characters: "A", flags: .shift))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: RDPKeyboardScancode(code: 0x1E), isReleased: false)])

        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Shift), flags: []))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: leftShift, isReleased: true)])
    }

    func testRepeatedFlagsStateSendsNoDuplicateEvents() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
        harness.recorder.events.removeAll()

        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testBothSidesWithoutSideBitsAreReleasedWithTheSharedFlag() {
        // Without side bits, releasing one Shift leaves .shift set, so the
        // other side's release only shows when the flag clears.
        let harness = makeHarness()
        let leftShift = RDPKeyboardScancode(code: 0x2A)
        let rightShift = RDPKeyboardScancode(code: 0x36)
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Shift), flags: .shift))
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_RightShift), flags: .shift))
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_RightShift), flags: .shift))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: leftShift, isReleased: false),
            .keyboard(scancode: rightShift, isReleased: false),
        ])

        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Shift), flags: []))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: leftShift, isReleased: true),
            .keyboard(scancode: rightShift, isReleased: true),
        ])
    }

    func testMissedModifierReleaseDoesNotInvertPhase() {
        // Hold Control, then leave the window: the release happens while
        // another app is active, so the view only sees the window resign key.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
        harness.recorder.events.removeAll()
        resignKey(harness)
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftControl, isReleased: true)])

        // The next physical Control press must be sent as a press, not as
        // the inverted release the old toggle-based logic produced.
        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftControl, isReleased: false)])
    }

    func testKeyDownResyncsStaleModifier() {
        // Control-down is tracked, then released without the view ever
        // seeing a flagsChanged. The next keystroke carries the truth in its
        // modifier flags and must repair the remote state first.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
        harness.recorder.events.removeAll()

        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 0, characters: "a"))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: .leftControl, isReleased: true),
            .keyboard(scancode: RDPKeyboardScancode(code: 0x1E), isReleased: false),
        ])
    }

    func testMouseDownResyncsStaleModifier() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
        harness.recorder.events.removeAll()

        harness.view.mouseDown(with: mouseEvent(.leftMouseDown, location: NSPoint(x: 100, y: 50)))
        XCTAssertEqual(harness.recorder.events.first, .keyboard(scancode: .leftControl, isReleased: true))
        XCTAssertTrue(isPointerButton(harness.recorder.events.last, button: .left, isDown: true))
    }

    func testMovesAndScrollsReleaseModifiersTheViewMissed() {
        // A modifier released while a menu is open never reaches the view as
        // flagsChanged; a later move, drag or scroll shows it up.
        let harness = makeHarness()
        let pressControl = {
            harness.view.flagsChanged(with: self.flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
            harness.recorder.events.removeAll()
        }

        pressControl()
        harness.view.mouseMoved(with: mouseEvent(.mouseMoved, location: NSPoint(x: 10, y: 90)))
        XCTAssertEqual(harness.recorder.events.count, 2)
        XCTAssertEqual(harness.recorder.events.first, .keyboard(scancode: .leftControl, isReleased: true))
        XCTAssertTrue(isPointerMove(harness.recorder.events.last))

        pressControl()
        harness.view.mouseDragged(with: mouseEvent(.leftMouseDragged, location: NSPoint(x: 10, y: 90)))
        XCTAssertEqual(harness.recorder.events.first, .keyboard(scancode: .leftControl, isReleased: true))
        XCTAssertTrue(isPointerMove(harness.recorder.events.last))

        pressControl()
        harness.view.scrollWheel(with: scrollEvent())
        XCTAssertEqual(harness.recorder.events.first, .keyboard(scancode: .leftControl, isReleased: true))
    }

    func testKeyAndButtonReleasesReleaseModifiersTheViewMissedFirst() {
        let harness = makeHarness()
        let xKey = RDPKeyboardScancode(code: 0x2D)
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_ANSI_X), characters: "\u{18}", flags: .leftControlDown))
        harness.view.mouseDown(with: mouseEvent(.leftMouseDown, location: NSPoint(x: 10, y: 90), flags: .leftControlDown))
        harness.recorder.events.removeAll()

        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: UInt16(kVK_ANSI_X), characters: "x"))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: .leftControl, isReleased: true),
            .keyboard(scancode: xKey, isReleased: true),
        ])

        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftControl, flags: .leftControlDown))
        harness.recorder.events.removeAll()
        harness.view.mouseUp(with: mouseEvent(.leftMouseUp, location: NSPoint(x: 10, y: 90)))
        XCTAssertEqual(harness.recorder.events.count, 2)
        XCTAssertEqual(harness.recorder.events.first, .keyboard(scancode: .leftControl, isReleased: true))
        XCTAssertTrue(isPointerButton(harness.recorder.events.last, button: .left, isDown: false))
    }

    // MARK: - Pointer

    func testADragPastTheDesktopStopsOnItsEdge() {
        // A 100x100 desktop letterboxed in the 200x100 view spans x 50-150.
        // A drag that leaves it holds the pointer on its edge; a plain move
        // there sends nothing.
        let harness = makeHarness()
        harness.view.rdpFrame = makeFrameMetadata(width: 100, height: 100)

        harness.view.mouseMoved(with: mouseEvent(.mouseMoved, location: NSPoint(x: 180, y: 50)))
        XCTAssertEqual(harness.recorder.events, [])
        harness.view.mouseDragged(with: mouseEvent(.leftMouseDragged, location: NSPoint(x: 180, y: 50)))
        harness.view.mouseDragged(with: mouseEvent(.leftMouseDragged, location: NSPoint(x: 10, y: -20)))
        XCTAssertEqual(harness.recorder.events, [.pointerMove(x: 99, y: 50), .pointerMove(x: 0, y: 99)])
    }

    // MARK: - Command as the Windows key

    func testCommandReleasedAloneTapsTheWindowsKey() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        XCTAssertEqual(harness.recorder.events, [])

        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: .leftWindows, isReleased: false),
            .keyboard(scancode: .leftWindows, isReleased: true),
        ])
    }

    func testCommandTabAwaySendsNoWindowsKey() {
        // Cmd-Tab: the view sees Command go down, then the window resign
        // key. A Win tap would open the remote Start menu.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        resignKey(harness)
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testCommandClickSendsTheWindowsKeyBeforeTheButton() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.view.mouseDown(with: mouseEvent(.leftMouseDown, location: NSPoint(x: 100, y: 50), flags: .leftCommandDown))
        XCTAssertEqual(harness.recorder.events.count, 2)
        XCTAssertEqual(harness.recorder.events.first, .keyboard(scancode: .leftWindows, isReleased: false))
        XCTAssertTrue(isPointerButton(harness.recorder.events.last, button: .left, isDown: true))

        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftWindows, isReleased: true)])
    }

    func testCommandChordTheRemoteNeverSeesSendsNoTap() {
        // A Command chord on a key with no scancode is left to the menus.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        let handled = harness.view.performKeyEquivalent(
            with: keyEvent(.keyDown, keyCode: UInt16(kVK_VolumeUp), flags: .leftCommandDown)
        )
        XCTAssertFalse(handled)

        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testCommandFoundAlreadyHeldIsNoTap() {
        // Cmd-Shift-Tab into this window, then Shift and Command released:
        // Command was never seen going down here, so it sends nothing.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Shift), flags: .leftCommandDown))
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testMissedCommandReleaseDropsTheDeferredWindowsKey() {
        // Command released while another app (Spotlight) had the keyboard:
        // Win never reached the server, so the next key must not take it
        // down there.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))

        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_LeftArrow)))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: RDPKeyboardScancode(code: 0x4B, isExtended: true), isReleased: false),
        ])
    }

    // MARK: - Window resigning key

    func testResignKeyReleasesPressedKeysAndButtons() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.view.mouseDown(with: mouseEvent(
            .leftMouseDown,
            location: NSPoint(x: 100, y: 50),
            flags: .leftCommandDown
        ))
        harness.recorder.events.removeAll()

        resignKey(harness)
        XCTAssertTrue(harness.recorder.events.contains { isPointerButton($0, button: .left, isDown: false) })
        XCTAssertTrue(harness.recorder.events.contains(.keyboard(scancode: .leftWindows, isReleased: true)))
    }

    func testKeysHeldWhenTheViewLosesFocusAreReleased() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Shift), flags: .shift))
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_DownArrow), flags: .shift))
        harness.recorder.events.removeAll()

        _ = harness.view.resignFirstResponder()

        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: RDPKeyboardScancode(code: 0x2A), isReleased: true),
            .keyboard(scancode: RDPKeyboardScancode(code: 0x50, isExtended: true), isReleased: true),
        ])
    }

    // MARK: - Toggle-key synchronization

    func testBecomingFirstResponderSynchronizesToggleKeys() {
        let harness = makeHarness(isFirstResponder: false)
        harness.window.makeFirstResponder(harness.view)
        XCTAssertEqual(harness.recorder.events, [.synchronize(toggleFlags: currentToggleFlags)])
    }

    func testWindowBecomingKeySynchronizesToggleKeysForTheFocusedView() {
        let harness = makeHarness()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: harness.window)
        XCTAssertEqual(harness.recorder.events, [.synchronize(toggleFlags: currentToggleFlags)])

        let unfocused = makeHarness(isFirstResponder: false)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: unfocused.window)
        XCTAssertEqual(unfocused.recorder.events, [])
    }

    func testNewInputSessionWhileFocusedIsSynchronized() {
        let harness = makeHarness()
        let nextSession = InputEventRecorder()
        harness.view.inputSession = nextSession
        XCTAssertEqual(nextSession.events, [.synchronize(toggleFlags: currentToggleFlags)])
    }

    func testCapsLockSynchronizesAndKeepsNumLockOnAndHeldKeysDown() {
        // The synchronize resets the server's keys, so the held Shift is
        // pressed again after it.
        let harness = makeHarness()
        let leftShift = RDPKeyboardScancode(code: 0x2A)
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Shift), flags: .leftShiftDown))
        harness.recorder.events.removeAll()

        harness.view.flagsChanged(with: flagsEvent(
            keyCode: UInt16(kVK_CapsLock),
            flags: NSEvent.ModifierFlags.leftShiftDown.union(.capsLock)
        ))
        XCTAssertEqual(harness.recorder.events, [
            .synchronize(toggleFlags: [.numLock, .capsLock]),
            .keyboard(scancode: leftShift, isReleased: false),
        ])

        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_CapsLock), flags: .leftShiftDown))
        XCTAssertEqual(harness.recorder.events, [
            .synchronize(toggleFlags: [.numLock]),
            .keyboard(scancode: leftShift, isReleased: false),
        ])
    }

    // MARK: - keyUp AppKit withholds while Command is held

    func testCommandChordKeyIsReleasedAsItGoesUp() {
        // AppKit never dispatches W's keyUp while Command is held; the
        // view's key-up monitor sends it at once, so a second ⌘W is a new
        // press rather than a repeat of a W the server still holds.
        let harness = makeHarness()
        let wKey = RDPKeyboardScancode(code: 0x11)
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        for _ in 0 ..< 2 {
            XCTAssertTrue(harness.view.performKeyEquivalent(
                with: keyEvent(.keyDown, keyCode: UInt16(kVK_ANSI_W), characters: "w", flags: .leftCommandDown)
            ))
            NSApplication.shared.sendEvent(keyEvent(
                .keyUp,
                keyCode: UInt16(kVK_ANSI_W),
                characters: "w",
                flags: .leftCommandDown,
                window: harness.window
            ))
        }
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))

        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: .leftWindows, isReleased: false),
            .keyboard(scancode: wKey, isReleased: false),
            .keyboard(scancode: wKey, isReleased: true),
            .keyboard(scancode: wKey, isReleased: false),
            .keyboard(scancode: wKey, isReleased: true),
            .keyboard(scancode: .leftWindows, isReleased: true),
        ])
    }

    func testTheKeyUpMonitorIgnoresKeyUpsFromOtherWindows() {
        // Every capture view's monitor sees all of the app's key-ups.
        let harness = makeHarness()
        let other = makeHarness()
        let wKey = RDPKeyboardScancode(code: 0x11)
        let releaseW = { (window: NSWindow) in
            NSApplication.shared.sendEvent(self.keyEvent(
                .keyUp,
                keyCode: UInt16(kVK_ANSI_W),
                characters: "w",
                flags: .leftCommandDown,
                window: window
            ))
        }
        _ = harness.view.performKeyEquivalent(
            with: keyEvent(.keyDown, keyCode: UInt16(kVK_ANSI_W), characters: "w", flags: .leftCommandDown)
        )
        harness.recorder.events.removeAll()

        releaseW(other.window)
        XCTAssertEqual(harness.recorder.events, [])
        releaseW(harness.window)
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: wKey, isReleased: true)])
        XCTAssertEqual(other.recorder.events, [])
    }

    func testCommandTappedWhileAKeyIsHeldLeavesTheKeyDown() {
        // Only the key's own keyUp releases it; Command going up does not.
        let harness = makeHarness()
        let leftArrow = RDPKeyboardScancode(code: 0x4B, isExtended: true)
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_LeftArrow)))
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_LeftArrow), isARepeat: true))
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: UInt16(kVK_LeftArrow)))

        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: leftArrow, isReleased: false),
            .keyboard(scancode: .leftWindows, isReleased: false),
            .keyboard(scancode: .leftWindows, isReleased: true),
            .keyboard(scancode: leftArrow, isReleased: false, wasDown: true),
            .keyboard(scancode: leftArrow, isReleased: true),
        ])
    }

    func testKeyHeldAsScancodeKeepsRepeatingAsItsScancodeAfterTheModifierIsReleased() {
        // Option-C goes as a scancode; once Option is released the held C
        // auto-repeats with no modifiers, and typing "c" as text on top of
        // the C the server holds would double it up.
        let harness = makeHarness()
        let leftOption = RDPKeyboardScancode(code: 0x38)
        let cKey = RDPKeyboardScancode(code: 0x2E)
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Option), flags: .leftOptionDown))
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_ANSI_C), characters: "ç", flags: .leftOptionDown))
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Option), flags: []))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: leftOption, isReleased: false),
            .keyboard(scancode: cKey, isReleased: false),
            .keyboard(scancode: leftOption, isReleased: true),
        ])

        harness.recorder.events.removeAll()
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_ANSI_C), characters: "c", isARepeat: true))
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: UInt16(kVK_ANSI_C), characters: "c"))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: cKey, isReleased: false, wasDown: true),
            .keyboard(scancode: cKey, isReleased: true),
        ])
    }

    // MARK: - Key equivalents while controlling the desktop

    func testPerformKeyEquivalentClaimsCommandChordForRemote() {
        // ⌘R must reach the remote as Win+R instead of triggering the
        // Session menu's Reconnect shortcut.
        let harness = makeHarness()

        let handled = harness.view.performKeyEquivalent(
            with: keyEvent(.keyDown, keyCode: 15, characters: "r", flags: .leftCommandDown)
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: .leftWindows, isReleased: false),
            .keyboard(scancode: RDPKeyboardScancode(code: 0x0013), isReleased: false),
        ])
    }

    func testPerformKeyEquivalentDefersWithoutInputSession() {
        let harness = makeHarness()
        harness.view.inputSession = nil

        let handled = harness.view.performKeyEquivalent(
            with: keyEvent(.keyDown, keyCode: 15, characters: "r", flags: .leftCommandDown)
        )
        XCTAssertFalse(handled)
    }

    func testPerformKeyEquivalentDefersWhenNotFirstResponder() {
        let harness = makeHarness(isFirstResponder: false)
        XCTAssertNotIdentical(harness.window.firstResponder, harness.view)

        let handled = harness.view.performKeyEquivalent(
            with: keyEvent(.keyDown, keyCode: 15, characters: "r", flags: .leftCommandDown)
        )
        XCTAssertFalse(handled)
        XCTAssertEqual(harness.recorder.events, [])
    }

    // MARK: - Typing

    func testTypingSendsScancodesWhenTheAnnouncedLayoutTypesTheSameCharacter() {
        // Scancodes reach a remote IME; Unicode arrives as VK_PACKET.
        let harness = makeHarness()
        let qKey = RDPKeyboardScancode(code: 0x10)
        let space = RDPKeyboardScancode(code: 0x39)
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_ANSI_Q), characters: "q"))
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: UInt16(kVK_ANSI_Q), characters: "q"))
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_Space), characters: " "))
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: UInt16(kVK_Space), characters: " "))
        // German: the Mac's Y key types "z", which German Windows types with
        // the scancode of US "y".
        harness.view.keyboardLayout = RDPKeyboardLayout(rawValue: 0x0000_0407)
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_ANSI_Y), characters: "z"))

        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: qKey, isReleased: false),
            .keyboard(scancode: qKey, isReleased: true),
            .keyboard(scancode: space, isReleased: false),
            .keyboard(scancode: space, isReleased: true),
            .keyboard(scancode: RDPKeyboardScancode(code: 0x15), isReleased: false),
        ])
    }

    func testTextTheLayoutTypesDifferentlyGoesAsUnicodePressReleasePairs() {
        let harness = makeHarness()
        // A character a dead key composed.
        harness.view.keyDown(with: keyEvent(
            .keyDown,
            keyCode: UInt16(kVK_ANSI_E),
            characters: "é",
            charactersIgnoringModifiers: "e"
        ))
        // A dead key types nothing, and Space after it the accent.
        harness.view.keyDown(with: keyEvent(
            .keyDown,
            keyCode: UInt16(kVK_ANSI_6),
            characters: "",
            charactersIgnoringModifiers: "^"
        ))
        harness.view.keyDown(with: keyEvent(
            .keyDown,
            keyCode: UInt16(kVK_Space),
            characters: "^",
            charactersIgnoringModifiers: " "
        ))
        XCTAssertEqual(harness.recorder.events, [
            .unicode(codeUnit: 0xE9, isReleased: false),
            .unicode(codeUnit: 0xE9, isReleased: true),
            .unicode(codeUnit: 0x5E, isReleased: false),
            .unicode(codeUnit: 0x5E, isReleased: true),
        ])

        harness.recorder.events.removeAll()
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: UInt16(kVK_ANSI_E), characters: "é"))
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testKeypadEqualsGoesAsUnicodeWhereItsScancodeTypesSomethingElse() {
        // PC keypads have no "=": keypad "=" goes as the main-row key US
        // Windows types "=" with, which is a dead "´" on German.
        let harness = makeHarness()
        let mainRowEquals = RDPKeyboardScancode(code: 0x0D)
        let keypadEquals = UInt16(kVK_ANSI_KeypadEquals)
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: keypadEquals, characters: "="))
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: keypadEquals, characters: "="))
        harness.view.keyboardLayout = RDPKeyboardLayout(rawValue: 0x0000_0407)
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: keypadEquals, characters: "="))

        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: mainRowEquals, isReleased: false),
            .keyboard(scancode: mainRowEquals, isReleased: true),
            .unicode(codeUnit: 0x3D, isReleased: false),
            .unicode(codeUnit: 0x3D, isReleased: true),
        ])
    }

    func testF2SendsItsScancodeInsteadOfAFunctionKeyCharacter() {
        // AppKit reports F2 as the private-use character NSF2FunctionKey,
        // which used to go to the remote as Unicode.
        let harness = makeHarness()
        let f2 = RDPKeyboardScancode(code: 0x3C)
        let functionKey = String(utf16CodeUnits: [0xF705], count: 1)
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_F2), characters: functionKey))
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: UInt16(kVK_F2), characters: functionKey))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: f2, isReleased: false),
            .keyboard(scancode: f2, isReleased: true),
        ])
    }

    // MARK: - Helpers

    /// The view starts as first responder, as it is while the user controls
    /// the desktop; the synchronize that focus sends is cleared.
    private func makeHarness(isFirstResponder: Bool = true) -> Harness {
        let recorder = InputEventRecorder()
        let view = RemoteInputCaptureNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.rdpFrame = makeFrameMetadata(width: 200, height: 100)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.inputSession = recorder
        if isFirstResponder {
            window.makeFirstResponder(view)
            recorder.events.removeAll()
        }
        return Harness(window: window, view: view, recorder: recorder)
    }

    /// What focus synchronization sends for the keyboard's current lock state.
    private var currentToggleFlags: RDPToggleKeyFlags {
        MacRDPKeyboardMapping.toggleFlags(for: NSEvent.modifierFlags)
    }

    private func resignKey(_ harness: Harness) {
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: harness.window
        )
    }

    private func keyEvent(
        _ type: NSEvent.EventType,
        keyCode: UInt16,
        characters: String = "",
        charactersIgnoringModifiers: String? = nil,
        flags: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false,
        window: NSWindow? = nil
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        ) else {
            preconditionFailure("Failed to synthesize key event")
        }
        return event
    }

    private func flagsEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        keyEvent(.flagsChanged, keyCode: keyCode, flags: flags)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        location: NSPoint,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            preconditionFailure("Failed to synthesize mouse event")
        }
        return event
    }

    private func scrollEvent() -> NSEvent {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ) else {
            preconditionFailure("Failed to synthesize scroll event")
        }
        cgEvent.flags = []
        guard let event = NSEvent(cgEvent: cgEvent) else {
            preconditionFailure("Failed to convert scroll event")
        }
        return event
    }

    private func isPointerMove(_ event: RDPSlowPathInputEvent?) -> Bool {
        guard case .pointerMove = event else {
            return false
        }
        return true
    }

    private func isPointerButton(
        _ event: RDPSlowPathInputEvent?,
        button: RDPPointerButton,
        isDown: Bool
    ) -> Bool {
        guard case let .pointerButton(eventButton, eventIsDown, _, _) = event else {
            return false
        }
        return eventButton == button && eventIsDown == isDown
    }

    private func makeFrameMetadata(width: UInt16, height: UInt16) -> RDPFrameMetadata {
        RDPFrameMetadata(RDPGraphicsFrameSnapshot(
            frameID: 1,
            surfaceID: 0,
            codecID: 0,
            codecName: "test",
            pixelFormat: 0,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: width, bottom: height),
            regionRects: [],
            encodedVideoData: Data()
        ))
    }
}

@MainActor
private final class InputEventRecorder: RemoteInputEventSink {
    var events: [RDPSlowPathInputEvent] = []

    nonisolated func send(_ events: [RDPSlowPathInputEvent]) {
        MainActor.assumeIsolated {
            self.events += events
        }
    }
}

private extension UInt16 {
    static let leftCommand: UInt16 = 55
    static let leftControl: UInt16 = 59
}

private extension NSEvent.ModifierFlags {
    /// `.command` plus the NX_DEVICELCMDKEYMASK device-dependent bit.
    static let leftCommandDown = NSEvent.ModifierFlags(
        rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0000_0008
    )

    /// `.control` plus the NX_DEVICELCTLKEYMASK device-dependent bit.
    static let leftControlDown = NSEvent.ModifierFlags(
        rawValue: NSEvent.ModifierFlags.control.rawValue | 0x0000_0001
    )

    /// `.option` plus the NX_DEVICELALTKEYMASK device-dependent bit.
    static let leftOptionDown = NSEvent.ModifierFlags(
        rawValue: NSEvent.ModifierFlags.option.rawValue | 0x0000_0020
    )

    /// `.shift` plus the NX_DEVICELSHIFTKEYMASK device-dependent bit.
    static let leftShiftDown = NSEvent.ModifierFlags(
        rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x0000_0002
    )
}

private extension RDPKeyboardScancode {
    static let leftWindows = RDPKeyboardScancode(code: 0x005B, isExtended: true)
    static let leftControl = RDPKeyboardScancode(code: 0x001D)
}
