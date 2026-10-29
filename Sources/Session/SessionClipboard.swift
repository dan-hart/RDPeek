import AppKit
import RDPKit

private let sessionMaximumLocalClipboardFileBytes = 32 * 1024 * 1024

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
    private var pasteboardChangeCount = NSPasteboard.general.changeCount
    private var temporarySharingExpiresAt: Date?
    private var fileTransfer: SessionRemoteClipboardFileTransfer?
    private var downloadDirectory: URL?
    private var nextStreamID: UInt32 = 1

    init(isSharingEnabled: Bool) {
        self.isSharingEnabled = isSharingEnabled
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
    /// stop talking to it, and drops any download in flight.
    func detach() {
        session = nil
        discardFileTransfer()
        pasteboardChangeCount = NSPasteboard.general.changeCount
    }

    /// The user's choice, which also ends a temporary share.
    func setSharingEnabled(_ enabled: Bool) {
        isSharingEnabled = enabled
        temporarySharingExpiresAt = nil
        applySharing(enabled)
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
        if let temporarySharingExpiresAt, now >= temporarySharingExpiresAt {
            self.temporarySharingExpiresAt = nil
            if isSharingEnabled {
                isSharingEnabled = false
                applySharing(false)
                onToast("Clipboard sharing ended", "doc.on.clipboard")
            }
        }
        if canSync {
            publishPasteboardIfChanged()
        }
    }

    func receiveText(_ text: String) {
        guard isSharingEnabled else {
            return
        }
        let pasteboard = NSPasteboard.general
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
                currentFileOffset: 0,
                streamID: makeStreamID(),
                expectedByteCount: nil,
                requestedRange: false,
                totalExpectedByteCount: 0,
                downloadedFileURLs: [],
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
        guard response.ok else {
            failFileTransfer(transfer, message: "Remote file transfer failed")
            return
        }

        if transfer.requestedRange {
            receiveFileData(response.data, transfer: transfer)
            return
        }

        do {
            let byteCount = try response.decodedFileSize()
            guard byteCount <= UInt64(sessionMaximumLocalClipboardFileBytes),
                  transfer.totalExpectedByteCount <= UInt64(sessionMaximumLocalClipboardFileBytes) - byteCount,
                  let requestedByteCount = UInt32(exactly: byteCount)
            else {
                failFileTransfer(transfer, message: "Remote files exceed 32 MiB")
                return
            }

            guard let session else {
                failFileTransfer(transfer, message: "Clipboard is not ready")
                return
            }

            transfer.expectedByteCount = byteCount
            transfer.totalExpectedByteCount += byteCount
            if byteCount == 0 {
                fileTransfer = transfer
                receiveFileData(Data(), transfer: transfer)
                return
            }

            transfer.requestedRange = true
            fileTransfer = transfer
            guard let currentFile = transfer.currentFile else {
                failFileTransfer(transfer, message: "Remote file transfer failed")
                return
            }
            try session.requestRemoteFileRange(
                streamID: transfer.streamID,
                fileIndex: currentFile.fileIndex,
                position: 0,
                requestedByteCount: requestedByteCount
            )
        } catch {
            failFileTransfer(transfer, message: "Remote file size request failed")
        }
    }

    // MARK: - Local pasteboard

    private func applySharing(_ enabled: Bool) {
        guard enabled else {
            temporarySharingExpiresAt = nil
            discardFileTransfer()
            session?.publishLocalUnicodeText(nil)
            pasteboardChangeCount = NSPasteboard.general.changeCount
            return
        }
        publishPasteboardIfChanged(force: true)
    }

    private func publishPasteboardIfChanged(force: Bool = false) {
        guard isSharingEnabled else {
            pasteboardChangeCount = NSPasteboard.general.changeCount
            return
        }
        guard let session else {
            pasteboardChangeCount = NSPasteboard.general.changeCount
            return
        }

        let pasteboard = NSPasteboard.general
        let nextChangeCount = pasteboard.changeCount
        guard force || nextChangeCount != pasteboardChangeCount else {
            return
        }

        pasteboardChangeCount = nextChangeCount
        switch localPayload(from: pasteboard) {
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

    private func localPayload(from pasteboard: NSPasteboard) -> SessionLocalClipboardPayload {
        let fileURLs = pasteboardFileURLs(from: pasteboard)
        if fileURLs.isEmpty == false {
            return localFiles(from: fileURLs)
        }
        if let text = pasteboard.string(forType: .string) {
            guard RDPClipboardLimits.canPublishUnicodeText(text) else {
                return .ignored("Local text is too large to sync.")
            }
            return .text(text)
        }
        return .empty
    }

    private func pasteboardFileURLs(from pasteboard: NSPasteboard) -> [URL] {
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

    private func localFiles(from urls: [URL]) -> SessionLocalClipboardPayload {
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

    private func receiveFileData(_ data: Data, transfer: SessionRemoteClipboardFileTransfer) {
        guard let currentFile = transfer.currentFile,
              transfer.expectedByteCount == UInt64(data.count),
              data.count <= sessionMaximumLocalClipboardFileBytes
        else {
            failFileTransfer(transfer, message: "Remote file transfer was incomplete")
            return
        }

        do {
            var nextTransfer = transfer
            let fileURL = try writeDownloadedFile(
                named: currentFile.fileName,
                contents: data,
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
            nextTransfer.requestedRange = false
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(transfer.downloadedFileURLs.map { $0 as NSURL }) else {
            failFileTransfer(transfer, message: "Remote files could not be copied")
            return
        }

        pasteboardChangeCount = pasteboard.changeCount
        fileTransfer = nil
        if transfer.downloadedFileURLs.count == 1,
           let fileName = transfer.files.first?.fileName
        {
            onToast("Remote file copied: \(fileName)", "doc.on.clipboard")
        } else {
            onToast("\(transfer.downloadedFileURLs.count) remote files copied", "doc.on.clipboard")
        }
    }

    private func failFileTransfer(_ transfer: SessionRemoteClipboardFileTransfer?, message: String) {
        if let directory = transfer?.downloadDirectory {
            try? FileManager.default.removeItem(at: directory)
            if downloadDirectory == directory {
                downloadDirectory = nil
            }
        }
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
        guard let transfer = fileTransfer else {
            return
        }
        try? FileManager.default.removeItem(at: transfer.downloadDirectory)
        if downloadDirectory == transfer.downloadDirectory {
            downloadDirectory = nil
        }
        fileTransfer = nil
    }

    /// Replaces the previous download directory; files from the last completed
    /// transfer stay on the pasteboard until the next transfer starts.
    private func makeDownloadDirectory() throws -> URL {
        let fileManager = FileManager.default
        if let downloadDirectory {
            try? fileManager.removeItem(at: downloadDirectory)
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("RDPeekRemoteClipboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        downloadDirectory = directory
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

private enum SessionLocalClipboardPayload: Equatable {
    case text(String)
    case files([RDPClipboardLocalFile])
    case empty
    case unsupported(String)
    case ignored(String)
}

private struct SessionRemoteClipboardFileTransfer: Equatable {
    var files: [RDPClipboardRemoteFileTransferFile]
    var currentFileOffset: Int
    var streamID: UInt32
    var expectedByteCount: UInt64?
    var requestedRange: Bool
    var totalExpectedByteCount: UInt64
    var downloadedFileURLs: [URL]
    var downloadDirectory: URL

    var currentFile: RDPClipboardRemoteFileTransferFile? {
        guard files.indices.contains(currentFileOffset) else {
            return nil
        }
        return files[currentFileOffset]
    }
}
