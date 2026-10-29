import AppKit
import AVFoundation
import QuartzCore
import RDPKit

@MainActor
final class RDPRemoteDesktopRenderer {
    private weak var view: RemoteDesktopSampleBufferNSView?
    private var latestPresentation: (presentation: RDPDecodedFramePresentation, id: Int)?

    func attach(_ view: RemoteDesktopSampleBufferNSView) {
        guard self.view !== view else {
            return
        }
        self.view = view
        if let latestPresentation {
            view.present(latestPresentation.presentation, id: latestPresentation.id)
            self.latestPresentation = nil
        }
    }

    func present(_ presentation: RDPDecodedFramePresentation, id: Int) {
        guard let view else {
            latestPresentation = (presentation, id)
            return
        }
        latestPresentation = nil
        view.present(presentation, id: id)
    }

    func clear() {
        latestPresentation = nil
        view?.clear()
    }
}

final class RemoteDesktopSampleBufferNSView: NSView {
    private let displayLayer: AVSampleBufferDisplayLayer
    private let sampleBufferFactory = RDPFrameSampleBufferFactory()
    private var lastPresentationID: Int?
    private var lastSampleBuffer: CMSampleBuffer?
    private var failureObserver: (any NSObjectProtocol)?

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, displayLayer: AVSampleBufferDisplayLayer())
    }

    /// Tests pass a layer that can report a failure.
    init(frame frameRect: NSRect, displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        displayLayer = AVSampleBufferDisplayLayer()
        super.init(coder: coder)
        configureLayers()
    }

    deinit {
        MainActor.assumeIsolated {
            clear()
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        updateContentsScale()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            clear()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    func present(_ presentation: RDPDecodedFramePresentation, id: Int) {
        guard lastPresentationID != id else {
            return
        }

        let disposition = rdpSampleBufferDisplayDisposition(
            displayFormatWillChange: sampleBufferFactory.willChangeDisplayFormat(for: presentation),
            rendererFailed: displayLayer.status == .failed,
            requiresFlushToResume: displayLayer.requiresFlushToResumeDecoding
        )
        switch disposition {
        case .flushAndEnqueue:
            flushQueuedSamples()
        case .enqueue:
            break
        }

        do {
            let sampleBuffer = try sampleBufferFactory.makeSampleBuffer(for: presentation)
            displayLayer.enqueue(sampleBuffer)
            lastPresentationID = id
            lastSampleBuffer = sampleBuffer
        } catch {
            flushQueuedSamples()
        }
    }

    /// Also removes the shown image, so a later session never flashes the
    /// last one's desktop and its pixel buffer is released.
    func clear() {
        displayLayer.flushAndRemoveImage()
        lastPresentationID = nil
        lastSampleBuffer = nil
        sampleBufferFactory.reset()
    }

    private func configureLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        updateContentsScale()
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerFailedToDecode,
            object: displayLayer,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.redisplayLastSampleAfterFailure()
            }
        }
    }

    /// A failed layer shows nothing until the next frame, which a still
    /// remote desktop may not send for a long time, so show the last frame
    /// again — once per frame, so a layer that keeps failing cannot loop.
    private func redisplayLastSampleAfterFailure() {
        guard displayLayer.status == .failed, let sampleBuffer = lastSampleBuffer else {
            return
        }
        lastSampleBuffer = nil
        flushQueuedSamples()
        displayLayer.enqueue(sampleBuffer)
    }

    private func updateContentsScale() {
        displayLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private func flushQueuedSamples() {
        displayLayer.flush()
    }

}

enum RDPRemoteDesktopSampleBufferDisplayDisposition: Equatable {
    case enqueue
    case flushAndEnqueue
}

func rdpSampleBufferDisplayDisposition(
    displayFormatWillChange: Bool,
    rendererFailed: Bool,
    requiresFlushToResume: Bool
) -> RDPRemoteDesktopSampleBufferDisplayDisposition {
    if displayFormatWillChange || rendererFailed || requiresFlushToResume {
        return .flushAndEnqueue
    }
    return .enqueue
}

/// Holds the one decoded frame waiting for the next display-link tick.
@MainActor
final class RDPFramePresentationBuffer {
    private var pendingPresentation: RDPDecodedFramePresentation?

    func replacePendingPresentation(_ presentation: RDPDecodedFramePresentation) -> Bool {
        let replacedPendingPresentation = pendingPresentation != nil
        pendingPresentation = presentation
        return replacedPendingPresentation
    }

    func takePendingPresentation() -> RDPDecodedFramePresentation? {
        let presentation = pendingPresentation
        pendingPresentation = nil
        return presentation
    }

    func clear() {
        pendingPresentation = nil
    }
}
