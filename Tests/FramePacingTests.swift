import XCTest

final class FramePacingTests: XCTestCase {
    func testNormalizesDisplayLinkTiming() {
        let state = RDPFramePacingState(
            screenName: "Studio Display",
            backingScaleFactor: 2,
            maximumFramesPerSecond: nil,
            minimumRefreshInterval: 1.0 / 120.0,
            maximumRefreshInterval: 1.0 / 48.0,
            displayUpdateGranularity: 0,
            displayLinkDuration: 0.0167,
            hasDisplayLink: true,
            isDisplayLinkPaused: false
        )

        XCTAssertEqual(state.displayLinkDuration, 1.0 / 60.0)
        XCTAssertEqual(state.displayLinkFramesPerSecond, 60)
        XCTAssertEqual(state.maximumRefreshRate, 120)
        XCTAssertEqual(state.clockState, "window display link")
    }

    func testMarksUpdatedDisplayLinkActive() {
        let state = RDPFramePacingState().updatingDisplayLinkDuration(1.0 / 120.0)

        XCTAssertTrue(state.hasDisplayLink)
        XCTAssertFalse(state.isDisplayLinkPaused)
        XCTAssertEqual(state.displayLinkFramesPerSecond, 120)
        XCTAssertEqual(state.clockState, "window display link")
    }
}
