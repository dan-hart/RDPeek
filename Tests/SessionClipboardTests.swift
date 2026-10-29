import AppKit
import RDPKit
import XCTest

/// Records what the bridge sends in place of a live CLIPRDR channel.
private final class RecordedClipboard: SessionClipboardSending {
    var publishedTexts: [String?] = []
    var publishedFiles: [[RDPClipboardLocalFile]] = []

    func publishLocalUnicodeText(_ text: String?) {
        publishedTexts.append(text)
    }

    func publishLocalFiles(_ files: [RDPClipboardLocalFile]) {
        publishedFiles.append(files)
    }

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
    /// A pasteboard of the test's own, so tests never read or replace the
    /// user's clipboard.
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("RDPeekTests.\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    // MARK: - Temporary sharing

    func testTemporaryShareEndsOnlySharingItTurnedOn() {
        let clipboard = SessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
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
        let clipboard = SessionClipboard(isSharingEnabled: false, pasteboard: pasteboard)
        clipboard.attach(session)
        XCTAssertEqual(session.publishedTexts, [nil])

        clipboard.startTemporarySharing()
        session.publishedTexts.removeAll()
        clipboard.poll(now: Date().addingTimeInterval(31))
        XCTAssertEqual(session.publishedTexts, [nil])
    }

    // MARK: - Local files

    func testCopiedLocalFilesAreReadOffTheMainThread() async throws {
        let fileURL = try makeLocalFile(named: "notes.txt", contents: Data("hello".utf8))
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])

        let session = RecordedClipboard()
        let clipboard = SessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
        clipboard.attach(session)
        XCTAssertTrue(session.publishedFiles.isEmpty, "The read finishes after attach returns")

        try await waitUntil { session.publishedFiles.isEmpty == false }
        XCTAssertEqual(session.publishedFiles.map { $0.map(\.contents) }, [[Data("hello".utf8)]])

        // A newer copy wins over a file read still in flight.
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        clipboard.syncNow()
        pasteboard.clearContents()
        pasteboard.setString("newer", forType: .string)
        clipboard.syncNow()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(session.publishedFiles.count, 1)
        XCTAssertEqual(session.publishedTexts.last, "newer")
    }

    func testRemoteTextOrSharingOffDropsAFileReadInFlight() async throws {
        let fileURL = try makeLocalFile(named: "notes.txt", contents: Data("hello".utf8))
        let session = RecordedClipboard()
        let clipboard = SessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
        clipboard.attach(session)

        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        clipboard.syncNow()
        clipboard.receiveText("remote")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(session.publishedFiles.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "remote")

        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        clipboard.syncNow()
        clipboard.setSharingEnabled(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(session.publishedFiles.isEmpty)
    }

    // MARK: - Helpers

    private func makeLocalFile(named fileName: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent(fileName)
        try contents.write(to: fileURL)
        return fileURL
    }

    /// Lets the main actor run, for up to two seconds, until `condition` holds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where condition() == false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
