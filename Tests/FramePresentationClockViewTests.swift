import AppKit
import XCTest

@MainActor
final class FramePresentationClockViewTests: XCTestCase {
    private struct Harness {
        let window: NSWindow
        let clock: FramePresentationClockNSView
    }

    // MARK: - Idle display link

    func testFrameRequestRunsTheLinkUntilItFires() {
        let harness = makeHarness()
        var frameCount = 0
        harness.clock.onFrame = { _ in frameCount += 1 }
        harness.clock.isEnabled = true
        XCTAssertFalse(harness.clock.isDisplayLinkRunning, "With no frame waiting, the link idles")

        harness.clock.requestFrame()
        XCTAssertTrue(harness.clock.isDisplayLinkRunning)

        fire(harness)
        XCTAssertEqual(frameCount, 1)
        XCTAssertFalse(harness.clock.isDisplayLinkRunning)
    }

    func testFrameRequestedDuringAFireKeepsTheLinkRunning() {
        let harness = makeHarness()
        let clock = harness.clock
        clock.onFrame = { [weak clock] _ in clock?.requestFrame() }
        clock.isEnabled = true
        clock.requestFrame()

        fire(harness)
        XCTAssertTrue(clock.isDisplayLinkRunning)
    }

    func testFrameRequestedWhileDisabledWaitsUntilEnabled() {
        let harness = makeHarness()
        var frameCount = 0
        harness.clock.onFrame = { _ in frameCount += 1 }

        harness.clock.requestFrame()
        XCTAssertFalse(harness.clock.isDisplayLinkRunning)

        harness.clock.isEnabled = true
        XCTAssertTrue(harness.clock.isDisplayLinkRunning)

        fire(harness)
        XCTAssertEqual(frameCount, 1)
        XCTAssertFalse(harness.clock.isDisplayLinkRunning)
    }

    func testDisablingPausesTheLinkAndKeepsTheRequest() {
        let harness = makeHarness()
        harness.clock.isEnabled = true
        harness.clock.requestFrame()

        harness.clock.isEnabled = false
        XCTAssertFalse(harness.clock.isDisplayLinkRunning)

        harness.clock.isEnabled = true
        XCTAssertTrue(harness.clock.isDisplayLinkRunning)
    }

    // MARK: - Timing

    func testTimingBeforeTheLinkFiresUsesTheScreenRefreshRate() throws {
        let harness = makeHarness()
        guard let screen = harness.window.screen else {
            throw XCTSkip("The test window is on no screen.")
        }
        var lastState: RDPFramePacingState?
        let published = expectation(description: "timing published")
        published.assertForOverFulfill = false
        harness.clock.onTimingChange = { state in
            lastState = state
            if state.isDisplayLinkPaused == false {
                published.fulfill()
            }
        }

        harness.clock.isEnabled = true
        wait(for: [published], timeout: 2)

        let framesPerSecond = try XCTUnwrap(lastState?.displayLinkFramesPerSecond)
        XCTAssertEqual(framesPerSecond, Double(screen.maximumFramesPerSecond), accuracy: 0.001)
    }

    // MARK: - Helpers

    private func makeHarness() -> Harness {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let clock = FramePresentationClockNSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView?.addSubview(clock)
        // Leaving the window invalidates the display link, which holds the
        // clock as its target.
        addTeardownBlock { @MainActor in
            clock.removeFromSuperview()
        }
        return Harness(window: window, clock: clock)
    }

    /// Stands in for a display refresh: the clock only passes the link on.
    private func fire(_ harness: Harness) {
        let link = harness.window.displayLink(
            target: harness.clock,
            selector: #selector(FramePresentationClockNSView.displayLinkFired(_:))
        )
        harness.clock.displayLinkFired(link)
        link.invalidate()
    }
}
