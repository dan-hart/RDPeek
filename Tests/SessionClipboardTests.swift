import AppKit
import RDPKit
import XCTest

/// Records what the bridge sends in place of a live CLIPRDR channel.
private final class RecordedClipboard: SessionClipboardSending {
    struct RangeRequest: Equatable {
        var streamID: UInt32
        var position: UInt64
        var requestedByteCount: UInt32
    }

    var publishedTexts: [String?] = []
    var publishedFiles: [[RDPClipboardLocalFile]] = []
    var sizeRequests: [UInt32] = []
    var rangeRequests: [RangeRequest] = []

    func publishLocalUnicodeText(_ text: String?) {
        publishedTexts.append(text)
    }

    func publishLocalFiles(_ files: [RDPClipboardLocalFile]) {
        publishedFiles.append(files)
    }

    func requestRemoteFileSize(streamID: UInt32, fileIndex _: Int32) throws {
        sizeRequests.append(streamID)
    }

    func requestRemoteFileRange(
        streamID: UInt32,
        fileIndex _: Int32,
        position: UInt64,
        requestedByteCount: UInt32
    ) throws {
        rangeRequests.append(RangeRequest(
            streamID: streamID,
            position: position,
            requestedByteCount: requestedByteCount
        ))
    }
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

        try await XCTUnwrap(clipboard.localFileRead).value
        XCTAssertEqual(session.publishedFiles.map { $0.map(\.contents) }, [[Data("hello".utf8)]])

        // A newer copy wins over a file read still in flight.
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        clipboard.syncNow()
        let staleRead = try XCTUnwrap(clipboard.localFileRead)
        pasteboard.clearContents()
        pasteboard.setString("newer", forType: .string)
        clipboard.syncNow()
        await staleRead.value
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
        var staleRead = try XCTUnwrap(clipboard.localFileRead)
        clipboard.receiveText("remote")
        await staleRead.value
        XCTAssertTrue(session.publishedFiles.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "remote")

        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        clipboard.syncNow()
        staleRead = try XCTUnwrap(clipboard.localFileRead)
        clipboard.setSharingEnabled(false)
        await staleRead.value
        XCTAssertTrue(session.publishedFiles.isEmpty)
    }

    // MARK: - Remote files

    func testRemoteFileArrivesOverRangesTheServerAnswersShort() throws {
        let session = RecordedClipboard()
        let clipboard = SessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
        clipboard.attach(session)
        let contents = Data((0 ..< 1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        try startRemoteFileDownload(contents, to: clipboard, from: session)
        var received = 0
        while received < contents.count {
            let request = try XCTUnwrap(session.rangeRequests.last)
            session.rangeRequests.removeAll()
            XCTAssertEqual(request.position, UInt64(received))
            XCTAssertLessThanOrEqual(request.requestedByteCount, 1024 * 1024)
            // Windows caps how much one answer carries.
            let end = received + min(Int(request.requestedByteCount), 700_000)
            clipboard.receiveFileContents(RDPClipboardFileContentsResponse(
                streamID: request.streamID,
                ok: true,
                data: contents.subdata(in: received ..< end)
            ))
            received = end
        }

        XCTAssertTrue(session.rangeRequests.isEmpty)
        let fileURL = try XCTUnwrap((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), contents)
    }

    func testEmptyRangeAnswerBeforeTheEndFailsTheDownload() throws {
        let session = RecordedClipboard()
        let clipboard = SessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
        var toasts: [String] = []
        clipboard.onToast = { text, _ in toasts.append(text) }
        clipboard.attach(session)

        try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        let request = try XCTUnwrap(session.rangeRequests.last)
        session.rangeRequests.removeAll()
        clipboard.receiveFileContents(RDPClipboardFileContentsResponse(
            streamID: request.streamID,
            ok: true,
            data: Data()
        ))

        XCTAssertTrue(session.rangeRequests.isEmpty)
        XCTAssertEqual(toasts.last, "Remote file transfer was incomplete")
    }

    func testRangeAnswerLongerThanAskedOrFailedFailsTheDownload() throws {
        let session = RecordedClipboard()
        let clipboard = SessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
        var toasts: [String] = []
        clipboard.onToast = { text, _ in toasts.append(text) }
        clipboard.attach(session)

        try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        var request = try XCTUnwrap(session.rangeRequests.last)
        session.rangeRequests.removeAll()
        clipboard.receiveFileContents(RDPClipboardFileContentsResponse(
            streamID: request.streamID,
            ok: true,
            data: Data(count: 11)
        ))
        XCTAssertTrue(session.rangeRequests.isEmpty)
        XCTAssertEqual(toasts.last, "Remote file transfer was incomplete")

        try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        request = try XCTUnwrap(session.rangeRequests.last)
        session.rangeRequests.removeAll()
        clipboard.receiveFileContents(RDPClipboardFileContentsResponse(
            streamID: request.streamID,
            ok: false,
            data: Data()
        ))
        XCTAssertTrue(session.rangeRequests.isEmpty)
        XCTAssertEqual(toasts.last, "Remote file transfer failed")
    }

    func testEmptyRemoteFileIsCopiedWithoutARangeRequest() throws {
        let session = RecordedClipboard()
        let clipboard = SessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
        clipboard.attach(session)

        try startRemoteFileDownload(Data(), to: clipboard, from: session)

        XCTAssertTrue(session.rangeRequests.isEmpty)
        let fileURL = try XCTUnwrap((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), Data())
    }

    // MARK: - Helpers

    /// Offers one remote file of `contents` and answers the size request.
    private func startRemoteFileDownload(
        _ contents: Data,
        to clipboard: SessionClipboard,
        from session: RecordedClipboard
    ) throws {
        clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: [
            RDPClipboardFileDescriptorW(
                flags: 0,
                fileAttributes: 0,
                fileSize: UInt64(contents.count),
                fileName: "big.bin"
            ),
        ]))
        let streamID = try XCTUnwrap(session.sizeRequests.last)
        let size = UInt64(contents.count).littleEndian
        clipboard.receiveFileContents(RDPClipboardFileContentsResponse(
            streamID: streamID,
            ok: true,
            data: withUnsafeBytes(of: size) { Data($0) }
        ))
    }

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
}
