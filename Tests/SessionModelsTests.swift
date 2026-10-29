import RDPKit
import XCTest

final class SessionModelsTests: XCTestCase {
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
        let error = RDPConnectionError.connect("No route to host")

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

    func testUnreachableRedirectTargetIsNotRetried() {
        let outcome = SessionAttemptOutcome.afterConnectionError(
            RDPConnectionError.connect("Connection refused"),
            host: "broker",
            retriesSpent: 0,
            reachedServer: true
        )

        XCTAssertEqual(outcome, .end(RDPSessionEndReason(
            kind: .failed,
            message: "“broker” redirected the connection to a server that could not be reached."
        )))
    }

    func testUnresolvableHostIsNeverRetried() {
        let outcome = SessionAttemptOutcome.afterConnectionError(
            RDPConnectionError.addressResolution("nodename nor servname provided"),
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
            RDPConnectionError.receive("connection closed before receiving X224 Connection Confirm"),
            host: "winbox",
            retriesSpent: 0
        )

        XCTAssertEqual(outcome, .end(RDPSessionEndReason(
            kind: .failed,
            message: "“winbox” did not answer as a Remote Desktop server."
        )))
    }

    func testKeyUsageFailureFallsBackToLegacyRSAOnce() {
        let report = makeReport(
            stage: "tls-handshake",
            error: "TLS failed: the server's certificate does not allow ECDHE key exchange (KEY_USAGE_BIT_INCORRECT)"
        )

        XCTAssertEqual(
            SessionAttemptOutcome.afterSession(report, presentedFrames: false, usedLegacyRSAKeyExchange: false),
            .retryWithLegacyRSAKeyExchange
        )
        XCTAssertEqual(
            SessionAttemptOutcome.afterSession(report, presentedFrames: false, usedLegacyRSAKeyExchange: true),
            .end(RDPSessionEndReason(
                kind: .failed,
                message: "A secure connection to the remote computer could not be set up."
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
                SessionAttemptOutcome.afterSession(report, presentedFrames: false, usedLegacyRSAKeyExchange: false),
                .promptForCredentials(message: "The user name or password is incorrect.")
            )
        }
    }

    func testConnectionClosedDuringSignInAsksToSignInAgain() {
        let report = makeReport(
            stage: "credssp",
            error: "receive failed: connection closed before receiving CredSSP response"
        )

        guard case .promptForCredentials = SessionAttemptOutcome.afterSession(
            report,
            presentedFrames: false,
            usedLegacyRSAKeyExchange: false
        ) else {
            return XCTFail("Expected the sign-in prompt")
        }
    }

    func testSignInTimeoutOrNTLMErrorEndsInsteadOfAskingToSignIn() {
        for error in [
            "receive failed: CredSSP response timed out after 10 seconds",
            "CredSSP NTLM failed: challenge message was truncated",
        ] {
            let report = makeReport(stage: "credssp", error: error)

            XCTAssertEqual(
                SessionAttemptOutcome.afterSession(report, presentedFrames: false, usedLegacyRSAKeyExchange: false),
                .end(RDPSessionEndReason(kind: .failed, message: error))
            )
        }
    }

    func testCredSSPProtocolFailureEndsInsteadOfAskingToSignIn() {
        let report = makeReport(stage: "credssp", error: "CredSSP server public-key binding did not match")

        XCTAssertEqual(
            SessionAttemptOutcome.afterSession(report, presentedFrames: false, usedLegacyRSAKeyExchange: false),
            .end(RDPSessionEndReason(kind: .failed, message: "CredSSP server public-key binding did not match"))
        )
    }

    func testFailureReportForThrownErrorKeepsTheError() {
        let configuration = RDPConnectionConfiguration(host: "winbox")
        let report = RDPConnectionReport(
            connectionError: RDPConnectionError.addressResolution("nodename nor servname provided"),
            configuration: configuration
        )

        XCTAssertEqual(report.status, "failure")
        XCTAssertEqual(report.target, "winbox:3389")
        XCTAssertNil(report.nextStage)
        XCTAssertEqual(report.error, "address resolution failed: nodename nor servname provided")
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

    func testDomainQualifiedUserNameSplitsWhenNoDomainIsGiven() {
        XCTAssertEqual(
            RDPLogonName(username: "CORP\\anees", domain: ""),
            RDPLogonName(username: "anees", domain: "CORP")
        )
        XCTAssertEqual(
            RDPLogonName(username: ".\\admin", domain: ""),
            RDPLogonName(username: "admin", domain: ".")
        )
    }

    func testLogonNameIsKeptWhenSplittingWouldNotHelp() {
        let explicitDomain = RDPLogonName(username: "CORP\\anees", domain: "OTHER")
        XCTAssertEqual(explicitDomain.username, "CORP\\anees")
        XCTAssertEqual(explicitDomain.domain, "OTHER")

        let principal = RDPLogonName(username: "anees@corp.example", domain: "")
        XCTAssertEqual(principal.username, "anees@corp.example")
        XCTAssertEqual(principal.domain, "")

        XCTAssertEqual(RDPLogonName(username: "\\anees", domain: "").username, "\\anees")
        XCTAssertEqual(RDPLogonName(username: "CORP\\", domain: "").username, "CORP\\")
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
