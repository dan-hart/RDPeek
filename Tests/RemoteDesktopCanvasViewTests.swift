import AppKit
import RDPKit
import XCTest

@MainActor
final class RemoteDesktopCanvasViewTests: XCTestCase {
    func testLetterboxedDesktopStartsOnAWholePixelAt1x() {
        // A 1x canvas an odd number of points wider or taller than the
        // desktop letterboxes it by half a point, which would blur it.
        let desktop = makeFrame(width: 1280, height: 800)
        for canvasSize in [
            CGSize(width: 1281, height: 800),
            CGSize(width: 1280, height: 801),
            CGSize(width: 1283, height: 805),
            CGSize(width: 1025, height: 641),
            CGSize(width: 801, height: 1001),
        ] {
            let canvas = makeCanvas(size: canvasSize, showing: desktop)
            let videoFrame = canvas.displayView.frame
            let inputFrame = inputView(of: canvas)?.frame

            XCTAssertEqual(inputFrame, videoFrame, "Input maps through the viewport the video is drawn in")
            XCTAssertEqual(videoFrame.size, canvas.bounds.size, "\(canvasSize)")
            let origin = desktopOrigin(of: desktop, in: videoFrame)
            XCTAssertEqual(origin.x, origin.x.rounded(), accuracy: 1e-9, "\(canvasSize)")
            XCTAssertEqual(origin.y, origin.y.rounded(), accuracy: 1e-9, "\(canvasSize)")
        }
    }

    func testDesktopThatFillsTheCanvasIsNotShifted() {
        let canvas = makeCanvas(size: CGSize(width: 1280, height: 800), showing: makeFrame(width: 1280, height: 800))

        XCTAssertEqual(canvas.displayView.frame, canvas.bounds)
        XCTAssertEqual(inputView(of: canvas)?.frame, canvas.bounds)
    }

    // MARK: - Helpers

    private func makeCanvas(size: CGSize, showing frame: RDPFrameMetadata) -> RemoteDesktopCanvasNSView {
        let window = OneXWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let canvas = RemoteDesktopCanvasNSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = canvas
        canvas.update(frame: frame, hasPresentedFrame: true, inputSession: nil)
        canvas.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            window.contentView = nil
        }
        return canvas
    }

    private func inputView(of canvas: RemoteDesktopCanvasNSView) -> RemoteInputCaptureNSView? {
        canvas.subviews.lazy.compactMap { $0 as? RemoteInputCaptureNSView }.first
    }

    /// Where the desktop's corner lands in the canvas: the video layer and
    /// the input view letterbox it within their own bounds.
    private func desktopOrigin(of frame: RDPFrameMetadata, in viewFrame: CGRect) -> CGPoint {
        let content = RDPRemoteDisplayViewport(
            frame: frame,
            bounds: CGRect(origin: .zero, size: viewFrame.size),
            coordinateOrigin: .bottomLeft
        ).contentRect
        return CGPoint(x: viewFrame.minX + content.minX, y: viewFrame.minY + content.minY)
    }

    private func makeFrame(width: UInt16, height: UInt16) -> RDPFrameMetadata {
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

/// A window on a 1x display, whatever display the tests run on.
private final class OneXWindow: NSWindow {
    override var backingScaleFactor: CGFloat {
        1
    }
}
