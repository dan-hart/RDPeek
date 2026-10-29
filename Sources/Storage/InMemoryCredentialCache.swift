/// Holds the passwords sessions signed in with and the PC editor saved
/// during this app run, remembered in the Keychain or not, so PCs that
/// don't remember theirs connect without asking. Kept for the lifetime of
/// the app process only. Keyed by the connection identity's account name.
@MainActor
final class InMemoryCredentialCache {
    static let shared = InMemoryCredentialCache()

    private var passwords: [String: String] = [:]

    func password(for account: String) -> String? {
        passwords[account]
    }

    func setPassword(_ password: String, for account: String) {
        passwords[account] = password
    }

    func removePassword(for account: String) {
        passwords.removeValue(forKey: account)
    }
}
