import Foundation
import RDPKit
import XCTest

@MainActor
final class DeviceListModelTests: XCTestCase {
    private struct Harness {
        let model: DeviceListModel
        let credentials: CredentialStoreRecorder
        let cache: InMemoryCredentialCache
        let defaults: UserDefaults
    }

    // MARK: - init

    func testInitSurfacesUnreadableStore() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: "device-profiles.v1")

        let model = DeviceListModel(
            credentialStore: CredentialStoreRecorder(),
            credentialCache: InMemoryCredentialCache(),
            defaults: defaults
        )

        XCTAssertEqual(model.devices, [])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.unreadableDeviceCount, 0)
    }

    func testInitCountsSavedPCsItCannotReadUntilNoticeIsDismissed() throws {
        let defaults = try makeIsolatedDefaults()
        let readableID = UUID()
        defaults.set(Data("""
        [{"id": "\(readableID.uuidString)", "host": "desk.example"},
         {"id": "not-a-uuid", "host": "damaged.example"},
         {"host": "no-id.example"}]
        """.utf8), forKey: "device-profiles.v1")

        let model = DeviceListModel(
            credentialStore: CredentialStoreRecorder(),
            credentialCache: InMemoryCredentialCache(),
            defaults: defaults
        )

        XCTAssertEqual(model.devices.map(\.id), [readableID])
        XCTAssertEqual(model.unreadableDeviceCount, 2)
        XCTAssertNil(model.errorMessage)

        model.dismissUnreadableDeviceNotice()

        XCTAssertEqual(model.unreadableDeviceCount, 0)
        XCTAssertEqual(
            try DeviceProfileStore(defaults: defaults).load().unreadableCount,
            2,
            "Dismissing the notice must leave the unreadable PCs stored"
        )
    }

    func testInitWithReadableStoreCountsNoUnreadablePCs() throws {
        let harness = try makeHarness(devices: [makeDevice()])

        XCTAssertEqual(harness.model.unreadableDeviceCount, 0)
    }

    // MARK: - confirmDeletion

    func testConfirmDeletionKeepsCredentialSharedWithRememberingProfile() throws {
        let device = makeDevice(name: "Work PC", rememberPassword: true)
        let twin = makeDevice(name: "Work PC via VPN", rememberPassword: true)
        let harness = try makeHarness(devices: [device, twin])
        let account = try account(for: device)
        harness.cache.setPassword("cached", for: account)

        harness.model.confirmDeletion(of: device)

        XCTAssertEqual(harness.model.devices.map(\.id), [twin.id])
        XCTAssertEqual(harness.credentials.deletedAccounts, [])
        XCTAssertEqual(harness.cache.password(for: account), "cached")
        XCTAssertNil(harness.model.errorMessage)
        XCTAssertNil(harness.model.devicePendingDeletion)
    }

    func testConfirmDeletionRemovesCredentialButKeepsCacheForTwinThatDoesNotRemember() throws {
        let device = makeDevice(name: "Work PC", rememberPassword: true)
        let twin = makeDevice(name: "Work PC via VPN")
        let harness = try makeHarness(devices: [device, twin])
        let account = try account(for: device)
        harness.cache.setPassword("cached", for: account)

        harness.model.confirmDeletion(of: device)

        XCTAssertEqual(harness.credentials.deletedAccounts, [account])
        XCTAssertEqual(harness.cache.password(for: account), "cached")
        XCTAssertNil(harness.model.errorMessage)
    }

    func testConfirmDeletionRemovesCredentialAndCacheEntryWhenUnshared() throws {
        let device = makeDevice(name: "Work PC")
        let other = makeDevice(name: "Other PC", host: "other.example")
        let harness = try makeHarness(devices: [device, other])
        let account = try account(for: device)
        harness.credentials.passwords[account] = "secret"
        harness.cache.setPassword("cached", for: account)

        harness.model.confirmDeletion(of: device)

        XCTAssertEqual(harness.model.devices.map(\.id), [other.id])
        XCTAssertEqual(harness.credentials.deletedAccounts, [account])
        XCTAssertNil(harness.cache.password(for: account))
        XCTAssertNil(harness.model.errorMessage)
    }

    func testConfirmDeletionKeepsCredentialOfAnotherIdentityWithTheSameAccount() throws {
        // Different identities, one keychain account, CORP\bob@host.example:3389.
        let device = makeDevice(name: "Work PC", username: "CORP\\bob", rememberPassword: true)
        let twin = makeDevice(name: "Work PC Too", username: "bob", domain: "CORP", rememberPassword: true)
        let harness = try makeHarness(devices: [device, twin])
        let account = try account(for: device)
        XCTAssertEqual(account, try self.account(for: twin))
        harness.cache.setPassword("cached", for: account)

        harness.model.confirmDeletion(of: device)

        XCTAssertEqual(harness.credentials.deletedAccounts, [])
        XCTAssertEqual(harness.cache.password(for: account), "cached")
        XCTAssertNil(harness.model.errorMessage)
    }

    func testConfirmDeletionLeavesKeychainUntouchedWhenProfileDeleteFails() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        let account = try account(for: device)
        harness.cache.setPassword("cached", for: account)
        // Corrupt the profile blob after the model loaded, so the store's
        // read-modify-write throws before anything irreversible happens.
        harness.defaults.set(Data("not json".utf8), forKey: "device-profiles.v1")

        harness.model.confirmDeletion(of: device)

        XCTAssertNotNil(harness.model.errorMessage)
        XCTAssertEqual(harness.credentials.deletedAccounts, [])
        XCTAssertEqual(harness.cache.password(for: account), "cached")
        XCTAssertNil(harness.model.devicePendingDeletion)
    }

    func testConfirmDeletionSurfacesKeychainDeleteFailure() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        harness.credentials.deleteError = KeychainError.unexpectedStatus(-1)

        harness.model.confirmDeletion(of: device)

        XCTAssertEqual(harness.model.devices, [])
        XCTAssertEqual(harness.credentials.deletedAccounts, [try account(for: device)])
        XCTAssertNotNil(harness.model.errorMessage)
    }

    // MARK: - save(editor:editedDevice:password:hadRememberedPassword:)

    func testSaveDeletesStaleCredentialWhenIdentityChanges() throws {
        let device = makeDevice(host: "old.example", rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.host = "new.example"

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "pw",
            hadRememberedPassword: true
        )

        XCTAssertEqual(harness.credentials.deletedAccounts, [try account(for: device)])
        XCTAssertEqual(harness.credentials.savedAccounts, [try account(for: edited)])
    }

    func testSaveKeepsOldCredentialWhenSavingTheNewOneFails() throws {
        let device = makeDevice(host: "old.example", rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        let oldAccount = try account(for: device)
        harness.credentials.passwords[oldAccount] = "pw"
        harness.credentials.saveError = KeychainError.unexpectedStatus(-1)
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.host = "new.example"

        XCTAssertThrowsError(
            try harness.model.save(
                editor: editor,
                editedDevice: edited,
                password: "pw",
                hadRememberedPassword: true
            )
        )

        XCTAssertEqual(harness.credentials.deletedAccounts, [])
        XCTAssertEqual(harness.credentials.passwords[oldAccount], "pw")
        XCTAssertEqual(try DeviceProfileStore(defaults: harness.defaults).devices().first?.host, "old.example")
    }

    func testSaveKeepsStaleCredentialSharedWithRememberingDevice() throws {
        let device = makeDevice(host: "shared.example", rememberPassword: true)
        let twin = makeDevice(name: "Twin", host: "shared.example", rememberPassword: true)
        let harness = try makeHarness(devices: [device, twin])
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.host = "new.example"

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "pw",
            hadRememberedPassword: true
        )

        XCTAssertEqual(harness.credentials.deletedAccounts, [])
        XCTAssertEqual(harness.credentials.savedAccounts, [try account(for: edited)])
    }

    func testSaveDeletesStaleCredentialWhenTwinDoesNotRemember() throws {
        let device = makeDevice(host: "shared.example", rememberPassword: true)
        let twin = makeDevice(name: "Twin", host: "shared.example")
        let harness = try makeHarness(devices: [device, twin])
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.host = "new.example"

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "pw",
            hadRememberedPassword: true
        )

        XCTAssertEqual(harness.credentials.deletedAccounts, [try account(for: device)])
    }

    func testSaveWithUnchangedIdentityDeletesNothing() throws {
        let device = makeDevice(rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.name = "Renamed"

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "pw",
            hadRememberedPassword: true
        )

        XCTAssertEqual(harness.credentials.deletedAccounts, [])
        XCTAssertEqual(harness.credentials.savedAccounts, [try account(for: device)])
    }

    func testSaveDeletesCredentialWhenRememberTurnedOff() throws {
        let device = makeDevice(rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.rememberPassword = false

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "",
            hadRememberedPassword: true
        )

        XCTAssertEqual(harness.credentials.deletedAccounts, [try account(for: device)])
        XCTAssertEqual(harness.credentials.savedAccounts, [])
    }

    func testSaveKeepsCredentialWhenRememberTurnedOffButTwinRemembers() throws {
        let device = makeDevice(rememberPassword: true)
        let twin = makeDevice(name: "Twin", rememberPassword: true)
        let harness = try makeHarness(devices: [device, twin])
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.rememberPassword = false

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "",
            hadRememberedPassword: true
        )

        XCTAssertEqual(harness.credentials.deletedAccounts, [])
    }

    func testSaveKeepsCredentialWhenRememberTurnedOffButSameAccountRemembers() throws {
        let device = makeDevice(username: "CORP\\bob", rememberPassword: true)
        let twin = makeDevice(name: "Twin", username: "bob", domain: "CORP", rememberPassword: true)
        let harness = try makeHarness(devices: [device, twin])
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.rememberPassword = false

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "",
            hadRememberedPassword: true
        )

        XCTAssertEqual(harness.credentials.deletedAccounts, [])
    }

    func testSaveKeepsCredentialWhenIdentityChangesButAccountDoesNot() throws {
        let device = makeDevice(username: "CORP\\bob", rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.username = "bob"
        edited.domain = "CORP"

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "pw",
            hadRememberedPassword: true
        )

        XCTAssertEqual(harness.credentials.deletedAccounts, [])
        XCTAssertEqual(harness.credentials.passwords[try account(for: device)], "pw")
    }

    func testSaveCachesTypedPasswordWhenNotRemembered() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)

        _ = try harness.model.save(
            editor: editor,
            editedDevice: device,
            password: "typed",
            hadRememberedPassword: false
        )

        XCTAssertEqual(harness.cache.password(for: try account(for: device)), "typed")
        XCTAssertEqual(harness.credentials.savedAccounts, [])
        XCTAssertEqual(harness.credentials.deletedAccounts, [])
    }

    func testSaveWithRememberReplacesCachedPassword() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        let account = try account(for: device)
        harness.cache.setPassword("stale", for: account)
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.rememberPassword = true

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "new",
            hadRememberedPassword: false
        )

        XCTAssertEqual(harness.credentials.passwords[account], "new")
        XCTAssertEqual(harness.cache.password(for: account), "new")
    }

    func testSaveKeepsStoreLastConnectedAtOverEditorSnapshot() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        // A session connected after the editor sheet opened on its snapshot.
        let connectedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        try DeviceProfileStore(defaults: harness.defaults).touchLastConnected(id: device.id, at: connectedAt)
        let editor = DeviceEditorState(device: device, isNew: false)
        var edited = device
        edited.name = "Renamed"

        let saved = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "",
            hadRememberedPassword: false
        )

        XCTAssertEqual(saved.lastConnectedAt, connectedAt)
        XCTAssertEqual(harness.model.devices.first?.lastConnectedAt, connectedAt)
    }

    func testSaveRequiresUsernameAndPasswordToRemember() throws {
        let device = makeDevice(rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)
        var missingUsername = device
        missingUsername.username = ""

        XCTAssertThrowsError(
            try harness.model.save(
                editor: editor,
                editedDevice: missingUsername,
                password: "pw",
                hadRememberedPassword: false
            )
        )
        XCTAssertThrowsError(
            try harness.model.save(
                editor: editor,
                editedDevice: device,
                password: "",
                hadRememberedPassword: false
            )
        )
        XCTAssertEqual(harness.credentials.savedAccounts, [])
    }

    func testSaveKeepsRememberThatASessionTurnedOnWhileEditing() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)
        // After the sheet opened, a session's sign-in saved the password.
        let account = try account(for: device)
        harness.credentials.passwords[account] = "from-session"
        harness.model.recordCredentialPersistence(deviceID: device.id, identity: device.identity, remembered: true)
        var edited = device
        edited.name = "Renamed"

        let saved = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "",
            hadRememberedPassword: false
        )

        XCTAssertTrue(saved.rememberPassword)
        XCTAssertEqual(saved.name, "Renamed")
        XCTAssertEqual(try DeviceProfileStore(defaults: harness.defaults).devices().first?.rememberPassword, true)
        XCTAssertEqual(harness.credentials.savedAccounts, [])
        XCTAssertEqual(harness.credentials.deletedAccounts, [])
        XCTAssertEqual(harness.credentials.passwords[account], "from-session")
    }

    func testSaveKeepsRememberThatASessionTurnedOffWhileEditing() throws {
        let device = makeDevice(rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)
        // After the sheet loaded the saved password, a session's sign-in
        // deleted it.
        harness.model.recordCredentialPersistence(deviceID: device.id, identity: device.identity, remembered: false)
        let account = try account(for: device)
        harness.cache.setPassword("new", for: account)
        var edited = device
        edited.name = "Renamed"

        let saved = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "old",
            hadRememberedPassword: true
        )

        XCTAssertFalse(saved.rememberPassword)
        XCTAssertEqual(harness.cache.password(for: account), "new", "The session's password is newer than the sheet's")
        XCTAssertEqual(try DeviceProfileStore(defaults: harness.defaults).devices().first?.rememberPassword, false)
        XCTAssertEqual(harness.credentials.savedAccounts, [])
        XCTAssertEqual(harness.credentials.deletedAccounts, [])
    }

    func testSaveKeepsEditorRememberWhenIdentityChangedToo() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)
        harness.model.recordCredentialPersistence(deviceID: device.id, identity: device.identity, remembered: true)
        var edited = device
        edited.host = "new.example"

        let saved = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "",
            hadRememberedPassword: false
        )

        XCTAssertFalse(saved.rememberPassword)
        XCTAssertEqual(try DeviceProfileStore(defaults: harness.defaults).devices().first?.rememberPassword, false)
    }

    func testSaveKeepsRememberToggledInEditorOverSessionChange() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        let editor = DeviceEditorState(device: device, isNew: false)
        let account = try account(for: device)
        harness.credentials.passwords[account] = "from-session"
        harness.model.recordCredentialPersistence(deviceID: device.id, identity: device.identity, remembered: true)
        var edited = device
        edited.rememberPassword = true

        _ = try harness.model.save(
            editor: editor,
            editedDevice: edited,
            password: "typed",
            hadRememberedPassword: false
        )

        XCTAssertEqual(harness.credentials.savedAccounts, [account])
        XCTAssertEqual(harness.credentials.passwords[account], "typed")
    }

    // MARK: - recordCredentialPersistence

    func testRecordCredentialPersistenceFlipsAndPersistsFlagOnIdentityMatch() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])

        harness.model.recordCredentialPersistence(
            deviceID: device.id,
            identity: device.identity,
            remembered: true
        )

        XCTAssertEqual(harness.model.devices.first?.rememberPassword, true)
        let persisted = try DeviceProfileStore(defaults: harness.defaults).devices()
        XCTAssertEqual(persisted.first?.rememberPassword, true)
    }

    func testRecordCredentialPersistenceIgnoresIdentityMismatch() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        let otherIdentity = RDPConnectionIdentity(
            host: device.host,
            port: device.port,
            username: "someone-else",
            domain: device.domain
        )

        harness.model.recordCredentialPersistence(
            deviceID: device.id,
            identity: otherIdentity,
            remembered: true
        )

        XCTAssertEqual(harness.model.devices.first?.rememberPassword, false)
        let persisted = try DeviceProfileStore(defaults: harness.defaults).devices()
        XCTAssertEqual(persisted.first?.rememberPassword, false)
    }

    func testRecordCredentialPersistenceIgnoresUnknownDeviceAndEqualFlag() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        let persistedBefore = try DeviceProfileStore(defaults: harness.defaults).devices()

        harness.model.recordCredentialPersistence(
            deviceID: UUID(),
            identity: device.identity,
            remembered: true
        )
        // Same value as the profile already has: must not rewrite the store.
        harness.model.recordCredentialPersistence(
            deviceID: device.id,
            identity: device.identity,
            remembered: false
        )

        XCTAssertNil(harness.model.errorMessage)
        XCTAssertEqual(try DeviceProfileStore(defaults: harness.defaults).devices(), persistedBefore)
    }

    // MARK: - addNewDevice

    func testAddNewDeviceKeepsAnEditorThatIsAlreadyOpen() throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        harness.model.edit(device)

        harness.model.addNewDevice()

        XCTAssertEqual(harness.model.editorState?.id, device.id)
        XCTAssertEqual(harness.model.editorState?.isNew, false)
    }

    // MARK: - edit

    func testEditOpensEditorWithoutReadingCredentialStore() throws {
        let device = makeDevice(rememberPassword: true)
        let harness = try makeHarness(devices: [device])

        harness.model.edit(device)

        XCTAssertEqual(harness.model.editorState?.device, device)
        XCTAssertEqual(harness.credentials.readAccounts, [])
    }

    func testSavedPasswordReadsCredentialStoreWhenPasswordIsRemembered() async throws {
        let device = makeDevice(rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        let account = try account(for: device)
        harness.credentials.passwords[account] = "secret"

        let password = await harness.model.savedPassword(for: device)

        XCTAssertEqual(password, "secret")
        XCTAssertEqual(harness.credentials.readAccounts, [account])
    }

    func testSavedPasswordSkipsCredentialStoreWhenPasswordIsNotRemembered() async throws {
        let device = makeDevice()
        let harness = try makeHarness(devices: [device])
        harness.credentials.passwords[try account(for: device)] = "secret"

        let password = await harness.model.savedPassword(for: device)

        XCTAssertNil(password)
        XCTAssertEqual(harness.credentials.readAccounts, [])
    }

    func testSavedPasswordTreatsReadFailureAsNone() async throws {
        let device = makeDevice(rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        harness.credentials.readError = KeychainError.unexpectedStatus(-1)

        let password = await harness.model.savedPassword(for: device)

        XCTAssertNil(password)
    }

    // MARK: - connect

    func testConnectLeavesPasswordResolutionToTheSession() throws {
        let device = makeDevice(rememberPassword: true)
        let harness = try makeHarness(devices: [device])
        let opener = RemoteSessionOpenerRecorder()
        // A cached password must not override the keychain one the session
        // reads for a profile that remembers its password.
        harness.cache.setPassword("cached", for: try account(for: device))

        harness.model.connect(device, using: opener)

        XCTAssertEqual(opener.drafts.map(\.password), [""])
        XCTAssertEqual(opener.drafts.map(\.rememberPassword), [true])
        XCTAssertEqual(harness.credentials.readAccounts, [])
    }

    // MARK: - duplicate

    func testDuplicateKeepsRememberPassword() throws {
        var device = makeDevice(rememberPassword: true)
        device.lastConnectedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let harness = try makeHarness(devices: [device])

        harness.model.duplicate(device)

        let copy = try XCTUnwrap(harness.model.devices.first { $0.id != device.id })
        XCTAssertEqual(copy.name, "Test PC Copy")
        XCTAssertTrue(copy.rememberPassword)
        XCTAssertTrue(copy.identity.hasSameConnectionIdentity(as: device.identity))
        XCTAssertNil(copy.lastConnectedAt)
    }

    // MARK: - Helpers

    private func makeHarness(devices: [DeviceProfile] = []) throws -> Harness {
        let defaults = try makeIsolatedDefaults()
        let profileStore = DeviceProfileStore(defaults: defaults)
        for device in devices {
            try profileStore.save(device)
        }
        let credentials = CredentialStoreRecorder()
        let cache = InMemoryCredentialCache()
        let model = DeviceListModel(credentialStore: credentials, credentialCache: cache, defaults: defaults)
        return Harness(model: model, credentials: credentials, cache: cache, defaults: defaults)
    }

    private func makeDevice(
        name: String = "Test PC",
        host: String = "host.example",
        port: UInt16 = 3389,
        username: String = "user",
        domain: String = "",
        rememberPassword: Bool = false
    ) -> DeviceProfile {
        DeviceProfile(
            id: UUID(),
            name: name,
            host: host,
            port: port,
            username: username,
            domain: domain,
            hideCertificateWarnings: false,
            timeoutSeconds: 10,
            clipboardSharingEnabled: true,
            audioPlaybackEnabled: false,
            rememberPassword: rememberPassword,
            accentHue: 0.5,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastConnectedAt: nil
        )
    }

    private func account(for device: DeviceProfile) throws -> String {
        try XCTUnwrap(KeychainCredentialKey(identity: device.identity)).account
    }
}

/// Recording fake for the keychain seam: tests must never touch the real
/// Keychain, so credential traffic lands in plain dictionaries instead.
/// Unchecked Sendable: a test awaits each call, so no two tasks touch it
/// at once.
private final class CredentialStoreRecorder: CredentialStoring, @unchecked Sendable {
    var passwords: [String: String] = [:]
    var readError: Error?
    var saveError: Error?
    var deleteError: Error?

    private(set) var readAccounts: [String] = []
    private(set) var savedAccounts: [String] = []
    private(set) var deletedAccounts: [String] = []

    func password(for key: KeychainCredentialKey) throws -> String? {
        readAccounts.append(key.account)
        if let readError {
            throw readError
        }
        return passwords[key.account]
    }

    func savePassword(_ password: String, for key: KeychainCredentialKey) throws {
        savedAccounts.append(key.account)
        if let saveError {
            throw saveError
        }
        passwords[key.account] = password
    }

    func deletePassword(for key: KeychainCredentialKey) throws {
        deletedAccounts.append(key.account)
        if let deleteError {
            throw deleteError
        }
        passwords.removeValue(forKey: key.account)
    }
}

@MainActor
private final class RemoteSessionOpenerRecorder: RemoteSessionOpening {
    private(set) var drafts: [RDPConnectionDraft] = []

    func openRemoteSession(_ draft: RDPConnectionDraft) {
        drafts.append(draft)
    }
}
