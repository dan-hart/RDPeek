import Foundation
import RDPKit

struct ClientLicenseStoreKey: Equatable, Sendable {
    let identity: RDPConnectionIdentity

    var account: String {
        [
            "v1",
            identity.host.lowercased(),
            String(identity.port),
            identity.domain ?? "",
            identity.username,
        ].joined(separator: "\u{1f}")
    }
}

struct ClientLicenseStore: Sendable {
    private let keychain = KeychainService(name: "ai.aneesiqbal.rdpeek.client-licenses")

    func license(for key: ClientLicenseStoreKey) throws -> RDPStoredClientLicense? {
        guard let data = try keychain.data(account: key.account) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(RDPStoredClientLicense.self, from: data)
        } catch {
            throw KeychainError.invalidItemData
        }
    }

    func saveLicense(_ license: RDPStoredClientLicense, for key: ClientLicenseStoreKey) throws {
        try keychain.save(JSONEncoder().encode(license), account: key.account)
    }
}

enum ClientLicensePersistenceResult: Sendable {
    case saved
}

@discardableResult
func persistClientLicenseIfNeeded(
    _ license: RDPStoredClientLicense?,
    key: ClientLicenseStoreKey,
    store: ClientLicenseStore
) -> Result<ClientLicensePersistenceResult, Error>? {
    guard let license else {
        return nil
    }

    do {
        try store.saveLicense(license, for: key)
        return .success(.saved)
    } catch {
        return .failure(error)
    }
}
