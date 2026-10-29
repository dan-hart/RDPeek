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
    /// A pasteboard and download root of the test's own, so tests never
    /// read or replace the user's clipboard or its downloads.
    private var pasteboard: NSPasteboard!
    private var downloadRoot: URL!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("RDPeekTests.\(UUID().uuidString)"))
        downloadRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDPeekTests.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        try? FileManager.default.removeItem(at: downloadRoot)
        downloadRoot = nil
    }

    // MARK: - Temporary sharing

    func testTemporaryShareEndsOnlySharingItTurnedOn() {
        let clipboard = makeClipboard()
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
        let clipboard = makeClipboard(isSharingEnabled: false)
        clipboard.attach(session)
        XCTAssertEqual(session.publishedTexts, [nil])

        clipboard.startTemporarySharing()
        session.publishedTexts.removeAll()
        clipboard.poll(now: Date().addingTimeInterval(31))
        XCTAssertEqual(session.publishedTexts, [nil])
    }

    /// The session always joins the clipboard channel, so this alone keeps
    /// a device that does not share from sharing.
    func testSharingOffSharesNothingEitherWay() {
        pasteboard.clearContents()
        pasteboard.setString("local", forType: .string)
        let session = RecordedClipboard()
        let clipboard = makeClipboard(isSharingEnabled: false)
        clipboard.attach(session)
        XCTAssertFalse(clipboard.canSync)
        XCTAssertTrue(clipboard.canStartTemporarySharing)

        pasteboard.clearContents()
        pasteboard.setString("newer local", forType: .string)
        clipboard.poll()
        clipboard.syncNow()
        XCTAssertEqual(session.publishedTexts, [nil])
        XCTAssertTrue(session.publishedFiles.isEmpty)

        clipboard.receiveText("remote")
        clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: [
            RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: 1, fileName: "remote.txt"),
        ]))
        XCTAssertEqual(pasteboard.string(forType: .string), "newer local")
        XCTAssertTrue(session.sizeRequests.isEmpty)

        clipboard.setSharingEnabled(true)
        XCTAssertEqual(session.publishedTexts.last, "newer local")
    }

    func testOnlySyncNowSaysTheClipboardSynced() {
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        let session = RecordedClipboard()
        let clipboard = makeClipboard(isSharingEnabled: false)
        var toasts: [String] = []
        clipboard.onToast = { text, _ in toasts.append(text) }
        clipboard.attach(session)
        clipboard.startTemporarySharing()
        clipboard.setSharingEnabled(true)
        XCTAssertEqual(session.publishedTexts, [nil, "hello", "hello"])
        XCTAssertEqual(toasts, ["Sharing clipboard for 30 seconds"])

        clipboard.syncNow()
        XCTAssertEqual(toasts.last, "Clipboard synced")

        pasteboard.clearContents()
        clipboard.syncNow()
        XCTAssertEqual(session.publishedTexts.last, .some(nil))
        XCTAssertEqual(toasts.last, "Clipboard has no text or files; remote clipboard cleared")
    }

    // MARK: - Local files

    func testCopiedLocalFilesPublishAfterAttachAndANewerCopyWins() async throws {
        let fileURL = try makeLocalFile(named: "notes.txt", contents: Data("hello".utf8))
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])

        let session = RecordedClipboard()
        let clipboard = makeClipboard()
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
        let clipboard = makeClipboard()
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

    func testLocalFileNamesAreMadeValidOnWindows() async throws {
        var usedFileNames = Set<String>()
        let names = ["a*b?.txt", "q\"<>|\\.txt", "draft. .", "...", "Notes.txt", "notes.txt", "notes.TXT"].map {
            SessionClipboard.windowsFileName($0, usedFileNames: &usedFileNames)
        }
        XCTAssertEqual(names, ["a_b_.txt", "q_____.txt", "draft", "file", "Notes.txt", "notes-2.txt", "notes-3.TXT"])

        // A "/" Finder shows in a name is a ":" on disk. Files from two
        // folders can share a name.
        let first = try makeLocalFile(named: "a:b.txt", contents: Data())
        let second = try makeLocalFile(named: "a:b.txt", contents: Data())
        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL, second as NSURL])
        let session = RecordedClipboard()
        let clipboard = makeClipboard()
        clipboard.attach(session)
        try await XCTUnwrap(clipboard.localFileRead).value
        XCTAssertEqual(session.publishedFiles.last?.map(\.descriptor.fileName), ["a_b.txt", "a_b-2.txt"])
    }

    // MARK: - Remote files

    func testRemoteFileArrivesOverRangesTheServerAnswersShort() throws {
        let session = RecordedClipboard()
        let clipboard = makeClipboard()
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
        let fileURL = try XCTUnwrap(copiedFileURL())
        XCTAssertEqual(try Data(contentsOf: fileURL), contents)
        let quarantine = try fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(quarantine?[kLSQuarantineAgentNameKey as String] as? String, "RDPeek")
    }

    func testEmptyRangeAnswerBeforeTheEndFailsTheDownload() throws {
        let session = RecordedClipboard()
        let clipboard = makeClipboard()
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
        let clipboard = makeClipboard()
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
        let clipboard = makeClipboard()
        clipboard.attach(session)

        try startRemoteFileDownload(Data(), to: clipboard, from: session)

        XCTAssertTrue(session.rangeRequests.isEmpty)
        let fileURL = try XCTUnwrap(copiedFileURL())
        XCTAssertEqual(try Data(contentsOf: fileURL), Data())
    }

    func testUnansweredFileRequestTimesOut() throws {
        let session = RecordedClipboard()
        let clipboard = makeClipboard()
        var toasts: [String] = []
        clipboard.onToast = { text, _ in toasts.append(text) }
        clipboard.attach(session)
        try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)

        clipboard.poll(now: Date().addingTimeInterval(29))
        XCTAssertFalse(toasts.contains("Remote file transfer timed out"))
        clipboard.poll(now: Date().addingTimeInterval(31))
        XCTAssertEqual(toasts.last, "Remote file transfer timed out")

        // An answer after the timeout is dropped.
        try finishRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        XCTAssertNil(copiedFileURL())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloadRoot.path), [])
    }

    func testNewerCopyDropsARemoteFileStillDownloading() throws {
        let session = RecordedClipboard()
        let clipboard = makeClipboard()
        var toasts: [String] = []
        clipboard.onToast = { text, _ in toasts.append(text) }
        clipboard.attach(session)

        // A local copy the poll has not seen yet still wins.
        try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        try finishRemoteFileDownload(Data(count: 10), to: clipboard, from: session) {
            pasteboard.clearContents()
            pasteboard.setString("local", forType: .string)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "local")

        // So does one the poll has published.
        try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        try finishRemoteFileDownload(Data(count: 10), to: clipboard, from: session) {
            pasteboard.clearContents()
            pasteboard.setString("newer local", forType: .string)
            clipboard.poll()
        }
        XCTAssertEqual(session.publishedTexts.last, "newer local")
        XCTAssertEqual(pasteboard.string(forType: .string), "newer local")

        // And a remote copy of text.
        try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        try finishRemoteFileDownload(Data(count: 10), to: clipboard, from: session) {
            clipboard.receiveText("remote")
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "remote")
        XCTAssertFalse(toasts.contains { $0.hasPrefix("Remote file copied") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloadRoot.path), [])
    }

    // MARK: - Download cleanup

    func testFinishedDownloadIsRemovedOnceItLeavesThePasteboard() throws {
        let session = RecordedClipboard()
        let clipboard = makeClipboard()
        clipboard.attach(session)
        try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        try finishRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        let firstFileURL = try XCTUnwrap(copiedFileURL())

        try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        XCTAssertTrue(fileExists(firstFileURL), "Still pasteable while the next file downloads")
        try finishRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
        let secondFileURL = try XCTUnwrap(copiedFileURL())
        XCTAssertFalse(fileExists(firstFileURL))

        clipboard.detach()
        XCTAssertTrue(fileExists(secondFileURL), "Still pasteable after the session ends")
        pasteboard.clearContents()
        pasteboard.setString("local", forType: .string)
        clipboard.detach()
        XCTAssertFalse(fileExists(secondFileURL))
    }

    func testDownloadsLeftByAnEarlierRunAreRemoved() throws {
        let leftover = downloadRoot.appendingPathComponent("earlier", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        _ = makeClipboard()
        XCTAssertFalse(fileExists(leftover))
    }

    func testDownloadsLeftByAnEarlierRunStayWhileFilesAreCopied() throws {
        let leftover = downloadRoot.appendingPathComponent("earlier", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let fileURL = try makeLocalFile(named: "notes.txt", contents: Data())
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        _ = makeClipboard()
        XCTAssertTrue(fileExists(leftover))
    }

    // MARK: - Helpers

    private func makeClipboard(isSharingEnabled: Bool = true) -> SessionClipboard {
        SessionClipboard(isSharingEnabled: isSharingEnabled, pasteboard: pasteboard, downloadRoot: downloadRoot)
    }

    private func copiedFileURL() -> URL? {
        (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

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

    /// Answers the outstanding range request with all of `contents`, after
    /// running `beforeAnswer`.
    private func finishRemoteFileDownload(
        _ contents: Data,
        to clipboard: SessionClipboard,
        from session: RecordedClipboard,
        beforeAnswer: () -> Void = {}
    ) throws {
        let request = try XCTUnwrap(session.rangeRequests.last)
        session.rangeRequests.removeAll()
        beforeAnswer()
        clipboard.receiveFileContents(RDPClipboardFileContentsResponse(
            streamID: request.streamID,
            ok: true,
            data: contents
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
