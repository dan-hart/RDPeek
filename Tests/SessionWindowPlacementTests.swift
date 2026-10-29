import AppKit
import XCTest

@MainActor
final class SessionWindowPlacementTests: XCTestCase {
    // MARK: - Initial frame placement

    func testApplyInitialFrameFillsVisibleFrame() {
        let window = TestWindow()
        let visibleFrame = NSRect(x: 10, y: 20, width: 1600, height: 1000)

        SessionWindowPlacement.applyInitialFrame(to: window, visibleFrame: visibleFrame)

        XCTAssertEqual(window.frame, visibleFrame)
    }

    func testApplyInitialFrameFallsBackToDefaultSizeWithoutScreen() {
        let window = TestWindow()

        SessionWindowPlacement.applyInitialFrame(to: window, visibleFrame: nil)

        XCTAssertEqual(
            window.contentRect(forFrameRect: window.frame).size,
            NSSize(width: 1280, height: 820)
        )
    }

    // MARK: - First-show guard

    func testFirstShowGuardClaimsExactlyOnce() {
        var showGuard = SessionWindowFirstShowGuard()
        XCTAssertTrue(showGuard.claimFirstShow())
        XCTAssertFalse(showGuard.claimFirstShow())
        XCTAssertFalse(showGuard.claimFirstShow())
    }

    // MARK: - Key flag clearing on close

    func testKeyFlagIsNotClearedWithoutAWindow() {
        XCTAssertFalse(SessionWindowKeyFlagPolicy.shouldClearOnClose(of: nil))
    }

    func testKeyFlagIsNotClearedForBackgroundWindow() {
        // The traffic-light close button closes background windows without
        // making them key; clearing the flag here would kill the Session
        // menu for the still-key window.
        XCTAssertFalse(SessionWindowKeyFlagPolicy.shouldClearOnClose(of: TestWindow()))
    }

    func testKeyFlagIsClearedForKeyWindow() {
        XCTAssertTrue(SessionWindowKeyFlagPolicy.shouldClearOnClose(of: TestWindow(isKey: true)))
    }
}
