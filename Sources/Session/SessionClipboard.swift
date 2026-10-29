import AppKit
import RDPKit

private let sessionMaximumLocalClipboardFileBytes = 32 * 1024 * 1024
/// The most asked for in one FILECONTENTS_RANGE request; servers may send
/// less anyway.
private let sessionMaximumFileRangeByteCount: UInt64 = 1024 * 1024

/// Where the clipboard bridge sends: the session's `RDPClipboardSession`, or
/// a test's recorder.
protocol SessionClipboardSending: AnyObject {
    func publishLocalUnicodeText(_ text: String?)
    func publishLocalFiles(_ files: [RDPClipboardLocalFile])
    func requestRemoteFileSize(streamID: UInt32, fileIndex: Int32) throws
    func requestRemoteFileRange(
        streamID: UInt32,
        fileIndex: Int32,
        position: UInt64,
        requestedByteCount: UInt32
    ) throws
}

extension RDPClipboardSession: SessionClipboardSending {}

/// Bridges the macOS pasteboard and a session's CLIPRDR channel: publishes
/// local text and files, applies remote text, and downloads remote files into
/// a temporary directory. What the user should hear about is reported through
/// `onToast`.
///
/// Adapted from RDPKit's example client (`RDPRemoteSessionClipboard`).
@MainActor
final class SessionClipboard {
    private(set) var session: (any SessionClipboardSending)?
    private(set) var isSharingEnabled: Bool
    /// Shows a transient message: its text and an SF Symbol name.
    var onToast: (_ text: String, _ systemImage: String) -> Void = { _, _ in }
    private let pasteboard: NSPasteboard
    /// Holds a directory for each remote file download.
    private let downloadRoot: URL
    private var pasteboardChangeCount: Int
    /// Reads copied local files off the main thread; tests await it.
    private(set) var localFileRead: Task<Void, Never>?
    private var temporarySharingExpiresAt: Date?
    private var fileTransfer: SessionRemoteClipboardFileTransfer?
    /// The last download put on the pasteboard, and the pasteboard's change
    /// count once it was there: a later count means its files are gone from
    /// the pasteboard.
    private var copiedDownload: (directory: URL, changeCount: Int)?
    private var nextStreamID: UInt32 = 1

    /// Download roots this process has cleared of earlier runs' downloads.
    private static var clearedDownloadRoots: Set<URL> = []

    /// `pasteboard` and `downloadRoot` are the user's clipboard and a
    /// directory in the temporary directory except in tests, which use their
    /// own.
    init(
        isSharingEnabled: Bool,
        pasteboard: NSPasteboard = .general,
        downloadRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RDPeekRemoteClipboard", isDirectory: true)
    ) {
        self.isSharingEnabled = isSharingEnabled
        self.pasteboard = pasteboard
        self.downloadRoot = downloadRoot
        pasteboardChangeCount = pasteboard.changeCount
        if Self.clearedDownloadRoots.insert(downloadRoot).inserted {
            removeEarlierDownloads()
        }
    }

    var canSync: Bool {
        isSharingEnabled && session != nil
    }

    var isTemporarySharingActive: Bool {
        temporarySharingExpiresAt != nil
    }

    /// Off while sharing is on for good, which a temporary share would end.
    var canStartTemporarySharing: Bool {
        session != nil && (isSharingEnabled == false || isTemporarySharingActive)
    }

    var temporarySharingSecondsRemaining: Int? {
        guard let temporarySharingExpiresAt else {
            return nil
        }
        let remainingSeconds = temporarySharingExpiresAt.timeIntervalSinceNow
        return max(0, Int(ceil(remainingSeconds)))
    }

    func attach(_ session: any SessionClipboardSending) {
        self.session = session
        guard isSharingEnabled else {
            session.publishLocalUnicodeText(nil)
            return
        }
        publishPasteboardIfChanged(force: true)
    }

    /// Forgets the session once its channel is gone, so polling and syncing
    /// stop talking to it, and drops any download in flight. A finished
    /// download stays only while its files are still on the pasteboard.
    func detach() {
        session = nil
        discardFileTransfer()
        cancelLocalFileRead()
        removeCopiedDownloadIfReplaced()
        pasteboardChangeCount = pasteboard.changeCount
    }

    /// The user's choice, which also ends a temporary share.
    func setSharingEnabled(_ enabled: Bool) {
        isSharingEnabled = enabled
        temporarySharingExpiresAt = nil
        guard enabled else {
            discardFileTransfer()
            cancelLocalFileRead()
            session?.publishLocalUnicodeText(nil)
            pasteboardChangeCount = pasteboard.changeCount
            return
        }
        publishPasteboardIfChanged(force: true)
    }

    func syncNow() {
        publishPasteboardIfChanged(force: true)
    }

    func startTemporarySharing() {
        guard canStartTemporarySharing else {
            return
        }

        setSharingEnabled(true)
        temporarySharingExpiresAt = Date().addingTimeInterval(30)
        onToast("Sharing clipboard for 30 seconds", "clock")
    }

    /// Called once a second: ends an expired temporary share and publishes
    /// local pasteboard changes.
    func poll(now: Date = Date()) {
        // A temporary share is always one that turned sharing on.
        if let temporarySharingExpiresAt, now >= temporarySharingExpiresAt {
            setSharingEnabled(false)
            onToast("Clipboard sharing ended", "doc.on.clipboard")
        }
        if canSync {
            publishPasteboardIfChanged()
        }
    }

    func receiveText(_ text: String) {
        guard isSharingEnabled else {
            return
        }
        cancelLocalFileRead()
        discardFileTransfer()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboardChangeCount = pasteboard.changeCount
        onToast("Remote text copied", "doc.on.clipboard")
    }

    func receiveFileList(_ descriptorList: RDPClipboardFileGroupDescriptorW) {
        guard isSharingEnabled else {
            return
        }
        discardFileTransfer()
        do {
            let files = try descriptorList.remoteFileTransferFiles(
                maximumTotalByteCount: UInt64(sessionMaximumLocalClipboardFileBytes)
            )
            let downloadDirectory = try makeDownloadDirectory()
            requestFileSize(SessionRemoteClipboardFileTransfer(
                files: files,
                streamID: makeStreamID(),
                downloadDirectory: downloadDirectory
            ))
        } catch let error as RDPClipboardRemoteFileTransferPlanningError {
            onToast(planningMessage(for: error), "exclamationmark.triangle")
        } catch {
            onToast("Remote files could not be prepared", "exclamationmark.triangle")
        }
    }

    func receiveFileContents(_ response: RDPClipboardFileContentsResponse) {
        guard isSharingEnabled,
              var transfer = fileTransfer,
              transfer.streamID == response.streamID
        else {
            return
        }
        // Taken out so the received bytes are appended in place.
        fileTransfer = nil
        guard response.ok else {
            failFileTransfer(transfer, message: "Remote file transfer failed")
            return
        }

        guard transfer.expectedByteCount != nil else {
            do {
                let byteCount = try response.decodedFileSize()
                guard byteCount <= UInt64(sessionMaximumLocalClipboardFileBytes),
                      transfer.totalExpectedByteCount <= UInt64(sessionMaximumLocalClipboardFileBytes) - byteCount
                else {
                    failFileTransfer(transfer, message: "Remote files exceed 32 MiB")
                    return
                }
                transfer.expectedByteCount = byteCount
                transfer.totalExpectedByteCount += byteCount
                continueFileTransfer(transfer)
            } catch {
                failFileTransfer(transfer, message: "Remote file size request failed")
            }
            return
        }

        // [MS-RDPECLIP] 2.2.5.4 does not promise all of a range in one
        // answer, and servers send less, so the rest is asked for again.
        // Nothing before the end, or more than was asked for, fails.
        guard response.data.isEmpty == false,
              response.data.count <= Int(transfer.requestedByteCount)
        else {
            failFileTransfer(transfer, message: "Remote file transfer was incomplete")
            return
        }
        transfer.receivedData.append(response.data)
        continueFileTransfer(transfer)
    }

    // MARK: - Local pasteboard

    private func publishPasteboardIfChanged(force: Bool = false) {
        guard isSharingEnabled, session != nil else {
            pasteboardChangeCount = pasteboard.changeCount
            return
        }

        let nextChangeCount = pasteboard.changeCount
        guard force || nextChangeCount != pasteboardChangeCount else {
            return
        }

        if nextChangeCount != pasteboardChangeCount {
            // A newer local copy replaces a remote one still downloading.
            discardFileTransfer()
        }
        pasteboardChangeCount = nextChangeCount
        cancelLocalFileRead()
        let fileURLs = pasteboardFileURLs()
        guard fileURLs.isEmpty else {
            // Reading up to 32 MiB, or a file iCloud has to download first,
            // on the main thread would stall the window and its input. A
            // newer local copy, remote clipboard, or sharing turned off
            // cancels the publish.
            localFileRead = Task { [weak self] in
                let payload = await Task.detached(priority: .userInitiated) {
                    Self.localFiles(from: fileURLs)
                }.value
                guard Task.isCancelled == false else {
                    return
                }
                self?.publish(payload, force: force)
            }
            return
        }
        publish(localTextPayload(), force: force)
    }

    private func publish(_ payload: SessionLocalClipboardPayload, force: Bool) {
        guard isSharingEnabled, let session else {
            return
        }
        switch payload {
        case let .text(text):
            session.publishLocalUnicodeText(text)
            if force {
                onToast("Clipboard synced", "doc.on.clipboard.fill")
            }
        case let .files(files):
            session.publishLocalFiles(files)
            let message = files.count == 1 ? "1 file shared to remote" : "\(files.count) files shared to remote"
            onToast(message, "doc.on.clipboard.fill")
        case .empty:
            session.publishLocalUnicodeText(nil)
        case let .unsupported(message):
            session.publishLocalUnicodeText(nil)
            onToast(message, "exclamationmark.triangle")
        case let .ignored(message):
            onToast(message, "exclamationmark.triangle")
        }
    }

    private func cancelLocalFileRead() {
        localFileRead?.cancel()
        localFileRead = nil
    }

    private func localTextPayload() -> SessionLocalClipboardPayload {
        if let text = pasteboard.string(forType: .string) {
            guard RDPClipboardLimits.canPublishUnicodeText(text) else {
                return .ignored("Local text is too large to sync.")
            }
            return .text(text)
        }
        return .empty
    }

    private func pasteboardFileURLs() -> [URL] {
        var urls: [URL] = []
        if let pasteboardItems = pasteboard.pasteboardItems {
            for item in pasteboardItems {
                appendFileURL(item.string(forType: .fileURL), to: &urls)
            }
        }
        if urls.isEmpty, pasteboard.types?.contains(.fileURL) == true {
            appendFileURL(pasteboard.string(forType: .fileURL), to: &urls)
        }
        return urls
    }

    private func appendFileURL(_ value: String?, to urls: inout [URL]) {
        guard let value,
              let url = URL(string: value),
              url.isFileURL,
              urls.contains(url) == false
        else {
            return
        }
        urls.append(url)
    }

    private nonisolated static func localFiles(from urls: [URL]) -> SessionLocalClipboardPayload {
        var files: [RDPClipboardLocalFile] = []
        var totalByteCount = 0

        for url in urls {
            let fileURL = url.standardizedFileURL
            let fileName = fileURL.lastPathComponent
            guard fileName.isEmpty == false else {
                return .unsupported("Local file clipboard was not shared.")
            }

            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resourceValues.isRegularFile == true else {
                    return .unsupported("Local clipboard has non-file items; remote clipboard cleared.")
                }

                guard let byteCount = resourceValues.fileSize,
                      byteCount >= 0
                else {
                    return .unsupported("Local file clipboard could not be read; remote clipboard cleared.")
                }
                guard byteCount <= sessionMaximumLocalClipboardFileBytes,
                      totalByteCount <= sessionMaximumLocalClipboardFileBytes - byteCount
                else {
                    return .unsupported("Local clipboard files exceed 32 MiB; remote clipboard cleared.")
                }

                let contents = try Data(contentsOf: fileURL)
                guard contents.count <= sessionMaximumLocalClipboardFileBytes,
                      totalByteCount <= sessionMaximumLocalClipboardFileBytes - contents.count
                else {
                    return .unsupported("Local clipboard files exceed 32 MiB; remote clipboard cleared.")
                }
                totalByteCount += contents.count
                files.append(RDPClipboardLocalFile(fileName: fileName, contents: contents))
            } catch {
                return .unsupported("Local file clipboard could not be read; remote clipboard cleared.")
            }
        }

        return files.isEmpty ? .empty : .files(files)
    }

    // MARK: - Remote file downloads

    /// Asks for the next range of the current file, or saves it once all of
    /// it has arrived.
    private func continueFileTransfer(_ transfer: SessionRemoteClipboardFileTransfer) {
        guard let currentFile = transfer.currentFile,
              let expectedByteCount = transfer.expectedByteCount
        else {
            failFileTransfer(transfer, message: "Remote file transfer failed")
            return
        }
        let receivedByteCount = UInt64(transfer.receivedData.count)
        guard receivedByteCount < expectedByteCount else {
            saveCurrentFile(currentFile, of: transfer)
            return
        }
        guard let session else {
            failFileTransfer(transfer, message: "Clipboard is not ready")
            return
        }

        var transfer = transfer
        transfer.requestedByteCount = UInt32(
            min(sessionMaximumFileRangeByteCount, expectedByteCount - receivedByteCount)
        )
        fileTransfer = transfer
        do {
            try session.requestRemoteFileRange(
                streamID: transfer.streamID,
                fileIndex: currentFile.fileIndex,
                position: receivedByteCount,
                requestedByteCount: transfer.requestedByteCount
            )
        } catch {
            failFileTransfer(transfer, message: "Remote file request failed")
        }
    }

    private func saveCurrentFile(
        _ currentFile: RDPClipboardRemoteFileTransferFile,
        of transfer: SessionRemoteClipboardFileTransfer
    ) {
        do {
            var nextTransfer = transfer
            let fileURL = try writeDownloadedFile(
                named: currentFile.fileName,
                contents: transfer.receivedData,
                in: transfer.downloadDirectory
            )
            nextTransfer.downloadedFileURLs.append(fileURL)

            guard nextTransfer.currentFileOffset + 1 < nextTransfer.files.count else {
                finishFileTransfer(nextTransfer)
                return
            }

            nextTransfer.currentFileOffset += 1
            nextTransfer.streamID = makeStreamID()
            nextTransfer.expectedByteCount = nil
            nextTransfer.receivedData = Data()
            requestFileSize(nextTransfer)
        } catch {
            failFileTransfer(transfer, message: "Remote file could not be saved")
        }
    }

    private func requestFileSize(_ transfer: SessionRemoteClipboardFileTransfer) {
        guard let session,
              let currentFile = transfer.currentFile
        else {
            failFileTransfer(transfer, message: "Clipboard is not ready")
            return
        }

        fileTransfer = transfer
        do {
            try session.requestRemoteFileSize(
                streamID: transfer.streamID,
                fileIndex: currentFile.fileIndex
            )
            let message = transfer.files.count == 1
                ? "Downloading \(currentFile.fileName)"
                : "Downloading file \(transfer.currentFileOffset + 1) of \(transfer.files.count)"
            onToast(message, "arrow.down.doc")
        } catch {
            failFileTransfer(transfer, message: "Remote file request failed")
        }
    }

    private func finishFileTransfer(_ transfer: SessionRemoteClipboardFileTransfer) {
        // A local copy made since the last poll is newer than the download,
        // so it stays.
        guard pasteboard.changeCount == pasteboardChangeCount else {
            try? FileManager.default.removeItem(at: transfer.downloadDirectory)
            fileTransfer = nil
            return
        }
        cancelLocalFileRead()
        pasteboard.clearContents()
        removeCopiedDownloadIfReplaced()
        guard pasteboard.writeObjects(transfer.downloadedFileURLs.map { $0 as NSURL }) else {
            failFileTransfer(transfer, message: "Remote files could not be copied")
            return
        }

        pasteboardChangeCount = pasteboard.changeCount
        copiedDownload = (transfer.downloadDirectory, pasteboardChangeCount)
        fileTransfer = nil
        if transfer.downloadedFileURLs.count == 1,
           let fileName = transfer.files.first?.fileName
        {
            onToast("Remote file copied: \(fileName)", "doc.on.clipboard")
        } else {
            onToast("\(transfer.downloadedFileURLs.count) remote files copied", "doc.on.clipboard")
        }
    }

    private func failFileTransfer(_ transfer: SessionRemoteClipboardFileTransfer, message: String) {
        try? FileManager.default.removeItem(at: transfer.downloadDirectory)
        fileTransfer = nil
        onToast(message, "exclamationmark.triangle")
    }

    private func planningMessage(for error: RDPClipboardRemoteFileTransferPlanningError) -> String {
        switch error {
        case .emptyFileList:
            "Remote file clipboard is empty"
        case .containsOnlyDirectories:
            "Remote clipboard has folders; file copy is not ready"
        case .invalidFileIndex:
            "Remote file index is not valid"
        case .totalByteLimitExceeded:
            "Remote files exceed 32 MiB"
        }
    }

    private func discardFileTransfer() {
        guard let fileTransfer else {
            return
        }
        try? FileManager.default.removeItem(at: fileTransfer.downloadDirectory)
        self.fileTransfer = nil
    }

    /// Removes the last download put on the pasteboard once something else
    /// has replaced it there.
    private func removeCopiedDownloadIfReplaced() {
        guard let copiedDownload,
              pasteboard.changeCount != copiedDownload.changeCount
        else {
            return
        }
        try? FileManager.default.removeItem(at: copiedDownload.directory)
        self.copiedDownload = nil
    }

    /// Removes what earlier runs left behind: downloads a crash cut short,
    /// and ones still on the pasteboard at quit. Telling whether the
    /// pasteboard holds one would mean reading its contents, which a session
    /// that does not share must not do, so while the pasteboard holds any
    /// files they are left for a later run.
    private func removeEarlierDownloads() {
        guard pasteboard.types?.contains(.fileURL) != true else {
            return
        }
        try? FileManager.default.removeItem(at: downloadRoot)
    }

    /// A new directory for each download, so the files of the previous one
    /// stay on the pasteboard until this one replaces them.
    private func makeDownloadDirectory() throws -> URL {
        let directory = downloadRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeDownloadedFile(named fileName: String, contents: Data, in directory: URL) throws -> URL {
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        try contents.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func makeStreamID() -> UInt32 {
        let streamID = nextStreamID
        nextStreamID = streamID == UInt32.max ? 1 : streamID + 1
        return streamID
    }
}

private enum SessionLocalClipboardPayload: Sendable {
    case text(String)
    case files([RDPClipboardLocalFile])
    case empty
    case unsupported(String)
    case ignored(String)
}

private struct SessionRemoteClipboardFileTransfer {
    var files: [RDPClipboardRemoteFileTransferFile]
    var currentFileOffset = 0
    var streamID: UInt32
    /// Nil until the server answers the size request.
    var expectedByteCount: UInt64?
    /// The current file's bytes so far.
    var receivedData = Data()
    /// What the outstanding FILECONTENTS_RANGE request asked for.
    var requestedByteCount: UInt32 = 0
    var totalExpectedByteCount: UInt64 = 0
    var downloadedFileURLs: [URL] = []
    var downloadDirectory: URL

    var currentFile: RDPClipboardRemoteFileTransferFile? {
        guard files.indices.contains(currentFileOffset) else {
            return nil
        }
        return files[currentFileOffset]
    }
}
