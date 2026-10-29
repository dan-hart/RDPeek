import AppKit
import RDPKit
import XCTest

/// Records what the bridge sends in place of a live CLIPRDR channel.
private final class RecordedClipboard: SessionClipboardSending {
    var publishedTexts: [String?] = []

    func publishLocalUnicodeText(_ text: String?) {
        publishedTexts.append(text)
    }

    func publishLocalFiles(_: [RDPClipboardLocalFile]) {}

    func requestRemoteFileSize(streamID _: UInt32, fileIndex _: Int32) throws {}

    func requestRemoteFileRange(
        streamID _: UInt32,
        fileIndex _: Int32,
        position _: UInt64,
        requestedByteCount _: UInt32
    ) throws {}
}

@MainActor
final class SessionClipboardTests: XCTestCase {
    // MARK: - Temporary sharing

    func testTemporaryShareEndsOnlySharingItTurnedOn() {
        let clipboard = SessionClipboard(isSharingEnabled: true)
        var toasts: [String] = []
        clipboard.onToast = { text, _ in toasts.append(text) }
        XCTAssertFalse(clipboard.canStartTemporarySharing, "No session to share with yet")

        clipboard.attach(RecordedClipboard())
        XCTAssertFalse(clipboard.canStartTemporarySharing)
        clipboard.startTemporarySharing()
        XCTAssertFalse(clipboard.isTemporarySharingActive)
        clipboard.poll(now: Date().addingTimeInterval(31))
        XCTAssertTrue(clipboard.isSharingEnabled)
        XCTAssertFalse(toasts.contains("Clipboard sharing ended"))

        clipboard.setSharingEnabled(false)
        XCTAssertTrue(clipboard.canStartTemporarySharing)
        clipboard.startTemporarySharing()
        XCTAssertTrue(clipboard.isSharingEnabled)
        XCTAssertTrue(clipboard.isTemporarySharingActive)
        XCTAssertTrue(clipboard.canStartTemporarySharing, "A running temporary share can be restarted")
        clipboard.poll(now: Date().addingTimeInterval(31))
        XCTAssertFalse(clipboard.isSharingEnabled)
        XCTAssertFalse(clipboard.isTemporarySharingActive)
        XCTAssertEqual(toasts.last, "Clipboard sharing ended")

        // Turning sharing on during a temporary share keeps it on.
        clipboard.startTemporarySharing()
        clipboard.setSharingEnabled(true)
        XCTAssertFalse(clipboard.isTemporarySharingActive)
        clipboard.poll(now: Date().addingTimeInterval(31))
        XCTAssertTrue(clipboard.isSharingEnabled)
    }

    func testTurningSharingOffClearsTheServerClipboard() {
        let session = RecordedClipboard()
        let clipboard = SessionClipboard(isSharingEnabled: false)
        clipboard.attach(session)
        XCTAssertEqual(session.publishedTexts, [nil])

        clipboard.startTemporarySharing()
        session.publishedTexts.removeAll()
        clipboard.poll(now: Date().addingTimeInterval(31))
        XCTAssertEqual(session.publishedTexts, [nil])
    }
}
