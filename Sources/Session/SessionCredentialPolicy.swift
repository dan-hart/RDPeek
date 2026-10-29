import RDPKit

/// How a session finds, keeps, and forgets the password it signs in with.
/// Only the decisions live here; the session applies them to the Keychain
/// and to this app run's password cache.
enum SessionCredentialPolicy {
    /// Where a connection the user starts gets its password.
    enum Source: Equatable {
        /// The session has one: typed at sign-in, or found for an earlier
        /// connection.
        case session
        /// Connect without credentials: there is no user name to find a
        /// password for, and the user left every sign-in field empty.
        case noCredentials
        /// Read the Keychain, which the PC remembers the password in.
        case keychain(KeychainCredentialKey)
        /// The password this app run kept for the sign-in.
        case cache(password: String)
        /// Ask the user to sign in.
        case prompt
    }

    /// The session's own password first; then the Keychain, only when the
    /// PC remembers the password; then this app run's cache; then the
    /// sign-in prompt. After a Keychain read that found nothing, the cache
    /// or the prompt come next: ask again with `remembersPassword` off.
    static func source(
        sessionPassword: String,
        identity: RDPConnectionIdentity,
        remembersPassword: Bool,
        didPromptForCredentials: Bool,
        cachedPassword: (_ account: String) -> String?
    ) -> Source {
        guard sessionPassword.isEmpty else {
            return .session
        }
        guard let key = KeychainCredentialKey(identity: identity) else {
            // Without a user name there is nothing stored.
            return didPromptForCredentials ? .noCredentials : .prompt
        }
        if remembersPassword {
            return .keychain(key)
        }
        return cachedPassword(key.account).map { .cache(password: $0) } ?? .prompt
    }

    /// What a session does with the password a server just accepted. Every
    /// case but `nothing` also keeps it for this app run, under `key`: the
    /// cache serves other PCs with this sign-in that do not remember it.
    enum Keep: Equatable {
        /// There is no user name or password to keep, or the PC was
        /// deleted: its window may go on, but keeps nothing for it.
        case nothing
        /// The Keychain is right as it is.
        case cacheOnly(KeychainCredentialKey)
        /// Save it to the Keychain: the PC remembers it.
        case save(KeychainCredentialKey)
        /// Delete the Keychain item: the PC no longer remembers it.
        case delete(KeychainCredentialKey)
        /// The PC no longer remembers it, but another PC with this sign-in
        /// does, so the Keychain item stays.
        case stopRemembering(KeychainCredentialKey)

        var key: KeychainCredentialKey? {
            switch self {
            case .nothing:
                nil
            case let .cacheOnly(key), let .save(key), let .delete(key), let .stopRemembering(key):
                key
            }
        }
    }

    /// `rememberedPassword` is the password the Keychain holds for the
    /// identity, when the session knows it.
    static func keep(
        password: String,
        identity: RDPConnectionIdentity,
        remembersPassword: Bool,
        rememberedPassword: String?,
        isRememberedByAnotherPC: Bool,
        isPCDeleted: Bool
    ) -> Keep {
        guard isPCDeleted == false,
              let key = KeychainCredentialKey(identity: identity),
              password.isEmpty == false
        else {
            return .nothing
        }
        if remembersPassword {
            // A password read from the Keychain is there already.
            return password == rememberedPassword ? .cacheOnly(key) : .save(key)
        }
        guard rememberedPassword != nil else {
            return .cacheOnly(key)
        }
        return isRememberedByAnotherPC ? .stopRemembering(key) : .delete(key)
    }

    /// Whether to drop this app run's copy of a password the server
    /// rejected: only when the cache holds that password, not one kept for
    /// the sign-in since.
    static func forgetsCachedPassword(_ cachedPassword: String?, rejected password: String) -> Bool {
        cachedPassword == password
    }

    /// Whether the password the Keychain held still belongs to a session
    /// that now signs in as `identity`. One held for another sign-in is not
    /// this one's to keep or delete.
    static func keepsRememberedPassword(
        signingInAs identity: RDPConnectionIdentity,
        insteadOf previousIdentity: RDPConnectionIdentity
    ) -> Bool {
        identity.hasSameConnectionIdentity(as: previousIdentity)
    }
}
