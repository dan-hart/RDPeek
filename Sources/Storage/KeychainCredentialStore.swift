import Foundation
import RDPKit

struct KeychainCredentialKey: Equatable, Sendable {
    let identity: RDPConnectionIdentity

    init?(identity: RDPConnectionIdentity) {
        guard identity.credentialAccountName != nil else {
            return nil
        }
        self.identity = identity
    }

    /// Account name with the host lowercased. Connection identities compare
    /// hosts case-insensitively, so the keychain must address them the same
    /// way — otherwise a case-only host edit strands the stored password.
    var account: String {
        guard let account = identity.credentialAccountName else {
            preconditionFailure("KeychainCredentialKey requires a credential account identity.")
        }
        return account
    }

    /// The pre-normalization account name older installs stored items under,
    /// with the host as typed.
    var legacyAccount: String? {
        guard let qualifiedUsername = identity.qualifiedUsername else {
            return nil
        }
        let legacy = "\(qualifiedUsername)@\(identity.host):\(identity.port)"
        return legacy == account ? nil : legacy
    }
}

/// The credential operations models depend on, as a seam so tests can
/// substitute a fake instead of touching the real Keychain. Sendable so
/// reads can run off the main actor.
protocol CredentialStoring: Sendable {
    func password(for key: KeychainCredentialKey) throws -> String?
    func savePassword(_ password: String, for key: KeychainCredentialKey) throws
    func deletePassword(for key: KeychainCredentialKey) throws
}

struct KeychainCredentialStore: CredentialStoring {
    private let keychain = KeychainService(name: "ai.aneesiqbal.rdpeek.credentials")

    func password(for key: KeychainCredentialKey) throws -> String? {
        if let password = try password(account: key.account) {
            return password
        }
        // Fall back to the raw-case account older installs wrote, and
        // migrate the item to the normalized account on a hit.
        guard let legacyAccount = key.legacyAccount,
              let password = try password(account: legacyAccount)
        else {
            return nil
        }
        try? savePassword(password, for: key)
        return password
    }

    func savePassword(_ password: String, for key: KeychainCredentialKey) throws {
        try keychain.save(Data(password.utf8), account: key.account)
        if let legacyAccount = key.legacyAccount {
            try? keychain.delete(account: legacyAccount)
        }
    }

    func deletePassword(for key: KeychainCredentialKey) throws {
        try keychain.delete(account: key.account)
        if let legacyAccount = key.legacyAccount {
            try keychain.delete(account: legacyAccount)
        }
    }

    private func password(account: String) throws -> String? {
        guard let data = try keychain.data(account: account) else {
            return nil
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidItemData
        }
        return password
    }
}

enum CredentialPersistenceRequest: Sendable {
    case save(key: KeychainCredentialKey, password: String)
    case delete(key: KeychainCredentialKey)

    var key: KeychainCredentialKey {
        switch self {
        case let .save(key, _), let .delete(key):
            key
        }
    }
}

enum CredentialPersistenceResult: Sendable {
    case saved
    case deleted
}

func persistCredentials(
    _ request: CredentialPersistenceRequest,
    store: any CredentialStoring
) -> Result<CredentialPersistenceResult, Error> {
    do {
        switch request {
        case let .save(key, password):
            try store.savePassword(password, for: key)
            return .success(.saved)
        case let .delete(key):
            try store.deletePassword(for: key)
            return .success(.deleted)
        }
    } catch {
        return .failure(error)
    }
}
