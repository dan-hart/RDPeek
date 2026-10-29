import Foundation
import RDPKit

enum DeviceSortOrder: String, CaseIterable, Identifiable {
    case byName
    case byRecent

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .byName:
            "Name"
        case .byRecent:
            "Recently Used"
        }
    }
}

/// What the editor sheet is working on: a fresh device or an existing one.
struct DeviceEditorState: Identifiable {
    var device: DeviceProfile
    var isNew: Bool

    var id: UUID {
        device.id
    }
}

@MainActor
final class DeviceListModel: ObservableObject {
    private let store: DeviceProfileStore
    private let credentialStore: any CredentialStoring
    private let credentialCache: InMemoryCredentialCache
    private let defaults: UserDefaults

    @Published private(set) var devices: [DeviceProfile] = []
    @Published var searchText = ""
    @Published var editorState: DeviceEditorState?
    @Published var devicePendingDeletion: DeviceProfile?
    @Published var errorMessage: String?
    /// How many saved PCs this version cannot read, counted at launch. They
    /// stay in storage unchanged; the Connection Center says so until the
    /// notice is dismissed, which zeroes this for the rest of the run.
    @Published private(set) var unreadableDeviceCount = 0
    @Published var sortOrder: DeviceSortOrder {
        didSet {
            defaults.set(sortOrder.rawValue, forKey: "device-sort-order")
        }
    }

    init(
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        credentialCache: InMemoryCredentialCache = .shared,
        defaults: UserDefaults = .standard
    ) {
        store = DeviceProfileStore(defaults: defaults)
        self.credentialStore = credentialStore
        self.credentialCache = credentialCache
        self.defaults = defaults
        let storedSortOrder = defaults.string(forKey: "device-sort-order")
        sortOrder = storedSortOrder.flatMap(DeviceSortOrder.init(rawValue:)) ?? .byName
        do {
            let stored = try store.load()
            devices = stored.devices
            unreadableDeviceCount = stored.unreadableCount
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func dismissUnreadableDeviceNotice() {
        unreadableDeviceCount = 0
    }

    var filteredDevices: [DeviceProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = devices
        if query.isEmpty == false {
            result = result.filter { device in
                device.displayName.localizedCaseInsensitiveContains(query)
                    || device.host.localizedCaseInsensitiveContains(query)
                    || device.username.localizedCaseInsensitiveContains(query)
            }
        }
        switch sortOrder {
        case .byName:
            return result
        case .byRecent:
            return result.sorted { lhs, rhs in
                switch (lhs.lastConnectedAt, rhs.lastConnectedAt) {
                case let (lhsDate?, rhsDate?):
                    lhsDate > rhsDate
                case (.some, nil):
                    true
                case (nil, .some):
                    false
                case (nil, nil):
                    lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            }
        }
    }

    // MARK: - Editing

    func addNewDevice() {
        // ⌘N stays enabled while the editor is open; replacing the state
        // would dismiss the sheet and discard the edit in progress.
        guard editorState == nil else {
            return
        }
        editorState = DeviceEditorState(device: .makeNew(defaults: defaults), isNew: true)
    }

    /// Opens the editor at once; the sheet loads the saved password itself
    /// through `savedPassword(for:)`.
    func edit(_ device: DeviceProfile) {
        editorState = DeviceEditorState(device: device, isNew: false)
    }

    /// The device's remembered password, or nil when it has none or the
    /// keychain read fails. The read runs off the main actor: it can block
    /// on the access-approval dialog.
    func savedPassword(for device: DeviceProfile) async -> String? {
        guard device.rememberPassword,
              let key = KeychainCredentialKey(identity: device.identity)
        else {
            return nil
        }
        let credentialStore = credentialStore
        return await Task.detached(priority: .userInitiated) {
            try? credentialStore.password(for: key)
        }.value
    }

    func duplicate(_ device: DeviceProfile) {
        var copy = device
        copy.id = UUID()
        copy.name = device.displayName + " Copy"
        copy.accentHue = Double.random(in: 0 ..< 1)
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.lastConnectedAt = nil
        // rememberPassword carries over: the copy has the same identity, so
        // it signs in with the same keychain entry.
        do {
            devices = try store.save(copy)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Persists the edited device and applies any keychain change.
    /// `editor.device` must remain the snapshot from sheet-open time — the
    /// stale-keychain-entry cleanup compares against its original identity,
    /// and the Remember toggle counts as untouched while the edited flag
    /// still matches the snapshot's.
    /// `hadRememberedPassword` says whether the editor found a saved
    /// password for that identity.
    func save(
        editor: DeviceEditorState,
        editedDevice: DeviceProfile,
        password: String,
        hadRememberedPassword: Bool
    ) throws -> DeviceProfile {
        var device = editedDevice
        let target = try RDPConnectionTarget(host: device.host, portText: String(device.port))
        device.host = target.host
        device.name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        device.username = device.username.trimmingCharacters(in: .whitespacesAndNewlines)
        device.domain = device.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        device.updatedAt = Date()

        // The editor works on a snapshot from sheet-open time; a session may
        // have connected since, so carry the store's timestamp over instead
        // of reverting it. Reading first also stops an unreadable store
        // before any keychain change.
        let current = try store.devices().first { $0.id == device.id }
        if let current {
            device.lastConnectedAt = current.lastConnectedAt
        }

        // A session's sign-in may also have turned Remember on or off since,
        // saving or deleting the keychain item itself. When the user left the
        // toggle alone and the identity is unchanged, that newer choice
        // stands and the keychain is already right: writing the snapshot's
        // flag back would orphan the item or re-save an old password.
        let keepsSessionRemember = current.map {
            device.rememberPassword == editor.device.rememberPassword
                && $0.rememberPassword != device.rememberPassword
                && editor.device.identity.hasSameConnectionIdentity(as: device.identity)
        } ?? false
        if let current, keepsSessionRemember {
            device.rememberPassword = current.rememberPassword
        } else {
            try applyKeychainChange(
                from: editor.device,
                to: device,
                password: password,
                hadRememberedPassword: hadRememberedPassword
            )
        }

        // Keep the password for this app run too, so this PC connects
        // without asking when it does not remember it, and so do others
        // with the same sign-in that do not. One the sheet loaded from the
        // keychain is older than the one a session that changed Remember
        // since has kept.
        if password.isEmpty == false,
           keepsSessionRemember == false || hadRememberedPassword == false,
           let account = device.identity.credentialAccountName
        {
            credentialCache.setPassword(password, for: account)
        }

        devices = try store.save(device)
        return device
    }

    /// Checks that the editor's Remember choice can be kept, then saves or
    /// deletes keychain entries to match it.
    private func applyKeychainChange(
        from snapshot: DeviceProfile,
        to device: DeviceProfile,
        password: String,
        hadRememberedPassword: Bool
    ) throws {
        if device.rememberPassword, device.username.isEmpty {
            throw DeviceValidationError.missingUsernameForKeychain
        }
        if device.rememberPassword, password.isEmpty {
            throw DeviceValidationError.missingPasswordForKeychain
        }

        // The keychain entry is keyed by identity, so drop the old entry when
        // host, port, username, or domain changed — unless another profile
        // still remembers its password under that identity.
        if hadRememberedPassword,
           snapshot.identity.hasSameConnectionIdentity(as: device.identity) == false,
           rememberedPasswordIsShared(snapshot.identity, excluding: device.id) == false,
           let oldKey = KeychainCredentialKey(identity: snapshot.identity)
        {
            try credentialStore.deletePassword(for: oldKey)
        }

        if let key = KeychainCredentialKey(identity: device.identity) {
            if device.rememberPassword {
                try credentialStore.savePassword(password, for: key)
            } else if hadRememberedPassword,
                      rememberedPasswordIsShared(device.identity, excluding: device.id) == false
            {
                try credentialStore.deletePassword(for: key)
            }
        }
    }

    func requestDeletion(of device: DeviceProfile) {
        devicePendingDeletion = device
    }

    func confirmDeletion(of device: DeviceProfile) {
        do {
            // Delete the profile first: if the store write throws, nothing
            // irreversible has happened to the keychain yet.
            devices = try store.delete(id: device.id)
            // Profiles for the same machine share one cached password and
            // one keychain entry; keep each while another profile uses it.
            let twins = devices.filter { $0.identity.hasSameConnectionIdentity(as: device.identity) }
            if twins.isEmpty, let account = device.identity.credentialAccountName {
                credentialCache.removePassword(for: account)
            }
            // The confirmation dialog promises the saved password is removed
            // too, so a failure must surface, not be swallowed.
            if twins.contains(where: \.rememberPassword) == false,
               let key = KeychainCredentialKey(identity: device.identity)
            {
                try credentialStore.deletePassword(for: key)
            }
        } catch {
            errorMessage = String(describing: error)
        }
        devicePendingDeletion = nil
    }

    /// Whether another profile remembers its password under `identity`, and
    /// so still needs the keychain entry. Profiles that don't remember their
    /// password never read it.
    func rememberedPasswordIsShared(_ identity: RDPConnectionIdentity, excluding deviceID: UUID) -> Bool {
        devices.contains { other in
            other.id != deviceID
                && other.rememberPassword
                && other.identity.hasSameConnectionIdentity(as: identity)
        }
    }

    // MARK: - Connecting

    func connect(_ device: DeviceProfile, using launchStore: any RemoteSessionOpening) {
        // No password here: the session window resolves it — the keychain
        // when the profile remembers one, then this run's cache, then the
        // sign-in prompt — off the main thread, since the keychain read can
        // block on the access-approval dialog.
        launchStore.openRemoteSession(RDPConnectionDraft(device: device))
    }

    func touchLastConnected(deviceID: UUID) {
        do {
            devices = try store.touchLastConnected(id: deviceID)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Keeps the profile's remember-password flag in sync when a session
    /// saves or deletes the keychain credential via the in-session prompt.
    /// Ignored when the session signed in under a different identity than
    /// the profile — that credential is not the profile's saved password.
    func recordCredentialPersistence(deviceID: UUID, identity: RDPConnectionIdentity, remembered: Bool) {
        guard var device = devices.first(where: { $0.id == deviceID }),
              device.identity.hasSameConnectionIdentity(as: identity),
              device.rememberPassword != remembered
        else {
            return
        }
        device.rememberPassword = remembered
        device.updatedAt = Date()
        do {
            devices = try store.save(device)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

enum DeviceValidationError: Error, CustomStringConvertible {
    case missingUsernameForKeychain
    case missingPasswordForKeychain

    var description: String {
        switch self {
        case .missingUsernameForKeychain:
            "A username is required to remember the password in Keychain."
        case .missingPasswordForKeychain:
            "Enter a password to remember, or turn off Remember Password."
        }
    }
}
