import Foundation
import RDPKit
import XCTest

final class KeychainCredentialStoreTests: XCTestCase {
    /// The account's current name, with the host lowercased.
    private let currentAccount = "anees@winbox:3389"
    /// The name older installs gave it, with the host as typed.
    private let legacyAccount = "anees@WinBox:3389"

    private func typedKey() throws -> KeychainCredentialKey {
        try XCTUnwrap(KeychainCredentialKey(identity: RDPConnectionIdentity(host: "WinBox", username: "anees")))
    }

    func testPasswordUnderTheLegacyNameMovesToTheCurrentName() throws {
        let keychain = KeychainItemsFake([legacyAccount: "secret"])
        let store = KeychainCredentialStore(keychain: keychain)

        XCTAssertEqual(try store.password(for: typedKey()), "secret")
        XCTAssertEqual(keychain.passwords, [currentAccount: "secret"])
    }

    func testHostTypedInLowercaseReadsNoLegacyName() throws {
        let keychain = KeychainItemsFake([:])
        let store = KeychainCredentialStore(keychain: keychain)
        let key = try XCTUnwrap(KeychainCredentialKey(identity: RDPConnectionIdentity(host: "winbox", username: "anees")))

        XCTAssertNil(try store.password(for: key))
        XCTAssertEqual(keychain.readAccounts, [currentAccount])
    }

    /// Deleting the PC can delete the password while a session's read moves
    /// it from its legacy name. Wherever the deletion falls, it stays deleted.
    func testPasswordDeletedWhileItMovesStaysDeleted() throws {
        let key = try typedKey()
        for call in 1 ... 10 {
            let keychain = KeychainItemsFake([legacyAccount: "secret"])
            let store = KeychainCredentialStore(keychain: keychain)
            keychain.interruption = (call, { try? store.deletePassword(for: key) })

            let password = try store.password(for: key)

            guard keychain.interruption == nil else {
                // The read made fewer calls.
                break
            }
            XCTAssertEqual(keychain.passwords, [:], "Deleted after call \(call)")
            XCTAssertTrue(password == nil || password == "secret", "Deleted after call \(call)")
        }
    }

    /// A password saved under the current name while the legacy one moves is
    /// the newer one.
    func testPasswordSavedWhileTheLegacyOneMovesStays() throws {
        let key = try typedKey()
        let keychain = KeychainItemsFake([legacyAccount: "older"])
        let store = KeychainCredentialStore(keychain: keychain)
        // After the read found nothing under the current name and read the legacy one.
        keychain.interruption = (2, { try? store.savePassword("newer", for: key) })

        XCTAssertEqual(try store.password(for: key), "newer")
        XCTAssertEqual(keychain.passwords, [currentAccount: "newer"])
    }

    func testLegacyItemLeftBesideTheCurrentOneIsDeletedNotRenamed() throws {
        let keychain = KeychainItemsFake([legacyAccount: "older"])
        let store = KeychainCredentialStore(keychain: keychain)
        // Saved under the current name between the two reads of the lookup.
        keychain.interruption = (1, { keychain.save(Data("newer".utf8), account: self.currentAccount) })

        XCTAssertEqual(try store.password(for: typedKey()), "newer")
        XCTAssertEqual(keychain.passwords, [currentAccount: "newer"])
    }

    func testSavingAndDeletingCoverTheLegacyName() throws {
        let key = try typedKey()
        let keychain = KeychainItemsFake([legacyAccount: "older"])
        let store = KeychainCredentialStore(keychain: keychain)

        try store.savePassword("newer", for: key)
        XCTAssertEqual(keychain.passwords, [currentAccount: "newer"])

        keychain.passwords[legacyAccount] = "older"
        try store.deletePassword(for: key)
        XCTAssertEqual(keychain.passwords, [:])
    }
}

/// Stands in for the Keychain. `interruption` runs once, after the call it
/// names, as another thread could between two calls; the tests make every
/// call from one thread.
private final class KeychainItemsFake: KeychainItems, @unchecked Sendable {
    var passwords: [String: String]
    private(set) var readAccounts: [String] = []
    var interruption: (afterCall: Int, run: () -> Void)?
    private var calls = 0

    init(_ passwords: [String: String]) {
        self.passwords = passwords
    }

    func data(account: String) -> Data? {
        defer { called() }
        readAccounts.append(account)
        return passwords[account].map { Data($0.utf8) }
    }

    func save(_ data: Data, account: String) {
        defer { called() }
        passwords[account] = String(decoding: data, as: UTF8.self)
    }

    func rename(account: String, to newAccount: String) -> KeychainRename {
        defer { called() }
        guard let password = passwords[account] else {
            return .notFound
        }
        guard passwords[newAccount] == nil else {
            return .newNameTaken
        }
        passwords[account] = nil
        passwords[newAccount] = password
        return .renamed
    }

    func delete(account: String) {
        defer { called() }
        passwords[account] = nil
    }

    private func called() {
        calls += 1
        if let interruption, interruption.afterCall == calls {
            self.interruption = nil
            interruption.run()
        }
    }
}
