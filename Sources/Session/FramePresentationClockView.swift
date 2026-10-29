import AppKit
import QuartzCore

/// An invisible view that owns the window's display link and publishes frame
/// pacing changes, so decoded frames can be presented on the display clock.
/// The link runs only while a frame waits for the next refresh, and timing is
/// read again only when the window's display changes.
final class FramePresentationClockNSView: NSView {
    private var displayLink: CADisplayLink?
    private weak var observedWindow: NSWindow?
    private var isFrameRequested = false
    /// Whether the link fired since it was made or the display changed;
    /// until it has, its duration is unset or the previous display's.
    private var hasFiredOnCurrentDisplay = false
    private var lastPublishedState = RDPFramePacingState()

    /// Called on the first display refresh after `requestFrame()`.
    var onFrame: ((CADisplayLink) -> Void)?
    var onTimingChange: ((RDPFramePacingState) -> Void)?

    /// Whether the session presents frames on the display clock; frames
    /// requested while it is off wait until it is on.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else {
                return
            }
            updateDisplayLinkPaused()
            publishTimingIfChanged()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            stopDisplayLink()
            stopObservingWindow()
            onFrame = nil
            onTimingChange = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureDisplayLink(for: window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopDisplayLink()
            stopObservingWindow()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        publishTimingIfChanged(force: true)
    }

    // Whether the display link waits for a refresh. Only tests read it.
    // swiftlint:disable:next unused_declaration
    var isDisplayLinkRunning: Bool {
        displayLink.map { $0.isPaused == false } ?? false
    }

    /// Runs the display link until its next refresh calls `onFrame`.
    func requestFrame() {
        guard isFrameRequested == false else {
            return
        }
        isFrameRequested = true
        updateDisplayLinkPaused()
    }

    private func updateDisplayLinkPaused() {
        displayLink?.isPaused = !(isEnabled && isFrameRequested)
    }

    private func configureDisplayLink(for nextWindow: NSWindow?) {
        guard observedWindow !== nextWindow || (nextWindow != nil && displayLink == nil) else {
            return
        }

        stopDisplayLink()
        stopObservingWindow()
        observedWindow = nextWindow
        hasFiredOnCurrentDisplay = false

        guard let nextWindow else {
            publishTimingIfChanged(force: true)
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayDidChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nextWindow
        )
        // A refresh-rate or resolution change keeps the window on its screen.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let nextDisplayLink = nextWindow.displayLink(
            target: self,
            selector: #selector(displayLinkFired(_:))
        )
        displayLink = nextDisplayLink
        updateDisplayLinkPaused()
        nextDisplayLink.add(to: .main, forMode: .common)
        publishTimingIfChanged(force: true)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func stopObservingWindow() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeScreenNotification,
                object: observedWindow
            )
        }
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        observedWindow = nil
    }

    /// Not private, so tests can stand in for a refresh.
    @objc func displayLinkFired(_ displayLink: CADisplayLink) {
        hasFiredOnCurrentDisplay = true
        isFrameRequested = false
        onFrame?(displayLink)
        // Pauses again unless onFrame requested another refresh.
        updateDisplayLinkPaused()
    }

    @objc private func displayDidChange(_: Notification) {
        hasFiredOnCurrentDisplay = false
        publishTimingIfChanged(force: true)
    }

    /// The display link idles between frames, so the published pause state
    /// is whether the clock is enabled, not whether the link is running.
    /// Its duration is read only once it fired on this display; until then
    /// the screen's refresh rate, which the link runs at, stands in.
    private func publishTimingIfChanged(force: Bool = false) {
        var nextState = RDPFramePacingState.current(
            window: observedWindow,
            displayLink: displayLink,
            isPaused: !isEnabled
        )
        if hasFiredOnCurrentDisplay == false,
           nextState.hasDisplayLink,
           let framesPerSecond = nextState.maximumFramesPerSecond,
           framesPerSecond > 0
        {
            nextState.displayLinkDuration = 1 / Double(framesPerSecond)
        }
        guard force || nextState != lastPublishedState else {
            return
        }
        lastPublishedState = nextState
        DispatchQueue.main.async { [weak self] in
            self?.onTimingChange?(nextState)
        }
    }
}
