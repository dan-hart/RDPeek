import AppKit
import RDPKit
import XCTest

final class RemoteDisplaySelectionTests: XCTestCase {
    private let monitors = [
        RDPMonitorDefinition(left: -100, top: 0, right: -1, bottom: 99, flags: 0),
        RDPMonitorDefinition(left: 0, top: 0, right: 99, bottom: 99, flags: 1),
        RDPMonitorDefinition(left: 100, top: 0, right: 199, bottom: 99, flags: 0),
    ]

    func testAllDisplaysNormalizesNegativeOrigins() {
        let viewport = RemoteDisplayViewport(frameSize: CGSize(width: 300, height: 100), monitors: monitors)
        XCTAssertEqual(viewport.sourceRect, CGRect(x: 0, y: 0, width: 300, height: 100))
        XCTAssertEqual(viewport.remotePoint(from: CGPoint(x: 5, y: 50), in: CGRect(x: 0, y: 0, width: 300, height: 100)),
                       RDPRemotePoint(x: 5, y: 50))
    }

    func testSingleDisplayCropsAndLetterboxes() {
        let viewport = RemoteDisplayViewport(frameSize: CGSize(width: 300, height: 100), monitors: monitors,
                                            selection: .only([monitors[2]]))
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(viewport.sourceRect, CGRect(x: 200, y: 0, width: 100, height: 100))
        XCTAssertEqual(viewport.destinationRect(in: bounds), CGRect(x: 50, y: 0, width: 100, height: 100))
        XCTAssertNil(viewport.remotePoint(from: CGPoint(x: 49, y: 50), in: bounds))
        XCTAssertEqual(viewport.remotePoint(from: CGPoint(x: 75, y: 25), in: bounds), RDPRemotePoint(x: 225, y: 75))
    }

    func testNonadjacentSelectionRetainsGapAndRejectsHiddenMonitor() {
        let viewport = RemoteDisplayViewport(frameSize: CGSize(width: 300, height: 100), monitors: monitors,
                                            selection: .only([monitors[0], monitors[2]]))
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 100)
        XCTAssertEqual(viewport.visibleRects.count, 2)
        XCTAssertNil(viewport.remotePoint(from: CGPoint(x: 150, y: 50), in: bounds))
        XCTAssertNotNil(viewport.remotePoint(from: CGPoint(x: 250, y: 50), in: bounds))
    }

    func testLayoutReconciliationUsesDescriptorRatherThanIndex() {
        var selection = RemoteDisplaySelection.only([monitors[0], monitors[2]])
        selection.reconcile(with: [monitors[2], monitors[1]])
        XCTAssertEqual(selection, .only([monitors[2]]))
        selection.reconcile(with: [monitors[1]])
        XCTAssertEqual(selection, .all)
    }

    func testToggleCannotRemoveFinalDisplayAndAllFollowsNewLayout() {
        var selection = RemoteDisplaySelection.all
        selection.toggle(monitors[0], in: monitors)
        XCTAssertEqual(selection, .only([monitors[1], monitors[2]]))
        selection.toggle(monitors[1], in: monitors)
        selection.toggle(monitors[2], in: monitors)
        XCTAssertEqual(selection, .only([monitors[2]]))
        selection = .all
        selection.reconcile(with: [monitors[1]])
        XCTAssertEqual(selection, .all)
    }

    func testRejectsReversedOverlappingDuplicateAndExtremeRectangles() {
        let reversed = RDPMonitorDefinition(left: 100, top: 0, right: 0, bottom: 99, flags: 0)
        let extreme = RDPMonitorDefinition(left: .min, top: 0, right: .max, bottom: 99, flags: 0)
        let overlap = RDPMonitorDefinition(left: -50, top: 0, right: 49, bottom: 99, flags: 0)
        for layout in [[reversed], [extreme], [monitors[0], monitors[0]], [monitors[0], overlap]] {
            XCTAssertTrue(RemoteDisplayViewport(frameSize: CGSize(width: 300, height: 100), monitors: layout).monitors.isEmpty)
        }
    }

    func testStackedLayoutPreservesVerticalArrangementAndNonzeroBounds() {
        let above = RDPMonitorDefinition(left: 0, top: -100, right: 99, bottom: -1, flags: 0)
        let primary = RDPMonitorDefinition(left: 0, top: 0, right: 199, bottom: 99, flags: 1)
        let viewport = RemoteDisplayViewport(frameSize: CGSize(width: 200, height: 200), monitors: [above, primary])
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 200)
        XCTAssertNil(viewport.remotePoint(from: CGPoint(x: 160, y: 170), in: bounds))
        XCTAssertEqual(viewport.remotePoint(from: CGPoint(x: 60, y: 170), in: bounds), RDPRemotePoint(x: 50, y: 50))
        XCTAssertEqual(viewport.localRect(for: CGRect(x: 0, y: 0, width: 100, height: 100), in: bounds),
                       CGRect(x: 10, y: 120, width: 100, height: 100))
        let single = RemoteDisplayViewport(frameSize: CGSize(width: 200, height: 200), monitors: [above, primary], selection: .only([above]))
        XCTAssertEqual(single.sourceRect, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testResizeRequiresDisplayedFrameAndNeverCollapsesReportedMultimonitorLayout() {
        XCTAssertFalse(remoteDisplayAllowsWindowMatching(hasPresentedFrame: false, reportedMonitorCount: 0))
        XCTAssertFalse(remoteDisplayAllowsWindowMatching(hasPresentedFrame: true, reportedMonitorCount: 2))
        XCTAssertTrue(remoteDisplayAllowsWindowMatching(hasPresentedFrame: true, reportedMonitorCount: 1))
        XCTAssertTrue(remoteDisplayAllowsWindowMatching(hasPresentedFrame: true, reportedMonitorCount: 0))
    }

    func testInvalidOrUnavailableLayoutUsesCompleteFrame() {
        let invalid = RDPMonitorDefinition(left: 0, top: 0, right: -1, bottom: 100, flags: 0)
        for layout in [[], [invalid], monitors] {
            let viewport = RemoteDisplayViewport(frameSize: CGSize(width: 50, height: 50), monitors: layout)
            XCTAssertTrue(viewport.monitors.isEmpty)
            XCTAssertEqual(viewport.sourceRect, CGRect(x: 0, y: 0, width: 50, height: 50))
        }
    }
}
