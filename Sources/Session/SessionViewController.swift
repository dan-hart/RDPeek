import AppKit
import QuartzCore
import RDPKit
import SwiftUI

/// Owns one remote desktop connection and the views that present it.
///
/// The connection, clipboard, display-control, audio, and credential logic is
/// adapted from the RDPKit example client; the presentation layer is replaced
/// with a full-bleed canvas plus SwiftUI HUD overlays.
@MainActor
final class SessionViewController: NSViewController {
    private let credentialStore = KeychainCredentialStore()
    private let clientLicenseStore = ClientLicenseStore()
    private let trustedCertificateStore = TrustedCertificateStore()
    private let sessionID: UUID
    private weak var launchStore: SessionLaunchStore?

    let hudModel = SessionHUDModel()
    private(set) var draft: RDPConnectionDraft

    private var requestedDesktopSizeLabel = "auto"
    private var rememberPassword: Bool
    private var hasRememberedPassword = false
    private var isAwaitingCredentials = false
    private var isResolvingStoredCredentials = false
    private var didPromptForCredentials = false
    private var isConnecting = false
    private var hasEverPresentedFrame = false
    private var autoRetryCount = 0
    private var isAutoRetryPending = false
    private var autoRetryTask: Task<Void, Never>?
    private var firstFrameWatchdogTask: Task<Void, Never>?
    private var audioMessage: String?
    private var activeConnectionID: UUID?
    private var activeCancellation: RDPConnectionCancellation?
    private var sessionEndReason: RDPSessionEndReason?
    private var inputSession: RDPInputSession?
    private var displayControlSession: RDPDisplayControlSession?
    private var autoApplyViewerSize = true
    private var pendingDisplayResizeTask: Task<Void, Never>?
    private var lastRequestedDisplayRequest: RDPDisplayRequest?
    private var viewerPointSize: CGSize = .zero
    private var viewerPixelSize: RDPViewerPixelSize?
    private let clipboard: SessionClipboard
    private var audioPlaybackEnabled: Bool
    private var remoteAudioPlayer = RDPAudioPlayer()
    private var report: RDPConnectionReport?
    private var liveCertificate: RDPServerCertificateInfo?
    private var previewFrame: RDPFrameMetadata?
    private var previewFrameCount = 0
    private var viewerMetricsSummary: String?
    private var previewDecodeError: String?
    private var hasPresentedFrame = false
    private var framePresentationBuffer = RDPFramePresentationBuffer()
    private var framePacing = RDPFramePacingState()
    private var remoteDesktopRenderer = RDPRemoteDesktopRenderer()
    private var renderMetricsStore = RDPRenderMetricsStore()
    private let diagnosticsModel = RemoteSessionDiagnosticsModel()
    private var certificateTrustedByApp = false
    private var certificateRefusal: CertificateRefusal?
    private var certificateTrustMessage: String?
    private var shouldAutoConnect = true
    private var diagnosticsTask: Task<Void, Never>?
    private var clipboardPollingTask: Task<Void, Never>?
    private var overlayVisibilityTask: Task<Void, Never>?
    private var didClose = false

    private let canvasView = RemoteDesktopCanvasNSView()
    private let titlebarBackdrop = NSVisualEffectView()
    private let frameClockView = FramePresentationClockNSView()
    private var overlayHost: NSHostingView<SessionOverlayRoot>?
    private var bannerHost: NSHostingView<SessionBannerRoot>?
    private var toastHost: PassThroughHostingView<SessionToastRoot>?
    private var metricsHost: PassThroughHostingView<SessionMetricsRoot>?

    init(
        sessionID: UUID,
        draft: RDPConnectionDraft,
        launchStore: SessionLaunchStore
    ) {
        self.sessionID = sessionID
        self.draft = draft
        self.launchStore = launchStore
        rememberPassword = draft.rememberPassword
        clipboard = SessionClipboard(isSharingEnabled: draft.clipboardSharingEnabled)
        audioPlaybackEnabled = draft.audioPlaybackEnabled
        super.init(nibName: nil, bundle: nil)
        clipboard.onToast = { [weak self] text, systemImage in
            self?.toast(text, systemImage: systemImage)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        configureLayout()
        configureHUDModel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        launchStore?.registerDiagnostics(diagnosticsModel, for: sessionID)
        startDiagnosticsLoop()
        startClipboardPollingLoop()
        if shouldAutoConnect {
            shouldAutoConnect = false
            resolveStoredCredentialsAndConnect()
        }
        render()
    }

    func closeSession() {
        guard didClose == false else {
            return
        }
        didClose = true
        diagnosticsTask?.cancel()
        clipboardPollingTask?.cancel()
        overlayVisibilityTask?.cancel()
        launchStore?.unregisterDiagnostics(for: sessionID)
        cancelConnection(shouldRecordCancellation: false)
    }

    deinit {
        MainActor.assumeIsolated {
            closeSession()
        }
    }

    // MARK: - Layout

    private func configureLayout() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        // The canvas starts below the titlebar (safe area) so pointer events
        // at the top edge reach the guest, while the glass strip behind the
        // transparent titlebar samples the desktop behind the window.
        titlebarBackdrop.material = .titlebar
        titlebarBackdrop.blendingMode = .behindWindow
        titlebarBackdrop.state = .followsWindowActiveState
        titlebarBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titlebarBackdrop)

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.onSurfaceSizeChange = { [weak self] size in
            self?.updateViewerSurfaceSize(size)
        }
        view.addSubview(canvasView)
        remoteDesktopRenderer.attach(canvasView.displayView)

        frameClockView.translatesAutoresizingMaskIntoConstraints = false
        frameClockView.isHidden = true
        view.addSubview(frameClockView)

        // Full-bleed hosts must not report an intrinsic size, or the window
        // shrinks to fit the overlay content on first layout.
        let overlayHost = NSHostingView(rootView: SessionOverlayRoot(model: hudModel))
        overlayHost.sizingOptions = []
        overlayHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayHost)
        self.overlayHost = overlayHost

        let toastHost = PassThroughHostingView(rootView: SessionToastRoot(model: hudModel))
        toastHost.sizingOptions = []
        toastHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toastHost)
        self.toastHost = toastHost

        let metricsHost = PassThroughHostingView(rootView: SessionMetricsRoot(model: hudModel))
        metricsHost.sizingOptions = []
        metricsHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metricsHost)
        self.metricsHost = metricsHost

        let bannerHost = NSHostingView(rootView: SessionBannerRoot(model: hudModel))
        bannerHost.translatesAutoresizingMaskIntoConstraints = false
        bannerHost.sizingOptions = .intrinsicContentSize
        view.addSubview(bannerHost)
        self.bannerHost = bannerHost

        NSLayoutConstraint.activate([
            titlebarBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titlebarBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titlebarBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            titlebarBackdrop.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            overlayHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayHost.topAnchor.constraint(equalTo: view.topAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toastHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toastHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toastHost.topAnchor.constraint(equalTo: view.topAnchor),
            toastHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            metricsHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metricsHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metricsHost.topAnchor.constraint(equalTo: view.topAnchor),
            metricsHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            bannerHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bannerHost.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),

            frameClockView.widthAnchor.constraint(equalToConstant: 1),
            frameClockView.heightAnchor.constraint(equalToConstant: 1),
            frameClockView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            frameClockView.topAnchor.constraint(equalTo: view.topAnchor),
        ])
    }

    private func configureHUDModel() {
        hudModel.deviceName = draft.displayName
        hudModel.hostLabel = draft.port == 3389 ? draft.host : "\(draft.host):\(draft.port)"
        hudModel.isClipboardSharingEnabled = clipboard.isSharingEnabled
        hudModel.isAudioPlaybackEnabled = audioPlaybackEnabled
        hudModel.isFollowWindowSizeEnabled = autoApplyViewerSize

        hudModel.onReconnect = { [weak self] in self?.startConnection() }
        hudModel.onCancel = { [weak self] in self?.cancelConnection() }
        hudModel.onClose = { [weak self] in self?.view.window?.close() }
        hudModel.onEditCredentials = { [weak self] in self?.promptForCredentials() }
        hudModel.onSubmitCredentials = { [weak self] username, domain, password, remember in
            self?.applyCredentials(username: username, domain: domain, password: password, remember: remember)
        }
        hudModel.onTrustCertificate = { [weak self] in self?.trustCurrentCertificate() }
        hudModel.onSyncClipboard = { [weak self] in self?.syncClipboardNow() }
        hudModel.onShareClipboardTemporarily = { [weak self] in self?.startTemporaryClipboardSharing() }
        hudModel.onSetClipboardSharing = { [weak self] enabled in
            self?.setClipboardSharing(enabled)
        }
        hudModel.onSetAudioPlayback = { [weak self] enabled in
            self?.setAudioPlayback(enabled)
        }
        hudModel.onSetFollowWindowSize = { [weak self] enabled in
            self?.setFollowWindowSize(enabled)
        }
        hudModel.onOpenDiagnostics = { [weak self] in self?.openDiagnosticsWindow() }
    }

    // MARK: - Rendering

    private func render() {
        let frame = previewFrame ?? report?.rdpGraphicsFirstFrame.map(RDPFrameMetadata.init)
        canvasView.update(
            frame: frame,
            hasPresentedFrame: hasPresentedFrame,
            inputSession: inputSession
        )

        let nextPhase = currentPhase
        if hudModel.phase != nextPhase {
            hudModel.phase = nextPhase
            updateOverlayVisibility(for: nextPhase)
        }
        hudModel.certificateNotice = certificateNoticeState()
        hudModel.metricsSummary = viewerMetricsSummary
        hudModel.isClipboardSharingEnabled = clipboard.isSharingEnabled
        hudModel.isAudioPlaybackEnabled = audioPlaybackEnabled
        hudModel.isFollowWindowSizeEnabled = autoApplyViewerSize
        hudModel.canSyncClipboard = clipboard.canSync
        hudModel.canShareClipboardTemporarily = clipboard.canStartTemporarySharing
        hudModel.temporaryClipboardSecondsRemaining = clipboard.temporarySharingSecondsRemaining
        hudModel.canReconnect = canStartConnection
        hudModel.canCancel = isConnecting || isResolvingStoredCredentials || isAutoRetryPending

        updateFrameClock()
        syncDiagnosticsSnapshot()
        publishSessionCommandStateIfKey()
    }

    /// Pushes this session's menu-relevant state to the launch store while
    /// its window is key, so the Session menu enables and titles its items
    /// from live state.
    func publishSessionCommandStateIfKey() {
        guard view.window?.isKeyWindow == true else {
            return
        }
        launchStore?.updateKeySessionCommands(sessionCommandState)
    }

    var sessionCommandState: SessionCommandState {
        SessionCommandState.make(
            isConnecting: isConnecting,
            isResolvingStoredCredentials: isResolvingStoredCredentials,
            isAutoRetryPending: isAutoRetryPending,
            hasFrame: previewFrame != nil,
            hasReport: report != nil,
            hasClipboardSession: clipboard.session != nil,
            clipboardSharingEnabled: clipboard.isSharingEnabled,
            isTemporaryClipboardSharingActive: clipboard.isTemporarySharingActive,
            hostIsEmpty: draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var currentPhase: SessionPhase {
        if isAwaitingCredentials {
            return .credentials
        }
        if isConnecting, hasPresentedFrame {
            return .active
        }
        if isConnecting || isResolvingStoredCredentials || isAutoRetryPending {
            return .connecting
        }
        if let sessionEndReason {
            return .ended(sessionEndReason)
        }
        return .connecting
    }

    /// Keeps the full-window overlay around long enough for its fade-out
    /// animation, then removes it from hit testing entirely.
    private func updateOverlayVisibility(for phase: SessionPhase) {
        overlayVisibilityTask?.cancel()
        guard phase.isActive else {
            overlayHost?.isHidden = false
            return
        }
        canvasView.makeInputFirstResponder()
        overlayVisibilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard Task.isCancelled == false, let self else {
                return
            }
            if self.hudModel.phase.isActive {
                self.overlayHost?.isHidden = true
            }
        }
    }

    private func certificateNoticeState() -> SessionCertificateNotice? {
        let canTrust = (liveCertificate?.sha256 ?? report?.certificateSHA256) != nil
        switch certificateRefusal {
        case .changed:
            return SessionCertificateNotice(
                title: "Certificate Changed",
                message: "Trust the new certificate only if you know why the server's certificate changed.",
                systemImage: "lock.trianglebadge.exclamationmark.fill",
                canTrust: canTrust,
                trustActionTitle: "Trust and Connect"
            )
        case .untrusted:
            let fingerprint = liveCertificate?.sha256.map { " SHA-256: \($0)" } ?? ""
            return SessionCertificateNotice(
                title: "Untrusted Certificate",
                message: "This Mac does not trust the server's certificate. Trust it only if you expect it, "
                    + "such as a server's self-signed certificate.\(fingerprint)",
                systemImage: "lock.trianglebadge.exclamationmark.fill",
                canTrust: canTrust,
                trustActionTitle: "Trust and Connect"
            )
        case nil:
            break
        }
        if certificateTrustedByApp {
            return nil
        }
        // The live callback fires at TLS time, so warnings surface while
        // connecting and during the session, not only at disconnect.
        if let warning = liveCertificate?.warnings.first ?? report?.warnings.first {
            return SessionCertificateNotice(
                title: "Certificate Warning",
                message: warning.message,
                systemImage: "lock.trianglebadge.exclamationmark.fill",
                canTrust: canTrust
            )
        }
        return nil
    }

    private func toast(_ text: String, systemImage: String) {
        hudModel.showToast(text, systemImage: systemImage)
    }

    fileprivate func acceptsConnectionEvent(id: UUID) -> Bool {
        activeConnectionID == id
    }

    fileprivate var isClosed: Bool {
        didClose
    }

    private func updateFrameClock() {
        frameClockView.configure(
            isEnabled: framePresentationClockEnabled,
            onFrame: { [weak self] displayLink in
                self?.displayLinkFrameArrived(displayLink)
            },
            onTimingChange: { [weak self] nextState in
                self?.updateFramePacing(nextState)
            }
        )
    }

    private func startDiagnosticsLoop() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                self?.syncDiagnosticsSnapshot()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func startClipboardPollingLoop() {
        clipboardPollingTask?.cancel()
        clipboardPollingTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard Task.isCancelled == false, let self else {
                    return
                }

                clipboard.poll()
                render()
            }
        }
    }

    private func openDiagnosticsWindow() {
        syncDiagnosticsSnapshot()
        launchStore?.openDiagnostics(for: sessionID)
    }

    private func syncDiagnosticsSnapshot() {
        let nextSnapshot = RemoteSessionDiagnosticsSnapshot(
            title: draft.displayName,
            report: report,
            previewFrame: previewFrame,
            previewFrameCount: previewFrameCount,
            previewDecodeError: previewDecodeError,
            renderMetrics: renderMetricsStore.metrics,
            framePacing: framePacing,
            sessionEndReason: sessionEndReason,
            serverCertificateInfo: liveCertificate,
            viewerPixelSize: viewerPixelSize,
            requestedDesktopSize: requestedDesktopSizeLabel,
            inputReady: inputSession != nil,
            displayControlReady: displayControlSession != nil,
            clipboardReady: clipboard.session != nil,
            clipboardSharingEnabled: clipboard.isSharingEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled,
            certificateTrustedByApp: certificateTrustedByApp,
            certificateTrustMessage: certificateTrustMessage,
            formError: nil,
            isConnecting: isConnecting
        )
        diagnosticsModel.updateSnapshot(nextSnapshot)
    }

    /// The user never picks a resolution: derive the initial remote desktop
    /// size from the viewer surface, falling back to the window's screen.
    private func initialDesktopSize() -> RDPDesktopSize {
        if let viewerPixelSize {
            let request = viewerPixelSize.displayRequest
            if let size = try? RDPDesktopSize(
                width: evenDesktopDimension(request.width, minimum: 640),
                height: evenDesktopDimension(request.height, minimum: 480)
            ) {
                return size
            }
        }

        let screen = view.window?.screen ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let surface = screen?.visibleFrame.size ?? CGSize(width: 1920, height: 1080)
        if let size = try? RDPDesktopSize(
            width: evenDesktopDimension(UInt32((surface.width * scale).rounded()), minimum: 640),
            height: evenDesktopDimension(UInt32((surface.height * scale).rounded()), minimum: 480)
        ) {
            return size
        }

        guard let fallback = try? RDPDesktopSize(width: 1920, height: 1080) else {
            preconditionFailure("1920x1080 is always a valid desktop size")
        }
        return fallback
    }

    private func evenDesktopDimension(_ value: UInt32, minimum: UInt16) -> UInt16 {
        let even = UInt16(clamping: value) & ~1
        return min(max(even, minimum), 8192)
    }

    // MARK: - Credentials prompt

    private func promptForCredentials(errorMessage: String? = nil) {
        hudModel.prefillUsername = draft.username
        hudModel.prefillDomain = draft.domain
        hudModel.prefillRememberPassword = rememberPassword
        hudModel.credentialsErrorMessage = errorMessage
        didPromptForCredentials = true
        isAwaitingCredentials = true
        render()
    }

    private func applyCredentials(username: String, domain: String, password: String, remember: Bool) {
        draft.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.password = password
        rememberPassword = remember
        draft.rememberPassword = remember
        if remember == false,
           password.isEmpty == false,
           let account = draft.identity.credentialAccountName
        {
            InMemoryCredentialCache.shared.setPassword(password, for: account)
        }
        isAwaitingCredentials = false
        hudModel.credentialsErrorMessage = nil
        startConnection()
    }

    // MARK: - Connection lifecycle

    /// A user-initiated (or post-credential) connection: resets the
    /// automatic retry budget before attempting.
    func startConnection() {
        autoRetryTask?.cancel()
        autoRetryTask = nil
        autoRetryCount = 0
        isAutoRetryPending = false
        hudModel.connectingStatusDetail = nil
        startConnectionAttempt()
    }

    /// Retries shortly after a transport-level failure. The first connection
    /// to a LAN host often fails while macOS shows the local-network
    /// permission dialog; a quiet retry papers over that race. Only failures
    /// that happened before TLS was established are retried, so credentials
    /// are never re-submitted automatically.
    private func scheduleAutoRetry() {
        autoRetryCount += 1
        isAutoRetryPending = true
        hudModel.connectingStatusDetail = "Network hiccup — retrying…"
        render()

        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard Task.isCancelled == false, let self, didClose == false else {
                return
            }
            isAutoRetryPending = false
            startConnectionAttempt()
        }
    }

    /// RDPKit's live-viewer mode has no deadline on post-TLS reads, so a
    /// stalled handshake would otherwise show "Connecting" forever. Cancel
    /// the attempt ourselves when no frame arrives in time, and lean on the
    /// auto-retry budget — this automates the manual disconnect/reconnect
    /// that recovers from the stall.
    private func startFirstFrameWatchdog() {
        firstFrameWatchdogTask?.cancel()
        let deadlineSeconds = UInt64(max(5, draft.timeoutSeconds) + 5)
        firstFrameWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: deadlineSeconds * 1_000_000_000)
            guard Task.isCancelled == false,
                  let self,
                  didClose == false,
                  isConnecting,
                  hasPresentedFrame == false
            else {
                return
            }
            cancelConnection(shouldRecordCancellation: false)
            if autoRetryCount < 2 {
                scheduleAutoRetry()
            } else {
                sessionEndReason = RDPSessionEndReason(
                    kind: .failed,
                    message: "Timed out waiting for the remote desktop."
                )
                render()
            }
        }
    }

    private func startConnectionAttempt() {
        isAwaitingCredentials = false
        isAutoRetryPending = false
        activeCancellation?.cancel()
        detachSessionChannels()
        activeConnectionID = nil
        activeCancellation = nil
        sessionEndReason = nil
        isConnecting = false

        report = nil
        liveCertificate = nil
        previewFrame = nil
        previewFrameCount = 0
        viewerMetricsSummary = nil
        previewDecodeError = nil
        resetFramePresentationState()
        renderMetricsStore.reset()
        certificateTrustedByApp = false
        certificateRefusal = nil
        certificateTrustMessage = nil

        let target: RDPConnectionTarget
        do {
            target = try RDPConnectionTarget(host: draft.host, portText: String(draft.port))
        } catch {
            sessionEndReason = RDPSessionEndReason(kind: .failed, message: String(describing: error))
            render()
            return
        }
        let requestedDesktopSize = initialDesktopSize()
        requestedDesktopSizeLabel = "\(requestedDesktopSize.width)x\(requestedDesktopSize.height)"

        let trimmedUsername = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = draft.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = RDPConnectionIdentity(
            host: target.host,
            port: target.port,
            username: trimmedUsername,
            domain: trimmedDomain
        )
        let credentialKey = KeychainCredentialKey(identity: identity)
        let clientLicenseKey = ClientLicenseStoreKey(identity: identity)
        let credentials: RDPCredentials?
        do {
            credentials = try RDPCredentials.validated(
                username: trimmedUsername,
                domain: trimmedDomain,
                password: draft.password
            )
        } catch {
            sessionEndReason = RDPSessionEndReason(kind: .failed, message: String(describing: error))
            render()
            return
        }
        let credentialPersistenceRequest = credentialPersistenceRequest(
            key: credentialKey,
            password: draft.password,
            hasCredentials: credentials != nil
        )

        // Announce the Mac's keyboard layout so the server maps scancodes to
        // the characters the keys are labelled with; the input layer sends
        // keys by the layout this session announced.
        let keyboardLayout = MacRDPKeyboardLayout.current()
        canvasView.keyboardLayout = keyboardLayout
        let baseConfiguration = RDPConnectionConfiguration(
            target: target,
            credentials: credentials,
            timeoutSeconds: draft.timeoutSeconds,
            hideCertificateWarnings: draft.hideCertificateWarnings,
            graphicsFrameCaptureLimit: nil,
            desktopSize: requestedDesktopSize,
            clipboardEnabled: clipboard.isSharingEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled,
            // RDPeek never exposes a graphics-profile picker: automatic lets
            // RDPKit negotiate the best path per host (Windows included).
            graphicsCapabilityProfile: .automatic,
            keyboardLayout: keyboardLayout
        )

        let connectionID = UUID()
        let cancellation = RDPConnectionCancellation()
        let connectionStartedAt = Date()
        activeConnectionID = connectionID
        activeCancellation = cancellation
        renderMetricsStore.reset(connectionStartedAt: connectionStartedAt)
        updateViewerMetricsSummary(renderMetricsStore.metrics)
        audioMessage = nil
        isConnecting = true
        launchStore?.recordConnectionStart(for: draft.deviceID)
        render()
        startFirstFrameWatchdog()

        let sink = SessionMainActorSink(controller: self, connectionID: connectionID)
        let credentialStore = credentialStore
        let clientLicenseStore = clientLicenseStore
        let trustedCertificateStore = trustedCertificateStore
        let acceptsUntrustedCertificates = draft.hideCertificateWarnings
        // RDPSessionClient.run blocks for the whole session and waits on the
        // decode queue, so it gets its own thread rather than pinning a Swift
        // concurrency worker per session, which could starve the decode drain.
        let sessionThread = Thread {
            var configuration = baseConfiguration
            configuration.storedClientLicense = try? clientLicenseStore.license(for: clientLicenseKey)
            var keyframeRequests = RDPKeyframeRequestThrottle()
            let decodeQueue = RDPFrameDecodeQueue(
                shouldCancel: {
                    cancellation.isCancelled
                },
                onDecoded: { presentation, receivedAt, decodedAt, timing in
                    sink.apply { controller in
                        controller.previewDecodeError = nil
                        let shouldForceMetricsSnapshot = !controller.hasPresentedFrame
                        controller.renderMetricsStore.recordDecodedFrame(
                            presentation.frame,
                            receivedAt: receivedAt,
                            decodedAt: decodedAt,
                            timing: timing
                        )
                        let metricsChanged = controller.publishRenderMetricsSnapshotIfNeeded(
                            force: shouldForceMetricsSnapshot,
                            at: decodedAt
                        )
                        let presentationChanged = controller.presentDecodedFrame(presentation)
                        if metricsChanged || presentationChanged {
                            controller.render()
                        }
                    }
                },
                onDecodeFailed: { receivedAt, errorDescription in
                    sink.apply { controller in
                        controller.previewDecodeError = errorDescription
                        controller.renderMetricsStore.recordDecodeFailure(
                            receivedAt: receivedAt,
                            errorDescription: errorDescription
                        )
                        controller.publishRenderMetricsSnapshotIfNeeded(at: receivedAt)
                        controller.render()
                    }
                }
            )
            let wireReceiveCoalescer = RDPWireReceiveMetricsCoalescer(
                shouldCancel: {
                    cancellation.isCancelled
                },
                onFlush: { sample in
                    sink.apply { controller in
                        controller.renderMetricsStore.recordWireReceive(sample)
                        if controller.publishRenderMetricsSnapshotIfNeeded(at: sample.receivedAt) {
                            controller.render()
                        }
                    }
                }
            )
            defer {
                wireReceiveCoalescer.flush()
                wireReceiveCoalescer.cancel()
                decodeQueue.cancel()
            }
            let nextReport = RDPSessionClient().run(
                configuration: configuration,
                onGraphicsFrame: { frame in
                    let completion = decodeQueue.submitAndWait(
                        frame,
                        receivedAt: Date(),
                        shouldContinue: {
                            cancellation.isCancelled == false
                        }
                    )
                    if frame.contentKind == .video, completion == .decoded {
                        keyframeRequests.recordDecodedVideo()
                    }
                    // An update that fails to decode leaves stale pixels, not
                    // a broken session. Failed video waits for a keyframe,
                    // which the server is asked for.
                    if case .failed = completion {
                        if frame.contentKind == .video, keyframeRequests.shouldRequest(at: Date()) {
                            sink.apply { controller in
                                controller.requestKeyframe(desktopSize: requestedDesktopSize)
                            }
                        }
                        return
                    }
                    try completion.requireDecoded()
                },
                onInputReady: { session in
                    // Keychain writes can block on the access-approval
                    // dialog; keep them off the connection thread so the
                    // graphics handshake (and the first-frame watchdog)
                    // are not held up behind them.
                    if let credentialPersistenceRequest {
                        Task.detached(priority: .utility) {
                            let persistenceResult = persistCredentialsIfNeeded(
                                credentialPersistenceRequest,
                                store: credentialStore
                            )
                            if let persistenceResult {
                                // The write may finish after the connection
                                // ended (keychain approval dialog); its
                                // outcome is not connection-scoped, so do
                                // not drop it with the stale-event gate.
                                // Carry the identity the entry was stored
                                // under — the draft can be re-signed-in
                                // with different credentials by then.
                                let identity = credentialPersistenceRequest.key.identity
                                sink.applyIgnoringConnectionState { controller in
                                    controller.applyCredentialPersistenceResult(
                                        persistenceResult,
                                        identity: identity
                                    )
                                }
                            }
                        }
                    }
                    sink.apply { controller in
                        controller.inputSession = session
                        controller.render()
                    }
                },
                onDisplayControlReady: { session in
                    sink.apply { controller in
                        controller.displayControlSession = session
                        // A server redirection's target has not been sent
                        // the layout the first server got.
                        controller.lastRequestedDisplayRequest = nil
                        controller.scheduleAutoDisplaySizeUpdate()
                        controller.render()
                    }
                },
                onClipboardReady: { session in
                    sink.apply { controller in
                        controller.clipboard.attach(session)
                        controller.render()
                    }
                },
                onClipboardText: { text in
                    sink.apply { controller in
                        controller.clipboard.receiveText(text)
                        controller.render()
                    }
                },
                onClipboardFileGroupDescriptor: { descriptorList in
                    sink.apply { controller in
                        controller.clipboard.receiveFileList(descriptorList)
                        controller.render()
                    }
                },
                onClipboardFileContents: { response in
                    sink.apply { controller in
                        controller.clipboard.receiveFileContents(response)
                        controller.render()
                    }
                },
                onAudioSample: { sample in
                    sink.apply { controller in
                        guard controller.audioPlaybackEnabled else {
                            return
                        }
                        do {
                            let queued = try controller.remoteAudioPlayer.enqueue(sample)
                            controller.updateAudioMessage(queued ? nil : "Dropping delayed audio")
                        } catch {
                            controller.updateAudioMessage(String(describing: error))
                        }
                    }
                },
                onCertificate: { info in
                    // Runs before any credential is sent, so cancelling here
                    // refuses the server without signing in to it.
                    let refusal = trustedCertificateStore.refusal(
                        of: info,
                        port: target.port,
                        acceptsUntrusted: acceptsUntrustedCertificates
                    )
                    if refusal != nil {
                        cancellation.cancel()
                    }
                    sink.apply { controller in
                        controller.liveCertificate = info
                        // After a server redirection, the certificate belongs
                        // to the redirection target.
                        controller.certificateTrustedByApp = controller.trustedCertificateStore.isTrusted(
                            host: info.host,
                            port: target.port,
                            sha256: info.sha256
                        )
                        if let refusal {
                            controller.refuseCertificate(refusal)
                        }
                        controller.render()
                    }
                },
                onWireReceive: { sample in
                    wireReceiveCoalescer.record(sample)
                },
                cancellation: cancellation
            )
            let finalWireReceiveSample = wireReceiveCoalescer.takePendingSample()
            // License persistence is not connection-scoped. Save an issued
            // license even when closing the window cancelled the session, so
            // the next connection can present it to the server.
            persistClientLicenseIfNeeded(
                nextReport.rdpIssuedClientLicense,
                key: clientLicenseKey,
                store: clientLicenseStore
            )
            guard cancellation.isCancelled == false else {
                return
            }
            let firstFrameDecodeResult = nextReport.rdpGraphicsFirstFrame.map(decodeReportFirstFrame)
            sink.apply { controller in
                if let finalWireReceiveSample {
                    controller.renderMetricsStore.recordWireReceive(finalWireReceiveSample)
                }
                controller.flushPendingFramePresentation()
                controller.publishRenderMetricsSnapshotIfNeeded(force: true)
                controller.report = nextReport
                controller.sessionEndReason = RDPSessionEndReason(report: nextReport)
                controller.certificateTrustedByApp = controller.trustedCertificateStore.isTrusted(
                    host: controller.liveCertificate?.host ?? target.host,
                    port: target.port,
                    sha256: nextReport.certificateSHA256
                )
                if controller.previewFrame == nil {
                    controller.previewFrame = nextReport.rdpGraphicsFirstFrame.map(RDPFrameMetadata.init)
                }
                if controller.hasPresentedFrame == false,
                   let firstFrameDecodeResult
                {
                    switch firstFrameDecodeResult {
                    case let .decoded(presentation, receivedAt, decodedAt, timing):
                        controller.renderMetricsStore.recordDecodedFrame(
                            presentation.frame,
                            receivedAt: receivedAt,
                            decodedAt: decodedAt,
                            timing: timing
                        )
                        controller.publishRenderMetricsSnapshotIfNeeded(force: true, at: decodedAt)
                        controller.applyFramePresentation(presentation)
                    case let .failed(receivedAt, errorDescription):
                        controller.previewDecodeError = errorDescription
                        controller.renderMetricsStore.recordDecodeFailure(
                            receivedAt: receivedAt,
                            errorDescription: errorDescription
                        )
                        controller.publishRenderMetricsSnapshotIfNeeded(force: true, at: receivedAt)
                    }
                }
                controller.isConnecting = false
                controller.activeConnectionID = nil
                controller.activeCancellation = nil
                // The channel is closed once the run loop returns; drop the
                // session objects so clipboard sync/polling and the input
                // wiring can't keep talking to a dead channel.
                controller.detachSessionChannels()
                controller.firstFrameWatchdogTask?.cancel()
                // Retry transport failures (no negotiation response ever
                // arrived) and pre-frame stalls. Some servers give no
                // explicit bad-credential signal — rejected credentials
                // surface as a timeout, which the retry budget bounds.
                if let reason = controller.sessionEndReason,
                   reason.kind == .failed,
                   controller.hasPresentedFrame == false,
                   controller.autoRetryCount < 2,
                   nextReport.responseHex == nil
                   || nextReport.error?.contains("RDP Graphics Update") == true
                {
                    controller.scheduleAutoRetry()
                }
                controller.render()
            }
        }
        sessionThread.name = "RDPeek session"
        sessionThread.qualityOfService = .userInitiated
        sessionThread.start()
    }

    func cancelConnection(shouldRecordCancellation: Bool = true) {
        let shouldRecordCancellation = shouldRecordCancellation
            && (isConnecting || activeConnectionID != nil
                || isResolvingStoredCredentials || isAutoRetryPending)
        autoRetryTask?.cancel()
        autoRetryTask = nil
        firstFrameWatchdogTask?.cancel()
        isAutoRetryPending = false
        isResolvingStoredCredentials = false
        hudModel.connectingStatusDetail = nil
        activeCancellation?.cancel()
        detachSessionChannels()
        resetFramePresentationState()
        activeCancellation = nil
        activeConnectionID = nil
        isConnecting = false
        if shouldRecordCancellation {
            // Cancelling a connect that never showed a frame, when the
            // password came from the sign-in overlay, returns to sign-in:
            // a Disconnected screen offering Reconnect implies a session
            // that never existed.
            if hasEverPresentedFrame == false, didPromptForCredentials {
                promptForCredentials()
                return
            }
            sessionEndReason = .cancelled
        }
        render()
    }

    /// Ends a connection whose certificate must not receive credentials;
    /// the certificate notice offers to trust it and connect again.
    private func refuseCertificate(_ refusal: CertificateRefusal) {
        certificateRefusal = refusal
        let reason = switch refusal {
        case .changed: "The server's certificate is not the one trusted for this host."
        case .untrusted: "Neither this Mac nor RDPeek trusts the server's certificate."
        }
        sessionEndReason = RDPSessionEndReason(
            kind: .failed,
            message: reason + " The connection was closed before any credential was sent."
        )
        cancelConnection(shouldRecordCancellation: false)
    }

    /// Drops what a session handed out, so nothing more is sent to it once
    /// it has ended — however it ended.
    private func detachSessionChannels() {
        cancelPendingDisplayResize(resetLastRequestedSize: true)
        inputSession = nil
        displayControlSession = nil
        clipboard.detach()
        remoteAudioPlayer.reset()
        audioMessage = nil
    }

    // MARK: - Frame presentation

    @discardableResult
    private func presentDecodedFrame(_ presentation: RDPDecodedFramePresentation) -> Bool {
        guard hasPresentedFrame else {
            return applyFramePresentation(presentation)
        }

        guard framePacing.hasDisplayLink else {
            return applyFramePresentation(presentation)
        }

        if framePresentationBuffer.replacePendingPresentation(presentation) {
            let skippedAt = Date()
            renderMetricsStore.recordSkippedPresentationFrame(at: skippedAt)
            return publishRenderMetricsSnapshotIfNeeded(at: skippedAt)
        }
        return false
    }

    private var framePresentationClockEnabled: Bool {
        isConnecting && hasPresentedFrame
    }

    private func displayLinkFrameArrived(_ displayLink: CADisplayLink) {
        let nextFramePacing = framePacing.updatingDisplayLinkDuration(displayLink.duration)
        let pacingChanged = updateFramePacing(nextFramePacing, shouldRender: false)
        let presentationChanged = flushPendingFramePresentation()
        if pacingChanged || presentationChanged {
            render()
        }
    }

    @discardableResult
    private func updateFramePacing(
        _ nextState: RDPFramePacingState,
        shouldRender: Bool = true
    ) -> Bool {
        let currentBackingScaleFactor = framePacing.backingScaleFactor
        guard framePacing != nextState else {
            return false
        }

        framePacing = nextState
        updateViewerMetricsSummary(renderMetricsStore.metrics)
        if currentBackingScaleFactor != nextState.backingScaleFactor {
            refreshViewerPixelSize()
        }
        if shouldRender {
            render()
        }
        return true
    }

    @discardableResult
    private func flushPendingFramePresentation() -> Bool {
        guard let pendingFramePresentation = framePresentationBuffer.takePendingPresentation() else {
            return false
        }
        return applyFramePresentation(pendingFramePresentation)
    }

    @discardableResult
    private func applyFramePresentation(_ presentation: RDPDecodedFramePresentation) -> Bool {
        let wasFirstPresentedFrame = hasPresentedFrame == false
        let shouldUpdateFrameMetadata = shouldPublishFrameMetadata(presentation.frame)
        remoteDesktopRenderer.present(presentation, id: renderMetricsStore.metrics.decodedFrameCount)
        if shouldUpdateFrameMetadata {
            previewFrame = RDPFrameMetadata(presentation.frame)
        }
        if wasFirstPresentedFrame {
            hasPresentedFrame = true
            hasEverPresentedFrame = true
            autoRetryCount = 0
            firstFrameWatchdogTask?.cancel()
            hudModel.connectingStatusDetail = nil
        }
        return wasFirstPresentedFrame || shouldUpdateFrameMetadata
    }

    private func shouldPublishFrameMetadata(_ frame: RDPGraphicsFrameSnapshot) -> Bool {
        guard let currentFrame = previewFrame else {
            return true
        }
        return currentFrame.width != frame.width
            || currentFrame.height != frame.height
            || currentFrame.codecName != frame.codecName
            || currentFrame.videoCodec != frame.videoCodec
    }

    @discardableResult
    private func publishRenderMetricsSnapshotIfNeeded(
        force: Bool = false,
        at timestamp: Date = Date()
    ) -> Bool {
        guard let snapshot = renderMetricsStore.snapshotIfNeeded(force: force, at: timestamp) else {
            return false
        }
        var didChange = false
        if previewFrameCount != snapshot.decodedFrameCount {
            previewFrameCount = snapshot.decodedFrameCount
            didChange = true
        }
        didChange = updateViewerMetricsSummary(snapshot) || didChange
        return didChange
    }

    @discardableResult
    private func updateViewerMetricsSummary(_ metrics: RDPRenderMetrics) -> Bool {
        let nextSummary = compactViewerMetricsSummary(metrics: metrics, framePacing: framePacing)
        if viewerMetricsSummary != nextSummary {
            viewerMetricsSummary = nextSummary
            return true
        }
        return false
    }

    private func resetFramePresentationState() {
        framePresentationBuffer.clear()
        hasPresentedFrame = false
        remoteDesktopRenderer.clear()
    }

    // MARK: - Display control

    private func updateViewerSurfaceSize(_ pointSize: CGSize) {
        guard pointSize.width > 0, pointSize.height > 0 else {
            return
        }
        viewerPointSize = pointSize
        refreshViewerPixelSize()
        render()
    }

    private func refreshViewerPixelSize() {
        guard viewerPointSize.width > 0, viewerPointSize.height > 0 else {
            return
        }
        let scale = framePacing.backingScaleFactor
            ?? view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        let nextSize = RDPViewerPixelSize(pointSize: viewerPointSize, backingScaleFactor: scale)
        if viewerPixelSize != nextSize {
            viewerPixelSize = nextSize
            scheduleAutoDisplaySizeUpdate()
        }
    }

    private func scheduleAutoDisplaySizeUpdate() {
        guard autoApplyViewerSize,
              isConnecting,
              displayControlSession != nil,
              let viewerPixelSize
        else {
            return
        }

        let displayRequest = viewerPixelSize.displayRequest
        guard lastRequestedDisplayRequest != displayRequest else {
            return
        }

        pendingDisplayResizeTask?.cancel()
        pendingDisplayResizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else {
                return
            }
            self?.applyAutoDisplayRequest(displayRequest)
        }
    }

    private func applyAutoDisplayRequest(_ displayRequest: RDPDisplayRequest) {
        pendingDisplayResizeTask = nil
        guard autoApplyViewerSize,
              isConnecting,
              displayControlSession != nil,
              lastRequestedDisplayRequest != displayRequest
        else {
            return
        }

        applyDisplayRequestToActiveSession(displayRequest)
    }

    private func applyDisplayRequestToActiveSession(_ request: RDPDisplayRequest) {
        guard let displayControlSession else {
            return
        }

        displayControlSession.send(request)
        lastRequestedDisplayRequest = request
        requestedDesktopSizeLabel = request.label
        render()
    }

    /// Windows and gnome-remote-desktop send no keyframe by themselves, but
    /// answer the monitor layout sent again with one.
    private func requestKeyframe(desktopSize: RDPDesktopSize) {
        guard let displayControlSession else {
            return
        }
        let backingScaleFactor = viewerPixelSize?.backingScaleFactor
            ?? framePacing.backingScaleFactor
            ?? view.window?.backingScaleFactor
            ?? 1
        let request = lastRequestedDisplayRequest ?? RDPDisplayRequest(
            width: UInt32(desktopSize.width),
            height: UInt32(desktopSize.height),
            scaleFactors: RDPDisplayScaleFactors(backingScaleFactor: backingScaleFactor)
        )
        displayControlSession.send(request)
    }

    private func cancelPendingDisplayResize(resetLastRequestedSize: Bool = false) {
        pendingDisplayResizeTask?.cancel()
        pendingDisplayResizeTask = nil
        if resetLastRequestedSize {
            lastRequestedDisplayRequest = nil
        }
    }

    private func setFollowWindowSize(_ enabled: Bool) {
        autoApplyViewerSize = enabled
        if enabled {
            scheduleAutoDisplaySizeUpdate()
        } else {
            cancelPendingDisplayResize()
        }
        render()
    }

    // MARK: - Clipboard

    func syncClipboardNow() {
        clipboard.syncNow()
        render()
    }

    func startTemporaryClipboardSharing() {
        clipboard.startTemporarySharing()
        render()
    }

    private func setClipboardSharing(_ enabled: Bool) {
        clipboard.setSharingEnabled(enabled)
        render()
    }

    /// Surfaces remote audio problems once per change, so a silent session
    /// explains itself instead of just not playing sound.
    private func updateAudioMessage(_ message: String?) {
        guard audioMessage != message else {
            return
        }
        audioMessage = message
        if let message {
            toast("Audio: \(message)", systemImage: "speaker.slash")
        }
    }

    private func setAudioPlayback(_ enabled: Bool) {
        audioPlaybackEnabled = enabled
        if !enabled {
            remoteAudioPlayer.reset()
        } else if isConnecting, report == nil, draft.audioPlaybackEnabled == false {
            toast("Audio starts on the next connection", systemImage: "speaker.wave.2")
        }
        render()
    }

    // MARK: - Certificate trust

    private func trustCurrentCertificate() {
        guard let key = currentCertificateTrustKey() else {
            toast("No certificate fingerprint available", systemImage: "exclamationmark.triangle")
            return
        }
        trustedCertificateStore.trust(key)
        // A connection refused for this certificate connects again now that
        // it is trusted.
        guard certificateRefusal == nil else {
            startConnection()
            return
        }
        certificateTrustedByApp = true
        certificateTrustMessage = "Certificate trusted for this host."
        toast("Certificate trusted for this host", systemImage: "checkmark.shield.fill")
        render()
    }

    private func currentCertificateTrustKey() -> RDPServerCertificateTrustKey? {
        guard let certificateSHA256 = liveCertificate?.sha256 ?? report?.certificateSHA256,
              let target = try? RDPConnectionTarget(host: draft.host, portText: String(draft.port))
        else {
            return nil
        }
        return RDPServerCertificateTrustKey(
            host: liveCertificate?.host ?? target.host,
            port: target.port,
            sha256: certificateSHA256
        )
    }

    // MARK: - Credentials

    /// Resolves the password (Keychain, then the in-memory cache) without
    /// blocking the main thread, then connects or asks the user to sign in.
    /// The Keychain read can block on the access-approval dialog, so it runs
    /// off the main actor while the connecting overlay is up.
    private func resolveStoredCredentialsAndConnect() {
        guard draft.password.isEmpty else {
            hasRememberedPassword = rememberPassword
            startConnection()
            return
        }

        guard let key = KeychainCredentialKey(
            host: draft.host,
            portText: String(draft.port),
            username: draft.username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: draft.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            promptForCredentials()
            return
        }

        isResolvingStoredCredentials = true
        render()
        let store = credentialStore
        Task { @MainActor [weak self] in
            let savedPassword = await Task.detached(priority: .userInitiated) {
                try? store.password(for: key)
            }.value

            guard let self, didClose == false, isResolvingStoredCredentials else {
                return
            }
            isResolvingStoredCredentials = false

            if let savedPassword, savedPassword.isEmpty == false {
                hasRememberedPassword = true
                rememberPassword = true
                draft.password = savedPassword
                startConnection()
                return
            }

            hasRememberedPassword = false
            if let account = draft.identity.credentialAccountName,
               let cachedPassword = InMemoryCredentialCache.shared.password(for: account)
            {
                draft.password = cachedPassword
                startConnection()
                return
            }

            promptForCredentials()
        }
    }

    private func credentialPersistenceRequest(
        key: KeychainCredentialKey?,
        password: String,
        hasCredentials: Bool
    ) -> CredentialPersistenceRequest? {
        guard hasCredentials,
              let key
        else {
            return nil
        }

        if rememberPassword {
            return .save(key: key, password: password)
        }
        if hasRememberedPassword {
            return .delete(key: key)
        }
        return nil
    }

    private func applyCredentialPersistenceResult(
        _ result: Result<CredentialPersistenceResult, Error>,
        identity: RDPConnectionIdentity
    ) {
        // A delayed write can land after the user re-signed in with
        // different credentials; only mirror it on session state when it
        // matches what the session is now using.
        let matchesCurrentDraft = draft.identity.hasSameConnectionIdentity(as: identity)
        switch result {
        case .success(.saved):
            if matchesCurrentDraft {
                hasRememberedPassword = true
                rememberPassword = true
            }
            // Reflect the save on the device profile, or the editor keeps
            // showing remember-off and later renames orphan the entry.
            launchStore?.recordCredentialPersistence(
                for: draft.deviceID,
                identity: identity,
                remembered: true
            )
        case .success(.deleted):
            if matchesCurrentDraft {
                hasRememberedPassword = false
            }
            launchStore?.recordCredentialPersistence(
                for: draft.deviceID,
                identity: identity,
                remembered: false
            )
        case .failure:
            break
        }
    }

    private var canStartConnection: Bool {
        !isConnecting && draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

// MARK: - Menu command surface

@MainActor
protocol RDPSessionCommandHandling: AnyObject {
    var rdpStartSessionTitle: String { get }
    var rdpCanStartSession: Bool { get }
    var rdpCanCancelSession: Bool { get }
    var rdpCanSyncClipboard: Bool { get }
    var rdpCanStartTemporaryClipboardSharing: Bool { get }

    func rdpStartSession()
    func rdpCancelSession()
    func rdpOpenDiagnostics()
    func rdpSyncClipboard()
    func rdpStartTemporaryClipboardSharing()
}

extension SessionViewController: RDPSessionCommandHandling {
    var rdpStartSessionTitle: String {
        sessionCommandState.startTitle
    }

    var rdpCanStartSession: Bool {
        sessionCommandState.canStart
    }

    var rdpCanCancelSession: Bool {
        sessionCommandState.canCancel
    }

    var rdpCanSyncClipboard: Bool {
        sessionCommandState.canSyncClipboard
    }

    var rdpCanStartTemporaryClipboardSharing: Bool {
        sessionCommandState.canShareClipboardTemporarily
    }

    func rdpStartSession() {
        startConnection()
    }

    func rdpCancelSession() {
        cancelConnection()
    }

    func rdpOpenDiagnostics() {
        openDiagnosticsWindow()
    }

    func rdpSyncClipboard() {
        syncClipboardNow()
    }

    func rdpStartTemporaryClipboardSharing() {
        startTemporaryClipboardSharing()
    }
}

// MARK: - Support types

private final class SessionMainActorSink: @unchecked Sendable {
    weak var controller: SessionViewController?
    let connectionID: UUID

    init(controller: SessionViewController, connectionID: UUID) {
        self.controller = controller
        self.connectionID = connectionID
    }

    /// Runs `operation` on the main queue in submission order, so frames
    /// and audio stay ordered. The block keeps the sink alive: the session
    /// thread releases it right after submitting the final update. The sink
    /// holds the controller weakly, so this forms no cycle.
    func apply(_ operation: @escaping @MainActor (SessionViewController) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let controller = self.controller,
                      controller.acceptsConnectionEvent(id: self.connectionID)
                else {
                    return
                }
                operation(controller)
            }
        }
    }

    /// Applies even after the connection has ended — for outcomes that are
    /// not connection-scoped, like a keychain write that finished after the
    /// session dropped and must still be reflected in tracked state.
    func applyIgnoringConnectionState(_ operation: @escaping @MainActor (SessionViewController) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let controller = self.controller,
                      controller.isClosed == false
                else {
                    return
                }
                operation(controller)
            }
        }
    }
}

func compactViewerMetricsSummary(
    metrics: RDPRenderMetrics,
    framePacing: RDPFramePacingState
) -> String? {
    var parts: [String] = []
    let framesPerSecond = metrics.rollingFramesPerSecond ?? metrics.averageFramesPerSecond
    if let framesPerSecond {
        parts.append(String(format: "%.1f fps", framesPerSecond))
    }
    if let lastDecodeMilliseconds = metrics.lastDecodeMilliseconds {
        parts.append(String(format: "decode %.1f ms", lastDecodeMilliseconds))
    }
    if let wireMegabitsPerSecond = metrics.rollingWireMegabitsPerSecond {
        parts.append(String(format: "rx %.1f Mbps", wireMegabitsPerSecond))
    }
    if let displayLinkFramesPerSecond = framePacing.displayLinkFramesPerSecond {
        parts.append(String(format: "%.0f Hz", displayLinkFramesPerSecond))
    }
    guard parts.isEmpty == false else {
        return nil
    }
    return parts.joined(separator: "  ·  ")
}
