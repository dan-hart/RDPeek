import Foundation
import Security

/// The generic-password items under one Keychain service, addressed by
/// account. The credential and client-license stores both go through here,
/// so their queries stay identical.
struct KeychainService: Sendable {
    let name: String

    /// The item's data, or nil when there is no item for `account`.
    func data(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.invalidItemData
        }
        return data
    }

    /// Replaces the item's data, adding the item when there is none.
    func save(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        // No kSecAttrAccessible: items live in the file-based login
        // keychain, which ignores it (only the data-protection keychain
        // honors it).
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another writer (editor vs. session persistence) added the
            // item between our update and add; retry the update.
            let retryStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(retryStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Deletes the item; a missing item counts as deleted.
    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: name,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainError: Error, CustomStringConvertible {
    /// The item exists, but its data is not in the format the store writes.
    case invalidItemData
    case unexpectedStatus(OSStatus)

    var description: String {
        switch self {
        case .invalidItemData:
            "The Keychain item's data was not in the expected format."
        case let .unexpectedStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "Keychain error \(status): \(message)"
            } else {
                "Keychain returned OSStatus \(status)."
            }
        }
    }
}
