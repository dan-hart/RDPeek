import Foundation
import RDPKit

/// The session-opening surface the device list needs, as a seam so tests
/// can substitute a recorder instead of the full session window stack.
@MainActor
protocol RemoteSessionOpening: AnyObject {
    func openRemoteSession(_ draft: RDPConnectionDraft)
}

/// Everything a session window needs to open and drive a connection.
struct RDPConnectionDraft: Equatable, Sendable {
    var deviceID: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var domain: String
    var password: String
    var hideCertificateWarnings: Bool
    var timeoutSeconds: Int
    var clipboardSharingEnabled: Bool
    var audioPlaybackEnabled: Bool
    var rememberPassword: Bool

    init(device: DeviceProfile, password: String) {
        deviceID = device.id
        name = device.displayName
        host = device.host
        port = device.port
        username = device.username
        domain = device.domain
        self.password = password
        hideCertificateWarnings = device.hideCertificateWarnings
        timeoutSeconds = device.timeoutSeconds
        clipboardSharingEnabled = device.clipboardSharingEnabled
        audioPlaybackEnabled = device.audioPlaybackEnabled
        rememberPassword = device.rememberPassword
    }

    var identity: RDPConnectionIdentity {
        RDPConnectionIdentity(
            host: host,
            port: port,
            username: username,
            domain: domain
        )
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? identity.displayName : trimmedName
    }
}

struct RDPSessionEndReason: Equatable {
    enum Kind: Equatable {
        case cancelled
        case failed
        case ended
    }

    var kind: Kind
    var message: String

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    static let cancelled = RDPSessionEndReason(
        kind: .cancelled,
        message: "Connection cancelled by user."
    )

    /// Why a session RDPKit set up ended, in plain words; the report keeps
    /// the raw details for Diagnostics. Once the desktop was shown the
    /// session ended rather than failed, however it ended.
    init(report: RDPConnectionReport, presentedFrames: Bool) {
        let showedDesktop = presentedFrames || report.rdpGraphicsFirstFrame != nil
        let termination = Self.terminationMessage(errorInfo: report.rdpRemoteTerminationErrorInfo)
        if report.error == nil {
            kind = .ended
            message = termination ?? (showedDesktop
                ? "The remote session ended."
                : "The remote session ended before showing the desktop.")
        } else if showedDesktop {
            kind = .ended
            message = termination ?? "The connection to the remote computer was lost."
        } else {
            kind = .failed
            message = termination ?? Self.failureMessage(report)
        }
    }

    /// The remote computer did not show the desktop in time after accepting
    /// the sign-in.
    static let firstFrameTimeout = RDPSessionEndReason(
        kind: .failed,
        message: "The remote computer did not show the desktop in time."
    )

    /// Why the server ended the session: its last Set Error Info code
    /// ([MS-RDPBCGR] 2.2.5.1.1), or nil for codes with nothing plainer to
    /// say than "the session ended".
    private static func terminationMessage(errorInfo: UInt32?) -> String? {
        guard let errorInfo else {
            return nil
        }
        return switch errorInfo {
        case 0x0000_0001:
            "An administrator disconnected the session."
        case 0x0000_0002:
            "An administrator signed you out of the remote computer."
        case 0x0000_0003:
            "The session was disconnected after being idle too long."
        case 0x0000_0004:
            "The session reached its time limit."
        case 0x0000_0005:
            "Another connection to the remote computer took over the session."
        case 0x0000_0006:
            "The remote computer ran out of memory."
        case 0x0000_0007:
            "The remote computer refused the connection."
        case 0x0000_0009:
            "This account is not allowed to connect to the remote computer."
        case 0x0000_000A:
            "The remote computer requires you to sign in again."
        case 0x0000_000B:
            "The session was disconnected from the remote computer."
        case 0x0000_000C:
            "You signed out of the remote computer."
        case 0x0000_0100 ... 0x0000_010A:
            licensingMessage
        default:
            nil
        }
    }

    private static let licensingMessage = "The remote computer could not license this connection."

    private static let standardSecurityMessage =
        "The remote computer only allows Standard RDP Security, which RDPeek does not support."

    /// Why a connection failed before the desktop showed, when the server
    /// gave no termination code.
    private static func failureMessage(_ report: RDPConnectionReport) -> String {
        let error = report.error ?? ""
        if let status = RDPLogonStatus.code(in: error) {
            return RDPLogonStatus.message(for: status)
        }
        if let failureCode = report.failureCode {
            // RDP_NEG_FAILURE codes ([MS-RDPBCGR] 2.2.1.2.2).
            return switch failureCode {
            case 0x0000_0002:
                standardSecurityMessage
            case 0x0000_0003:
                "The remote computer has no certificate for a secure connection."
            case 0x0000_0006:
                "The remote computer requires Early User Authorization, which RDPeek does not support."
            default:
                "The remote computer refused the connection request (code \(failureCode))."
            }
        }
        if error == "standard RDP security is not supported" {
            return standardSecurityMessage
        }
        switch report.stage {
        case "tls-handshake":
            return "A secure connection to the remote computer could not be set up."
        case "early-user-authorization" where report.earlyUserAuthorizationResult == 0x0000_0005:
            return "The remote computer denied this account access."
        case "rdp-licensing" where report.rdpLicensingErrorCode != nil:
            return licensingMessage
        default:
            return report.error ?? "The connection failed at \(report.stage)."
        }
    }

    var title: String {
        switch kind {
        case .cancelled:
            return "Disconnected"
        case .failed:
            return "Connection Failed"
        case .ended:
            return "Disconnected"
        }
    }

    var statusText: String {
        switch kind {
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        case .ended:
            return "Disconnected"
        }
    }

    var systemImage: String {
        switch kind {
        case .cancelled:
            return "xmark.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .ended:
            return "power"
        }
    }

    var diagnosticValue: String {
        "\(statusText): \(message)"
    }
}

/// What a session does next when a connection attempt ends without the
/// user ending it.
enum SessionAttemptOutcome: Equatable {
    /// Connect again at once offering only RSA key exchange: the server's
    /// certificate does not allow the ECDHE key exchange offered first.
    case retryWithLegacyRSAKeyExchange
    /// Connect again after a short pause.
    case retry
    /// Ask for the user name and password again, saying why.
    case promptForCredentials(message: String)
    /// Show why the session ended.
    case end(RDPSessionEndReason)

    /// Automatic reconnects to a server that could not be reached. The
    /// first connection to a LAN host often fails while macOS asks for
    /// local network access.
    static let maximumUnreachableRetries = 2

    static let wrongCredentialsMessage = "The user name or password is incorrect."

    /// After `RDPSessionClient.connect` threw: no RDP connection was set up,
    /// so no credential was sent. Only an unreachable server is retried — a
    /// host name that does not resolve stays wrong.
    static func afterConnectionError(_ error: any Error, host: String, retriesSpent: Int) -> Self {
        switch error as? RDPConnectionError {
        case .connect?:
            guard retriesSpent >= maximumUnreachableRetries else {
                return .retry
            }
            return .end(RDPSessionEndReason(
                kind: .failed,
                message: "Could not reach “\(host)”. Check that it is on and accepts Remote Desktop connections."
            ))
        case .addressResolution?:
            return .end(RDPSessionEndReason(
                kind: .failed,
                message: "Could not find “\(host)”. Check the host name."
            ))
        default:
            return .end(RDPSessionEndReason(
                kind: .failed,
                message: "“\(host)” did not answer as a Remote Desktop server."
            ))
        }
    }

    /// After a session RDPKit set up ended. Credentials may have been sent,
    /// so nothing is retried with them: a rejected sign-in asks again.
    static func afterSession(
        _ report: RDPConnectionReport,
        presentedFrames: Bool,
        usedLegacyRSAKeyExchange: Bool
    ) -> Self {
        if presentedFrames == false, let error = report.error {
            // RDPKit names the certificate's missing key usage in the TLS
            // failure, which ends the attempt before any credential is sent.
            if report.stage == "tls-handshake",
               usedLegacyRSAKeyExchange == false,
               error.contains("KEY_USAGE_BIT_INCORRECT")
            {
                return .retryWithLegacyRSAKeyExchange
            }
            if let status = RDPLogonStatus.code(in: error) {
                if RDPLogonStatus.isWrongCredentials(status) {
                    return .promptForCredentials(message: wrongCredentialsMessage)
                }
            } else if report.stage == "credssp", error.contains("CredSSP server") == false {
                // Some servers close the connection on a rejected sign-in
                // instead of naming the reason. A server that answered
                // CredSSP wrongly is not a sign-in problem.
                return .promptForCredentials(
                    message: "The remote computer did not accept the sign-in. Check the user name and password."
                )
            }
        }
        return .end(RDPSessionEndReason(report: report, presentedFrames: presentedFrames))
    }
}

extension RDPConnectionReport {
    /// The report for an attempt `RDPSessionClient.connect` threw on, shaped
    /// as `run` reports it, so Diagnostics keeps the raw error.
    init(connectionError: any Error, configuration: RDPConnectionConfiguration) {
        self = RDPSessionClient().dryRun(configuration: configuration)
        status = "failure"
        stage = "x224-rdp-negotiation"
        nextStage = nil
        error = String(describing: connectionError)
    }
}

/// The NTSTATUS a CredSSP server rejected a sign-in with ([MS-ERREF]
/// 2.3.1). RDPKit reports it only in its error text, as
/// "CredSSP server returned STATUS_LOGON_FAILURE (0xc000006d)".
enum RDPLogonStatus {
    static func code(in error: String) -> UInt32? {
        guard let returned = error.range(of: "CredSSP server returned "),
              let open = error.range(of: "(0x", range: returned.upperBound ..< error.endIndex),
              let close = error[open.upperBound...].firstIndex(of: ")")
        else {
            return nil
        }
        return UInt32(error[open.upperBound ..< close], radix: 16)
    }

    /// STATUS_LOGON_FAILURE, STATUS_WRONG_PASSWORD, and STATUS_NO_SUCH_USER:
    /// signing in again can fix these.
    static func isWrongCredentials(_ status: UInt32) -> Bool {
        [0xC000_006D, 0xC000_006A, 0xC000_0064].contains(status)
    }

    static func message(for status: UInt32) -> String {
        if isWrongCredentials(status) {
            return SessionAttemptOutcome.wrongCredentialsMessage
        }
        return switch status {
        case 0xC000_0022:
            "The remote computer denied this account access."
        case 0xC000_006E:
            "An account restriction, such as a blank password, prevents this sign-in."
        case 0xC000_006F:
            "This account is not allowed to sign in at this time."
        case 0xC000_0070:
            "This account is not allowed to sign in from this Mac."
        case 0xC000_0071, 0xC000_0224:
            "The password for this account has expired and must be changed."
        case 0xC000_0072:
            "This account is disabled."
        case 0xC000_015B:
            "This account is not allowed to sign in with Remote Desktop."
        case 0xC000_0193:
            "This account has expired."
        case 0xC000_0234:
            "This account is locked out."
        default:
            "The remote computer rejected the sign-in (status 0x\(String(status, radix: 16)))."
        }
    }
}

/// The user name and domain RDPKit signs in with. A "DOMAIN\user" user
/// name with no domain of its own splits into both, as Windows clients do;
/// the device keeps the name as typed, so its Keychain entry is unchanged.
struct RDPLogonName: Equatable {
    var username: String
    var domain: String

    init(username: String, domain: String) {
        if domain.isEmpty, let separator = username.firstIndex(of: "\\") {
            let qualifier = username[..<separator]
            let name = username[username.index(after: separator)...]
            if qualifier.isEmpty == false, name.isEmpty == false {
                self.username = String(name)
                self.domain = String(qualifier)
                return
            }
        }
        self.username = username
        self.domain = domain
    }
}

/// Paces the keyframe requests sent after video fails to decode: one at most every few seconds,
/// and only a few until video decodes again, so video that never decodes does not make the
/// server reset its graphics forever.
struct RDPKeyframeRequestThrottle {
    static let minimumInterval: TimeInterval = 3
    static let maximumUnansweredRequests = 3

    private var lastRequestAt: Date?
    private var unansweredRequests = 0

    mutating func shouldRequest(at date: Date) -> Bool {
        guard unansweredRequests < Self.maximumUnansweredRequests else {
            return false
        }
        if let lastRequestAt, date.timeIntervalSince(lastRequestAt) < Self.minimumInterval {
            return false
        }
        lastRequestAt = date
        unansweredRequests += 1
        return true
    }

    mutating func recordDecodedVideo() {
        unansweredRequests = 0
    }
}
