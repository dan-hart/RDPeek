import Foundation
import XCTest

final class SessionCommandStateTests: XCTestCase {
    // MARK: - Phase table

    func testIdleBeforeFirstAttemptOffersConnect() {
        let state = makeState()
        XCTAssertEqual(state.startTitle, "Connect")
        XCTAssertTrue(state.canStart)
        XCTAssertFalse(state.canCancel)
    }

    func testEndedSessionOffersReconnect() {
        let state = makeState(hasReport: true)
        XCTAssertEqual(state.startTitle, "Reconnect")
        XCTAssertTrue(state.canStart)
        XCTAssertFalse(state.canCancel)
    }

    func testResolvingStoredCredentialsIsCancelableButNotStartable() {
        // The v1.0.1 regression: during the async keychain resolution the
        // menu offered Connect (double-starting) and no Cancel (no way out).
        let state = makeState(isResolvingStoredCredentials: true)
        XCTAssertFalse(state.canStart)
        XCTAssertTrue(state.canCancel)
    }

    func testAutoRetryWaitIsCancelableButNotStartable() {
        let state = makeState(isAutoRetryPending: true, hasReport: true)
        XCTAssertFalse(state.canStart)
        XCTAssertTrue(state.canCancel)
    }

    func testConnectingWithoutFrameShowsConnecting() {
        let state = makeState(isConnecting: true)
        XCTAssertEqual(state.startTitle, "Connecting")
        XCTAssertFalse(state.canStart)
        XCTAssertTrue(state.canCancel)
    }

    func testActiveSessionShowsConnected() {
        let state = makeState(isConnecting: true, hasFrame: true)
        XCTAssertEqual(state.startTitle, "Connected")
        XCTAssertFalse(state.canStart)
        XCTAssertTrue(state.canCancel)
    }

    func testSignInPromptIsNeitherStartableNorCancelable() {
        // Reconnect while the sign-in overlay waits would connect without
        // the credentials it asks for; the overlay's own Connect and Cancel
        // are the way out.
        let state = makeState(isAwaitingCredentials: true, hasReport: true)
        XCTAssertEqual(state.startTitle, "Reconnect")
        XCTAssertFalse(state.canStart)
        XCTAssertFalse(state.canCancel)
    }

    func testIdleWithEmptyHostCannotStartOrCancel() {
        let state = makeState(hostIsEmpty: true)
        XCTAssertFalse(state.canStart)
        XCTAssertFalse(state.canCancel)
    }

    // MARK: - Invariant

    func testEveryPhaseOffersAWayForward() {
        // The user must never be stuck with both Connect and Cancel disabled
        // unless the session is idle and has no host to connect to, or the
        // sign-in overlay offers its own way forward.
        for mask in 0 ..< (1 << 6) {
            let isConnecting = mask & 1 != 0
            let isResolving = mask & 2 != 0
            let isAutoRetryPending = mask & 4 != 0
            let isAwaitingCredentials = mask & 8 != 0
            let hostIsEmpty = mask & 16 != 0
            let state = SessionCommandState.make(
                isConnecting: isConnecting,
                isResolvingStoredCredentials: isResolving,
                isAutoRetryPending: isAutoRetryPending,
                isAwaitingCredentials: isAwaitingCredentials,
                hasFrame: mask & 32 != 0,
                hasReport: false,
                hostIsEmpty: hostIsEmpty,
                canSyncClipboard: false,
                canShareClipboardTemporarily: false
            )
            let isIdle = !isConnecting && !isResolving && !isAutoRetryPending
            XCTAssertTrue(
                state.canStart || state.canCancel || (isIdle && (hostIsEmpty || isAwaitingCredentials)),
                "Dead-end command state for input mask \(mask)"
            )
        }
    }

    // MARK: - Helpers

    private func makeState(
        isConnecting: Bool = false,
        isResolvingStoredCredentials: Bool = false,
        isAutoRetryPending: Bool = false,
        isAwaitingCredentials: Bool = false,
        hasFrame: Bool = false,
        hasReport: Bool = false,
        hostIsEmpty: Bool = false
    ) -> SessionCommandState {
        SessionCommandState.make(
            isConnecting: isConnecting,
            isResolvingStoredCredentials: isResolvingStoredCredentials,
            isAutoRetryPending: isAutoRetryPending,
            isAwaitingCredentials: isAwaitingCredentials,
            hasFrame: hasFrame,
            hasReport: hasReport,
            hostIsEmpty: hostIsEmpty,
            canSyncClipboard: false,
            canShareClipboardTemporarily: false
        )
    }
}
