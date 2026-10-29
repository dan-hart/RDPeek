import AVFoundation
import CoreVideo
import RDPKit
import XCTest

final class RemoteDesktopRendererTests: XCTestCase {
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

    func testAFailedRendererShowsTheLastFrameAgainOnce() {
        XCTAssertTrue(rdpShouldResendLastPresentation(
            hasLastPresentation: true,
            didResendLastPresentation: false,
            rendererFailed: true,
            requiresFlushToResume: false
        ))
        XCTAssertTrue(rdpShouldResendLastPresentation(
            hasLastPresentation: true,
            didResendLastPresentation: false,
            rendererFailed: false,
            requiresFlushToResume: true
        ))
        XCTAssertFalse(rdpShouldResendLastPresentation(
            hasLastPresentation: true,
            didResendLastPresentation: true,
            rendererFailed: true,
            requiresFlushToResume: false
        ), "A renderer that fails again on the same frame waits for the next one")
        XCTAssertFalse(rdpShouldResendLastPresentation(
            hasLastPresentation: false,
            didResendLastPresentation: false,
            rendererFailed: true,
            requiresFlushToResume: true
        ), "A cleared view shows nothing again")
        XCTAssertFalse(rdpShouldResendLastPresentation(
            hasLastPresentation: true,
            didResendLastPresentation: false,
            rendererFailed: false,
            requiresFlushToResume: false
        ), "A notice for a healthy renderer changes nothing")
    }
}

@MainActor
final class RemoteDesktopSampleBufferViewTests: XCTestCase {
    /// On macOS 15 and later frames go to the display layer's
    /// `sampleBufferRenderer`, before and after the display is cleared.
    func testFramesRenderThroughTheDisplayLayersSampleBufferRenderer() throws {
        guard #available(macOS 15, *) else {
            throw XCTSkip("macOS 14 renders through the display layer itself")
        }
        let view = RemoteDesktopSampleBufferNSView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let displayLayer = try XCTUnwrap(view.layer?.sublayers?.first as? AVSampleBufferDisplayLayer)
        let renderer = displayLayer.sampleBufferRenderer
        let presentation = try makePresentation()
        XCTAssertEqual(renderer.status, .unknown)

        view.present(presentation, id: 1)
        XCTAssertEqual(renderer.status, .rendering)
        view.clear()
        view.present(presentation, id: 2)
        XCTAssertEqual(renderer.status, .rendering)
        XCTAssertNil(renderer.error)
    }

    /// A composed BGRA frame, as RDPKit hands one over once decoded.
    private func makePresentation() throws -> RDPDecodedFramePresentation {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer),
            kCVReturnSuccess
        )
        let frame = RDPGraphicsFrameSnapshot(
            frameID: 1,
            surfaceID: 0,
            codecID: 0,
            codecName: "test",
            pixelFormat: 0,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
            regionRects: [],
            encodedVideoData: Data(),
            contentKind: .bitmap
        )
        return try RDPDecodedFramePresentation(frame: frame, imageBuffer: XCTUnwrap(pixelBuffer))
    }
}
