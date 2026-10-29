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
}

@MainActor
final class RemoteDesktopSampleBufferViewTests: XCTestCase {
    func testFailedLayerShowsTheLastFrameAgain() throws {
        let layer = RecordingDisplayLayer()
        let view = RemoteDesktopSampleBufferNSView(frame: .zero, displayLayer: layer)
        view.present(try makePresentation(), id: 1)
        let shownSample = try XCTUnwrap(layer.enqueuedSamples.last)
        let flushCount = layer.flushCount

        layer.reportsFailure = true
        postDecodeFailure(of: layer)

        XCTAssertEqual(layer.enqueuedSamples.count, 2)
        XCTAssertTrue(layer.enqueuedSamples.last === shownSample)
        XCTAssertEqual(layer.flushCount, flushCount + 1, "The failed queue is flushed before the frame goes in again")
    }

    func testLayerThatKeepsFailingGetsEachFrameAgainOnlyOnce() throws {
        let layer = RecordingDisplayLayer()
        let view = RemoteDesktopSampleBufferNSView(frame: .zero, displayLayer: layer)
        view.present(try makePresentation(), id: 1)
        layer.reportsFailure = true

        postDecodeFailure(of: layer)
        postDecodeFailure(of: layer)
        XCTAssertEqual(layer.enqueuedSamples.count, 2)

        view.present(try makePresentation(), id: 2)
        XCTAssertEqual(layer.enqueuedSamples.count, 3)
        postDecodeFailure(of: layer)
        XCTAssertEqual(layer.enqueuedSamples.count, 4)
        XCTAssertTrue(layer.enqueuedSamples[3] === layer.enqueuedSamples[2])
    }

    func testFailureNoticeForAHealthyLayerChangesNothing() throws {
        let layer = RecordingDisplayLayer()
        let view = RemoteDesktopSampleBufferNSView(frame: .zero, displayLayer: layer)
        view.present(try makePresentation(), id: 1)

        postDecodeFailure(of: layer)

        XCTAssertEqual(layer.enqueuedSamples.count, 1)
    }

    func testClearedViewShowsNothingAgain() throws {
        let layer = RecordingDisplayLayer()
        let view = RemoteDesktopSampleBufferNSView(frame: .zero, displayLayer: layer)
        view.present(try makePresentation(), id: 1)
        view.clear()

        layer.reportsFailure = true
        postDecodeFailure(of: layer)

        XCTAssertEqual(layer.enqueuedSamples.count, 1)
    }

    // MARK: - Helpers

    private func postDecodeFailure(of layer: AVSampleBufferDisplayLayer) {
        NotificationCenter.default.post(name: .AVSampleBufferDisplayLayerFailedToDecode, object: layer)
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

/// Records what the view enqueues instead of decoding it, and reports a
/// failure on demand.
private final class RecordingDisplayLayer: AVSampleBufferDisplayLayer {
    var reportsFailure = false
    private(set) var enqueuedSamples: [CMSampleBuffer] = []
    private(set) var flushCount = 0

    override var status: AVQueuedSampleBufferRenderingStatus {
        reportsFailure ? .failed : .rendering
    }

    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        enqueuedSamples.append(sampleBuffer)
    }

    override func flush() {
        flushCount += 1
    }
}
