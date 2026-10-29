import RDPKit
import XCTest

final class ViewerMetricsSummaryTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)
    private let displayLink = RDPFramePacingState(displayLinkDuration: 1.0 / 120)

    func testBusyStreamShowsItsRates() throws {
        let metrics = busyMetrics()

        let summary = try XCTUnwrap(compactViewerMetricsSummary(
            metrics: metrics,
            framePacing: displayLink,
            lastWireReceiveAt: start.addingTimeInterval(1),
            now: start.addingTimeInterval(1.5)
        ))

        XCTAssertEqual(summary, "10.0 fps  ·  decode 2.0 ms  ·  rx \(megabits(metrics))  ·  120 Hz")
    }

    func testStillDesktopIsIdleRatherThanItsLastRates() throws {
        let summary = try XCTUnwrap(compactViewerMetricsSummary(
            metrics: busyMetrics(),
            framePacing: displayLink,
            lastWireReceiveAt: start.addingTimeInterval(1),
            now: start.addingTimeInterval(1 + viewerMetricsIdleInterval)
        ))

        XCTAssertEqual(summary, "idle  ·  decode 2.0 ms  ·  rx idle  ·  120 Hz")
    }

    func testBytesStillArrivingKeepTheirRateWhileFramesAreIdle() throws {
        let metrics = busyMetrics()
        let now = start.addingTimeInterval(1 + viewerMetricsIdleInterval)

        let summary = try XCTUnwrap(compactViewerMetricsSummary(
            metrics: metrics,
            framePacing: displayLink,
            lastWireReceiveAt: now.addingTimeInterval(-0.5),
            now: now
        ))

        XCTAssertEqual(summary, "idle  ·  decode 2.0 ms  ·  rx \(megabits(metrics))  ·  120 Hz")
    }

    func testNothingReceivedShowsOnlyTheDisplay() {
        XCTAssertEqual(
            compactViewerMetricsSummary(
                metrics: RDPRenderMetrics(),
                framePacing: displayLink,
                lastWireReceiveAt: nil,
                now: start
            ),
            "120 Hz"
        )
        XCTAssertNil(compactViewerMetricsSummary(
            metrics: RDPRenderMetrics(),
            framePacing: RDPFramePacingState(),
            lastWireReceiveAt: nil,
            now: start
        ))
    }

    // MARK: - Helpers

    /// Ten frames a second for one second, and bytes alongside them.
    private func busyMetrics() -> RDPRenderMetrics {
        var metrics = RDPRenderMetrics(connectionStartedAt: start)
        let timing = RDPFrameDecodeTiming(
            samplePreparationMilliseconds: 0.5,
            videoToolboxMilliseconds: 1,
            imageConversionMilliseconds: 0.5,
            totalMilliseconds: 2,
            decodedPixelFormat: nil,
            usesHardwareAcceleration: nil
        )
        for index in 0 ... 10 {
            let decodedAt = start.addingTimeInterval(Double(index) / 10)
            metrics.recordDecodedFrame(frameSnapshot(), receivedAt: decodedAt, decodedAt: decodedAt, timing: timing)
            metrics.recordWireReceive(RDPWireReceiveSample(byteCount: 12500, receivedAt: decodedAt))
        }
        return metrics
    }

    private func megabits(_ metrics: RDPRenderMetrics) -> String {
        String(format: "%.1f Mbps", metrics.rollingWireMegabitsPerSecond ?? 0)
    }

    private func frameSnapshot() -> RDPGraphicsFrameSnapshot {
        RDPGraphicsFrameSnapshot(
            frameID: 1,
            surfaceID: 0,
            codecID: 0,
            codecName: "test",
            pixelFormat: 0,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
            regionRects: [],
            encodedVideoData: Data()
        )
    }
}

final class FrameAcknowledgeSummaryTests: XCTestCase {
    func testFewerAcknowledgementsThanRDPKitRecordsAreTheTotal() {
        XCTAssertEqual(frameAcknowledgeSummary(nil), "none")
        XCTAssertEqual(frameAcknowledgeSummary([]), "none")
        XCTAssertEqual(frameAcknowledgeSummary(Array(repeating: "00", count: 3)), "3")
    }

    func testAFullRecordIsOnlyASample() {
        XCTAssertEqual(frameAcknowledgeSummary(Array(repeating: "00", count: 8)), "8+ (first 8 recorded)")
    }
}
