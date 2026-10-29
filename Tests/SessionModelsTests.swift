import RDPKit
import XCTest

final class SessionModelsTests: XCTestCase {
    // MARK: - Following the saved PC

    func testAnUnchangedPCLeavesTheDraftAsTheSessionMadeIt() {
        let saved = makeDraft()
        var draft = saved
        // Signed in at the sign-in sheet as someone else.
        draft.username = "bob"
        draft.password = "secret"
        draft.rememberPassword = true

        XCTAssertEqual(draft.following(saved, previouslySaved: saved), draft)
    }

    func testSettingsChangedInTheEditorFollowAndKeepThePassword() {
        let previous = makeDraft()
        var saved = previous
        saved.name = "Office"
        saved.hideCertificateWarnings = false
        saved.timeoutSeconds = 30
        var draft = previous
        draft.password = "secret"

        let next = draft.following(saved, previouslySaved: previous)

        XCTAssertEqual(next.name, "Office")
        XCTAssertFalse(next.hideCertificateWarnings)
        XCTAssertEqual(next.timeoutSeconds, 30)
        XCTAssertEqual(next.password, "secret")
    }

    func testANewHostDropsThePassword() {
        let previous = makeDraft()
        var saved = previous
        saved.host = "10.0.0.6"
        var draft = previous
        draft.password = "secret"

        let next = draft.following(saved, previouslySaved: previous)

        XCTAssertEqual(next.host, "10.0.0.6")
        XCTAssertEqual(next.password, "")
    }

    func testAHostChangedOnlyInCaseKeepsThePassword() {
        let previous = makeDraft()
        var saved = previous
        saved.host = "WINBOX"
        var draft = previous
        draft.password = "secret"

        XCTAssertEqual(draft.following(saved, previouslySaved: previous).password, "secret")
    }

    func testOnlyChangedSettingsReplaceWhatTheSessionTyped() {
        let previous = makeDraft()
        var draft = previous
        draft.username = "bob"
        draft.password = "secret"

        var renamed = previous
        renamed.name = "Office"
        let afterRename = draft.following(renamed, previouslySaved: previous)
        XCTAssertEqual(afterRename.username, "bob")
        XCTAssertEqual(afterRename.password, "secret")

        var newUser = previous
        newUser.username = "carol"
        let afterNewUser = draft.following(newUser, previouslySaved: previous)
        XCTAssertEqual(afterNewUser.username, "carol")
        XCTAssertEqual(afterNewUser.password, "")
    }

    func testEverySavedSettingFollows() {
        let previous = makeDraft()
        var saved = previous
        saved.name = "Office"
        saved.host = "office.example"
        saved.port = 3390
        saved.username = "carol"
        saved.domain = "CORP"
        saved.hideCertificateWarnings.toggle()
        saved.timeoutSeconds = 45
        saved.clipboardSharingEnabled.toggle()
        saved.audioPlaybackEnabled.toggle()
        saved.rememberPassword.toggle()
        var draft = previous
        draft.password = "secret"

        XCTAssertEqual(draft.following(saved, previouslySaved: previous), saved)
    }

    // MARK: - End reasons

    func testUnclassifiedFailureKeepsReportedError() {
        let reason = RDPSessionEndReason(
            report: makeReport(stage: "mcs-channel-connection", error: "Negotiation failed"),
            presentedFrames: false
        )

        XCTAssertEqual(reason.kind, .failed)
        XCTAssertEqual(reason.message, "Negotiation failed")
    }

    func testCleanEndAfterFramesUsesTerminationSentence() {
        // A legacy fast-path session never opens RDPGFX, yet showed frames.
        let reason = RDPSessionEndReason(
            report: makeReport(nextStage: "rdp-session-ended", errorInfo: 0x0000_000C),
            presentedFrames: true
        )

        XCTAssertEqual(reason, RDPSessionEndReason(kind: .ended, message: "You signed out of the remote computer."))
    }

    func testTerminationAfterFramesEndsRatherThanFails() {
        // RDPKit reports any termination but logoff and user disconnects as
        // a failure, even after the desktop showed.
        let reason = RDPSessionEndReason(
            report: makeReport(errorInfo: 0x0000_0005, error: "server ended the session with ERRINFO_0x00000005"),
            presentedFrames: true
        )

        XCTAssertEqual(reason, RDPSessionEndReason(
            kind: .ended,
            message: "Another connection to the remote computer took over the session."
        ))
    }

    func testLostConnectionAfterFramesEndsRatherThanFails() {
        let reason = RDPSessionEndReason(
            report: makeReport(error: "receive failed: connection lost: Connection reset by peer"),
            presentedFrames: true
        )

        XCTAssertEqual(reason, RDPSessionEndReason(
            kind: .ended,
            message: "The connection to the remote computer was lost."
        ))
    }

    func testTerminationBeforeFramesFailsWithPlainSentence() {
        let reason = RDPSessionEndReason(
            report: makeReport(errorInfo: 0x0000_0009, error: "server ended the session with ERRINFO_0x00000009"),
            presentedFrames: false
        )

        XCTAssertEqual(reason, RDPSessionEndReason(
            kind: .failed,
            message: "This account is not allowed to connect to the remote computer."
        ))
    }

    func testLicensingTerminationIsPlain() {
        let reason = RDPSessionEndReason(
            report: makeReport(errorInfo: 0x0000_010A, error: "server ended the session with ERRINFO_0x0000010a"),
            presentedFrames: false
        )

        XCTAssertEqual(reason.message, "The remote computer could not license this connection.")
    }

    func testCleanEndBeforeFramesSaysSo() {
        let reason = RDPSessionEndReason(
            report: makeReport(nextStage: "rdp-session-ended"),
            presentedFrames: false
        )

        XCTAssertEqual(reason, RDPSessionEndReason(
            kind: .ended,
            message: "The remote session ended before showing the desktop."
        ))
    }

    func testNegotiationFailureCodesArePlain() {
        func message(failureCode: UInt32) -> String {
            RDPSessionEndReason(
                report: makeReport(
                    stage: "x224-rdp-negotiation",
                    failureCode: failureCode,
                    error: "RDP negotiation failed with code 0x\(String(failureCode, radix: 16))"
                ),
                presentedFrames: false
            ).message
        }

        XCTAssertEqual(
            message(failureCode: 2),
            "The remote computer only allows Standard RDP Security, which RDPeek does not support."
        )
        XCTAssertEqual(message(failureCode: 3), "The remote computer has no certificate for a secure connection.")
        XCTAssertEqual(
            message(failureCode: 6),
            "The remote computer requires Early User Authorization, which RDPeek does not support."
        )
    }

    func testAccountStateIsPlain() {
        let reason = RDPSessionEndReason(
            report: makeReport(
                stage: "credssp",
                error: "CredSSP server returned STATUS_ACCOUNT_LOCKED_OUT (0xc0000234)"
            ),
            presentedFrames: false
        )

        XCTAssertEqual(reason, RDPSessionEndReason(kind: .failed, message: "This account is locked out."))
    }

    // MARK: - Attempt outcomes

    func testUnreachableServerIsRetriedWithinBudget() {
        let error = RDPConnectionError(.connect(error: RDPSocketError(errno: EHOSTUNREACH)), description: "No route to host")

        XCTAssertEqual(SessionAttemptOutcome.afterConnectionError(error, host: "winbox", retriesSpent: 0), .retry)
        XCTAssertEqual(SessionAttemptOutcome.afterConnectionError(error, host: "winbox", retriesSpent: 1), .retry)
        XCTAssertEqual(
            SessionAttemptOutcome.afterConnectionError(error, host: "winbox", retriesSpent: 2),
            .end(RDPSessionEndReason(
                kind: .failed,
                message: "Could not reach “winbox”. Check that it is on and accepts Remote Desktop connections."
            ))
        )
    }

    func testRedirectTargetFailuresBlameThePassingServerAndAreNotRetried() {
        // After a Server Redirection the server typed in took the sign-in,
        // so it is neither blamed nor retried, whatever the target did.
        func outcome(_ error: RDPConnectionError) -> SessionAttemptOutcome {
            SessionAttemptOutcome.afterConnectionError(error, host: "broker", retriesSpent: 0, reachedServer: true)
        }

        XCTAssertEqual(outcome(RDPConnectionError(.connect(error: RDPSocketError(errno: ECONNREFUSED)), description: "Connection refused")), .end(RDPSessionEndReason(
            kind: .failed,
            message: "“broker” passed the session on to a server this Mac could not reach."
        )))
        XCTAssertEqual(outcome(RDPConnectionError(.addressResolution, description: "nodename nor servname provided")), .end(RDPSessionEndReason(
            kind: .failed,
            message: "“broker” passed the session on to a server this Mac could not find."
        )))
        XCTAssertEqual(outcome(RDPConnectionError(.connectionClosed, description: "connection closed before receiving X224 Connection Confirm")), .end(
            RDPSessionEndReason(
                kind: .failed,
                message: "“broker” passed the session on to a server that did not answer as a Remote Desktop server."
            )
        ))
    }

    func testUnresolvableHostIsNeverRetried() {
        let outcome = SessionAttemptOutcome.afterConnectionError(
            RDPConnectionError(.addressResolution, description: "nodename nor servname provided"),
            host: "winbx",
            retriesSpent: 0
        )

        XCTAssertEqual(outcome, .end(RDPSessionEndReason(
            kind: .failed,
            message: "Could not find “winbx”. Check the host name."
        )))
    }

    func testFailedConnectionRequestIsNotRetried() {
        let outcome = SessionAttemptOutcome.afterConnectionError(
            RDPConnectionError(.connectionClosed, description: "connection closed before receiving X224 Connection Confirm"),
            host: "winbox",
            retriesSpent: 0
        )

        XCTAssertEqual(outcome, .end(RDPSessionEndReason(
            kind: .failed,
            message: "“winbox” did not answer as a Remote Desktop server."
        )))
    }

    func testKeyUsageFailureFallsBackToLegacyRSAOnce() {
        let report = makeReport(stage: "tls-handshake", error: keyUsageError)

        XCTAssertEqual(outcome(after: report), .retryWithLegacyRSAKeyExchange)
        XCTAssertEqual(
            outcome(after: report, usedLegacyRSAKeyExchange: true),
            .end(RDPSessionEndReason(
                kind: .failed,
                message: "A secure connection to the remote computer could not be set up."
            ))
        )
    }

    func testKeyUsageFailureAfterARedirectIsNotRetriedWithLegacyRSA() {
        // The certificate came from the server typed in, which took the
        // sign-in and passed the session on: retrying it with RSA key
        // exchange would send it the credentials without forward secrecy.
        let report = makeReport(stage: "tls-handshake", error: keyUsageError)

        XCTAssertEqual(
            outcome(after: report, reachedServer: true),
            .end(RDPSessionEndReason(
                kind: .failed,
                message: "“winbox” passed the session on to a server this Mac could not set up a secure connection with."
            ))
        )
    }

    func testWrongCredentialsAskToSignInAgain() {
        for status in ["STATUS_LOGON_FAILURE (0xc000006d)", "STATUS_WRONG_PASSWORD (0xc000006a)",
                       "STATUS_NO_SUCH_USER (0xc0000064)"]
        {
            // A rejection the server sends after the credentials can
            // surface in the stage after CredSSP.
            let report = makeReport(
                stage: "mcs-channel-connection",
                error: "CredSSP server returned \(status)"
            )

            XCTAssertEqual(
                outcome(after: report),
                .promptForCredentials(message: "The user name or password is incorrect.")
            )
        }
    }

    func testConnectionClosedDuringSignInAsksToSignInAgain() {
        let report = makeReport(
            stage: "credssp",
            error: "receive failed: connection closed before receiving CredSSP response"
        )

        guard case .promptForCredentials = outcome(after: report) else {
            return XCTFail("Expected the sign-in prompt")
        }
    }

    func testConnectingWithoutCredentialsToASignInServerAsksForThem() {
        // RDPKit's error when the server picks CredSSP and the user left
        // every sign-in field empty; nothing was sent.
        let report = makeReport(stage: "credssp", error: "CredSSP requires credentials")

        XCTAssertEqual(
            outcome(after: report),
            .promptForCredentials(message: "The remote computer requires a user name and password.")
        )
    }

    func testSignInTimeoutOrNTLMErrorEndsInsteadOfAskingToSignIn() {
        for error in [
            "receive failed: CredSSP response timed out after 10 seconds",
            "CredSSP NTLM failed: challenge message was truncated",
        ] {
            let report = makeReport(stage: "credssp", error: error)

            XCTAssertEqual(outcome(after: report), .end(RDPSessionEndReason(kind: .failed, message: error)))
        }
    }

    func testCredSSPProtocolFailureEndsInsteadOfAskingToSignIn() {
        let report = makeReport(stage: "credssp", error: "CredSSP server public-key binding did not match")

        XCTAssertEqual(
            outcome(after: report),
            .end(RDPSessionEndReason(kind: .failed, message: "CredSSP server public-key binding did not match"))
        )
    }

    func testFailureReportForThrownErrorKeepsTheError() {
        let configuration = RDPConnectionConfiguration(host: "winbox")
        let report = RDPConnectionReport(
            connectionError: RDPConnectionError(
                .addressResolution,
                description: "address resolution failed: nodename nor servname provided"
            ),
            configuration: configuration
        )

        XCTAssertEqual(report.status, "failure")
        XCTAssertEqual(report.target, "winbox:3389")
        XCTAssertNil(report.nextStage)
        XCTAssertEqual(report.error, "address resolution failed: nodename nor servname provided")
    }

    func testFailureReportAfterARedirectDoesNotNameTheServerTypedInAsTarget() {
        let report = RDPConnectionReport(
            connectionError: RDPConnectionError(.connect(error: RDPSocketError(errno: ECONNREFUSED)), description: "Connection refused"),
            configuration: RDPConnectionConfiguration(host: "broker"),
            redirected: true
        )

        XCTAssertEqual(report.target, "unknown (passed on by broker:3389)")
        XCTAssertEqual(report.error, "Connection refused")
    }

    // MARK: - Logon names

    func testLogonStatusIsReadFromCredSSPError() {
        XCTAssertEqual(
            RDPLogonStatus.code(in: "CredSSP server returned STATUS_LOGON_FAILURE (0xc000006d)"),
            0xC000_006D
        )
        XCTAssertEqual(RDPLogonStatus.code(in: "CredSSP server returned NTSTATUS (0xc0000123)"), 0xC000_0123)
        XCTAssertNil(RDPLogonStatus.code(in: "receive failed: connection closed (0x1)"))
    }

    func testDomainQualifiedUserNameSignsInSplitAndKeepsItsKeychainAccount() throws {
        // RDPeek hands RDPKit the user name as typed: RDPKit signs in with
        // it split, and the Keychain account keeps it whole.
        let credentials = try XCTUnwrap(RDPCredentials.validated(username: "CORP\\anees", domain: "", password: "pw"))
        XCTAssertEqual(credentials.username, "anees")
        XCTAssertEqual(credentials.domain, "CORP")

        let identity = RDPConnectionIdentity(host: "winbox", username: "CORP\\anees", domain: "")
        XCTAssertEqual(identity.credentialAccountName, "CORP\\anees@winbox:3389")
    }

    // MARK: - Keyframe requests

    func testKeyframeRequestsArePacedAndStopUntilVideoDecodesAgain() {
        var throttle = RDPKeyframeRequestThrottle()
        let start = Date()
        func requests(atIntervals intervals: [Double]) -> [Bool] {
            intervals.map {
                throttle.shouldRequest(at: start.addingTimeInterval($0 * RDPKeyframeRequestThrottle.minimumInterval))
            }
        }

        XCTAssertEqual(requests(atIntervals: [0, 0.5, 1, 2, 3]), [true, false, true, true, false])

        throttle.recordDecodedVideo()

        XCTAssertEqual(requests(atIntervals: [4]), [true])
    }

    // MARK: - Initial desktop size

    func testInitialDesktopMatchesTheDisplayControlLayoutAt1x() throws {
        // The layout sent once Display Control opens comes from the canvas
        // pixels; at 1x it must ask for the desktop the connection has.
        for pointSize in [
            CGSize(width: 1280, height: 800),
            CGSize(width: 1281, height: 801),
            CGSize(width: 1023, height: 767),
            CGSize(width: 1440.4, height: 899.6),
        ] {
            let desktop = RDPDesktopSize.initial(canvasPointSize: pointSize)
            let layout = RDPViewerPixelSize(pointSize: pointSize, backingScaleFactor: 1).displayRequest
            XCTAssertEqual(UInt32(desktop.width), layout.width, "\(pointSize)")
            XCTAssertEqual(UInt32(desktop.height), layout.height, "\(pointSize)")
        }
        XCTAssertEqual(
            RDPDesktopSize.initial(canvasPointSize: CGSize(width: 1281, height: 801)),
            try RDPDesktopSize(width: 1280, height: 801)
        )
    }

    func testInitialDesktopStaysWithinDesktopSizeLimits() throws {
        XCTAssertEqual(
            RDPDesktopSize.initial(canvasPointSize: CGSize(width: 300, height: 200)),
            try RDPDesktopSize(width: 640, height: 480)
        )
        XCTAssertEqual(
            RDPDesktopSize.initial(canvasPointSize: CGSize(width: 9001, height: 9001)),
            try RDPDesktopSize(width: 8192, height: 8192)
        )
    }

    private func makeDraft() -> RDPConnectionDraft {
        RDPConnectionDraft(device: DeviceProfile(
            id: UUID(),
            name: "Desk",
            host: "winbox",
            port: 3389,
            username: "alice",
            domain: "",
            hideCertificateWarnings: true,
            timeoutSeconds: 10,
            clipboardSharingEnabled: true,
            audioPlaybackEnabled: false,
            rememberPassword: false,
            accentHue: 0.5,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastConnectedAt: nil
        ))
    }

    private let keyUsageError =
        "TLS failed: the server's certificate does not allow ECDHE key exchange (KEY_USAGE_BIT_INCORRECT)"

    private func outcome(
        after report: RDPConnectionReport,
        usedLegacyRSAKeyExchange: Bool = false,
        reachedServer: Bool = false
    ) -> SessionAttemptOutcome {
        SessionAttemptOutcome.afterSession(
            report,
            host: "winbox",
            presentedFrames: false,
            usedLegacyRSAKeyExchange: usedLegacyRSAKeyExchange,
            reachedServer: reachedServer
        )
    }

    private func makeReport(
        stage: String = "rdp-graphics-dynamic-channel",
        failureCode: UInt32? = nil,
        nextStage: String? = nil,
        errorInfo: UInt32? = nil,
        error: String? = nil
    ) -> RDPConnectionReport {
        RDPConnectionReport(
            status: error == nil ? "success" : "failure",
            stage: stage,
            target: "winbox:3389",
            passwordConfigured: true,
            requestedProtocols: [],
            requestHex: "",
            failureCode: failureCode,
            rdpRemoteTerminationErrorInfo: errorInfo,
            warnings: [],
            nextStage: nextStage,
            error: error
        )
    }
}
