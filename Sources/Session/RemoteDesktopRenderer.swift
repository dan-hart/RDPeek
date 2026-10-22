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

    @discardableResult
    func present(_ presentation: RDPDecodedFramePresentation, id: Int) -> Bool {
        guard let view else {
            latestPresentation = (presentation, id)
            return false
        }
        latestPresentation = nil
        return view.present(presentation, id: id)
    }

    func clear() {
        latestPresentation = nil
        view?.clear()
    }
}

final class RemoteDesktopSampleBufferNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let viewportLayer = CALayer()
    private let viewportMask = CAShapeLayer()
    var viewport: RemoteDisplayViewport? {
        didSet {
            guard viewport != oldValue else { return }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }
    private let sampleBufferFactory = RDPFrameSampleBufferFactory()
    private var lastPresentationID: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    deinit {
        MainActor.assumeIsolated {
            clear()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewportLayer.frame = bounds
        if let viewport {
            displayLayer.frame = viewport.localRect(for: CGRect(origin: .zero, size: viewport.frameSize), in: bounds)
            let path = CGMutablePath()
            for rect in viewport.visibleRects {
                path.addRect(viewport.localRect(for: rect, in: bounds))
            }
            viewportMask.frame = bounds
            viewportMask.path = path
            viewportLayer.mask = viewportMask
        } else {
            displayLayer.frame = bounds
            viewportLayer.mask = nil
        }
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

    @discardableResult
    func present(_ presentation: RDPDecodedFramePresentation, id: Int) -> Bool {
        guard lastPresentationID != id else {
            return true
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
            return true
        } catch {
            flushQueuedSamples()
            return false
        }
    }

    func clear() {
        flushQueuedSamples()
        lastPresentationID = nil
        sampleBufferFactory.reset()
    }

    private func configureLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resize
        layer?.masksToBounds = true
        layer?.addSublayer(viewportLayer)
        viewportLayer.addSublayer(displayLayer)
        updateContentsScale()
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
