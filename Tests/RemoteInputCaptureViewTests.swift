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
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftWindows, isReleased: false)])

        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftWindows, isReleased: true)])
    }

    func testModifierWithoutSideBitsFollowsSideIndependentFlag() {
        // Some keyboards report only .shift, with no left/right device bit;
        // the key code still names the side that changed.
        let harness = makeHarness()
        let leftShift = RDPKeyboardScancode(code: 0x2A)
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Shift), flags: .shift))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: leftShift, isReleased: false)])

        harness.recorder.events.removeAll()
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: UInt16(kVK_ANSI_A), characters: "A", flags: .shift))
        XCTAssertEqual(harness.recorder.events, [
            .unicode(codeUnit: 0x41, isReleased: false),
            .unicode(codeUnit: 0x41, isReleased: true),
        ])

        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: UInt16(kVK_Shift), flags: []))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: leftShift, isReleased: true)])
    }

    func testRepeatedFlagsStateSendsNoDuplicateEvents() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.recorder.events.removeAll()

        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testMissedModifierReleaseDoesNotInvertPhase() {
        // Hold Cmd, then Cmd+Tab away: the release happens while another
        // app is active, so the view only sees the window resign key.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.recorder.events.removeAll()
        resignKey(harness)
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftWindows, isReleased: true)])

        // The next physical Cmd press must be sent as a press, not as the
        // inverted release the old toggle-based logic produced.
        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftWindows, isReleased: false)])
    }

    func testKeyDownResyncsStaleModifier() {
        // Cmd-down is tracked, then released without the view ever seeing
        // a flagsChanged. The next keystroke carries the truth in its
        // modifier flags and must repair the remote state first.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.recorder.events.removeAll()

        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 0, characters: "a"))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: .leftWindows, isReleased: true),
            .unicode(codeUnit: 0x61, isReleased: false),
            .unicode(codeUnit: 0x61, isReleased: true),
        ])
    }

    func testMouseDownResyncsStaleModifier() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.recorder.events.removeAll()

        harness.view.mouseDown(with: mouseEvent(.leftMouseDown, location: NSPoint(x: 100, y: 50)))
        XCTAssertEqual(harness.recorder.events.first, .keyboard(scancode: .leftWindows, isReleased: true))
        XCTAssertTrue(isPointerButton(harness.recorder.events.last, button: .left, isDown: true))
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

    // MARK: - Swallowed keyUp while Command is held

    func testCommandReleaseFlushesSwallowedKeyUp() {
        // AppKit never delivers the keyUp for W while Cmd is held, so the
        // flush on Cmd-up must release it.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 13, characters: "w", flags: .leftCommandDown))
        harness.recorder.events.removeAll()

        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: RDPKeyboardScancode(code: 0x0011), isReleased: true),
            .keyboard(scancode: .leftWindows, isReleased: true),
        ])
    }

    func testKeyRepeatAfterFlushIsRetrackedAndReleased() {
        // Hold Cmd+Left-arrow, release Cmd first: the flush releases the
        // arrow, but auto-repeat keeps pressing it. The repeat must be
        // re-tracked so the final physical keyUp reaches the remote.
        let harness = makeHarness()
        let leftArrow = RDPKeyboardScancode(code: 0x004B, isExtended: true)
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 123, flags: .leftCommandDown))
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        harness.recorder.events.removeAll()

        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 123, isARepeat: true))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: leftArrow, isReleased: false)])

        harness.recorder.events.removeAll()
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: 123))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: leftArrow, isReleased: true)])
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

    // MARK: - Normal typing is unaffected

    func testPlainTypingSendsUnicodePressReleasePairs() {
        let harness = makeHarness()
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 0, characters: "a"))
        XCTAssertEqual(harness.recorder.events, [
            .unicode(codeUnit: 0x61, isReleased: false),
            .unicode(codeUnit: 0x61, isReleased: true),
        ])

        harness.recorder.events.removeAll()
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: 0, characters: "a"))
        XCTAssertEqual(harness.recorder.events, [])
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
        flags: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
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
}

private extension NSEvent.ModifierFlags {
    /// `.command` plus the NX_DEVICELCMDKEYMASK device-dependent bit.
    static let leftCommandDown = NSEvent.ModifierFlags(
        rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0000_0008
    )

    /// `.shift` plus the NX_DEVICELSHIFTKEYMASK device-dependent bit.
    static let leftShiftDown = NSEvent.ModifierFlags(
        rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x0000_0002
    )
}

private extension RDPKeyboardScancode {
    static let leftWindows = RDPKeyboardScancode(code: 0x005B, isExtended: true)
}
