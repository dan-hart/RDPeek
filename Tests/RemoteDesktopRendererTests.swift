import AppKit
import AVFoundation
import RDPKit
import XCTest

final class RemoteDesktopRendererTests: XCTestCase {
    @MainActor
    func testViewportCropsSampleBufferLayerAndMasksExcludedDisplay() throws {
        let monitors = [
            RDPMonitorDefinition(left: -100, top: 0, right: -1, bottom: 99, flags: 0),
            RDPMonitorDefinition(left: 0, top: 0, right: 99, bottom: 99, flags: 1),
            RDPMonitorDefinition(left: 100, top: 0, right: 199, bottom: 99, flags: 0),
        ]
        let view = RemoteDesktopSampleBufferNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        view.viewport = RemoteDisplayViewport(frameSize: CGSize(width: 300, height: 100), monitors: monitors,
                                             selection: .only([monitors[1]]))
        view.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(view.layer?.sublayers?.first)
        let video = try XCTUnwrap(container.sublayers?.first as? AVSampleBufferDisplayLayer)
        let mask = try XCTUnwrap(container.mask as? CAShapeLayer)
        let singlePath = try XCTUnwrap(mask.path)
        XCTAssertEqual(container.frame, CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(video.frame, CGRect(x: -150, y: 0, width: 600, height: 200))
        XCTAssertEqual(video.videoGravity, .resize)
        XCTAssertEqual(singlePath.boundingBox, CGRect(x: 50, y: 0, width: 200, height: 200))
        XCTAssertFalse(singlePath.contains(CGPoint(x: 25, y: 100)))
        XCTAssertTrue(singlePath.contains(CGPoint(x: 150, y: 100)))

        view.viewport = RemoteDisplayViewport(frameSize: CGSize(width: 300, height: 100), monitors: monitors,
                                             selection: .only([monitors[0], monitors[2]]))
        view.layoutSubtreeIfNeeded()
        let subsetPath = try XCTUnwrap(mask.path)
        XCTAssertTrue(container.sublayers?.first === video)
        XCTAssertEqual(video.frame, CGRect(x: 0, y: 50, width: 300, height: 100))
        XCTAssertEqual(subsetPath.boundingBox, CGRect(x: 0, y: 50, width: 300, height: 100))
        XCTAssertTrue(subsetPath.contains(CGPoint(x: 50, y: 100)))
        XCTAssertTrue(subsetPath.contains(CGPoint(x: 250, y: 100)))
        XCTAssertFalse(subsetPath.contains(CGPoint(x: 150, y: 100)))
        XCTAssertFalse(subsetPath.contains(CGPoint(x: 50, y: 25)))
    }

    func testHealthyRendererEnqueuesWithoutFlushing() {
        XCTAssertEqual(
            rdpSampleBufferDisplayDisposition(
                displayFormatWillChange: false,
                rendererFailed: false,
                requiresFlushToResume: false
            ),
            .enqueue
        )
    }

    func testRendererFlushesForEveryRecoveryCondition() {
        XCTAssertEqual(
            rdpSampleBufferDisplayDisposition(
                displayFormatWillChange: true,
                rendererFailed: false,
                requiresFlushToResume: false
            ),
            .flushAndEnqueue
        )
        XCTAssertEqual(
            rdpSampleBufferDisplayDisposition(
                displayFormatWillChange: false,
                rendererFailed: true,
                requiresFlushToResume: false
            ),
            .flushAndEnqueue
        )
        XCTAssertEqual(
            rdpSampleBufferDisplayDisposition(
                displayFormatWillChange: false,
                rendererFailed: false,
                requiresFlushToResume: true
            ),
            .flushAndEnqueue
        )
    }
}
