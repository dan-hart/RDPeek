import AppKit
import XCTest

@MainActor
final class SessionTitlebarAccessoryTests: XCTestCase {
    func testTitlebarReservesSpaceForAllControlsBeforeAttachment() {
        let view = SessionTitlebarAccessory.makeHostingView(model: SessionHUDModel())

        XCTAssertGreaterThan(view.fittingSize.width, 100)
        XCTAssertGreaterThanOrEqual(view.frame.width, view.fittingSize.width)
        XCTAssertGreaterThan(view.frame.height, 0)
    }
}
