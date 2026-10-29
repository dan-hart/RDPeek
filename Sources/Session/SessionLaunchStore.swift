import AppKit
import Foundation
import RDPKit
import SwiftUI

/// Opens and tracks remote session windows and their diagnostics windows.
@MainActor
final class SessionLaunchStore: ObservableObject, RemoteSessionOpening {
    /// Command state of the key session window, published while it is key
    /// and nil while no session window is; drives the contextual Session
    /// menu in the menu bar.
    @Published private(set) var keySessionCommands: SessionCommandState?

    var isSessionWindowKey: Bool {
        keySessionCommands != nil
    }

    func updateKeySessionCommands(_ state: SessionCommandState?) {
        if keySessionCommands != state {
            keySessionCommands = state
        }
    }

    private var sessionWindowControllers: [UUID: SessionWindowController] = [:]
    private var diagnosticsWindowControllers: [UUID: DiagnosticsWindowController] = [:]
    private var diagnosticsModels: [UUID: RemoteSessionDiagnosticsModel] = [:]

    /// Called when a connection attempt starts, so the device list can record
    /// the most recent connection.
    var onConnectionStart: ((UUID) -> Void)?

    /// Called when a session saved or deleted a keychain credential, so the
    /// profile's remember-password flag stays truthful. Carries the identity
    /// the credential was stored under: the sign-in overlay can use a
    /// different username than the profile, and only a matching profile may
    /// have its flag updated.
    var onCredentialPersistence: ((UUID, RDPConnectionIdentity, _ remembered: Bool) -> Void)?

    /// Opens a session window for the draft, or focuses the existing window if
    /// this device already has one.
    func openRemoteSession(_ draft: RDPConnectionDraft) {
        if let existing = sessionWindowControllers.values.first(where: { $0.deviceID == draft.deviceID }) {
            existing.showWindow(nil)
            return
        }

        let id = UUID()
        let preferredScreen = NSApp.keyWindow?.screen ?? NSScreen.main
        let controller = SessionWindowController(
            sessionID: id,
            draft: draft,
            launchStore: self,
            preferredScreen: preferredScreen
        )
        controller.onClose = { [weak self] sessionID in
            self?.sessionWindowControllers.removeValue(forKey: sessionID)
        }
        sessionWindowControllers[id] = controller
        controller.showWindow(nil)
    }

    func recordConnectionStart(for deviceID: UUID) {
        onConnectionStart?(deviceID)
    }

    func recordCredentialPersistence(for deviceID: UUID, identity: RDPConnectionIdentity, remembered: Bool) {
        onCredentialPersistence?(deviceID, identity, remembered)
    }

    func registerDiagnostics(_ model: RemoteSessionDiagnosticsModel, for id: UUID) {
        diagnosticsModels[id] = model
    }

    func openDiagnostics(for id: UUID) {
        if let controller = diagnosticsWindowControllers[id] {
            controller.showWindow(nil)
            return
        }

        guard let model = diagnosticsModels[id] else {
            return
        }

        let controller = DiagnosticsWindowController(
            sessionID: id,
            title: model.snapshot.title,
            model: model
        )
        controller.onClose = { [weak self] sessionID in
            self?.diagnosticsWindowControllers.removeValue(forKey: sessionID)
        }
        diagnosticsWindowControllers[id] = controller
        controller.showWindow(nil)
    }

    func unregisterDiagnostics(for id: UUID) {
        diagnosticsModels.removeValue(forKey: id)
        diagnosticsWindowControllers.removeValue(forKey: id)?.close()
    }
}
