/// Command state of a session: the Session menu and the HUD's Reconnect and
/// Cancel controls both enable and title their items from it.
struct SessionCommandState: Equatable {
    var startTitle: String
    var canStart: Bool
    var canCancel: Bool
    var canSyncClipboard: Bool
    var canShareClipboardTemporarily: Bool

    /// Derives the command state from the session's primitive phase inputs.
    /// `hasFrame` is whether a remote frame is available to show; it titles
    /// the Connecting/Connected distinction while a connection is live.
    /// A connection that ended — with a report, or with an end reason such
    /// as the user disconnecting — is started again with Reconnect. The
    /// clipboard items come from the session clipboard as they are.
    static func make(
        isConnecting: Bool,
        isResolvingStoredCredentials: Bool,
        isAutoRetryPending: Bool,
        isAwaitingCredentials: Bool,
        hasFrame: Bool,
        hasReport: Bool,
        hasEndReason: Bool,
        hostIsEmpty: Bool,
        canSyncClipboard: Bool,
        canShareClipboardTemporarily: Bool
    ) -> SessionCommandState {
        let startTitle = if isConnecting {
            hasFrame ? "Connected" : "Connecting"
        } else {
            hasReport || hasEndReason ? "Reconnect" : "Connect"
        }
        return SessionCommandState(
            startTitle: startTitle,
            // The sign-in overlay is the way forward while it asks for
            // credentials; connecting around it would skip them.
            canStart: isConnecting == false && hostIsEmpty == false
                && isResolvingStoredCredentials == false && isAutoRetryPending == false
                && isAwaitingCredentials == false,
            // Credential resolution and the auto-retry wait are cancelable
            // phases too, not just the live connection.
            canCancel: isConnecting || isResolvingStoredCredentials || isAutoRetryPending,
            canSyncClipboard: canSyncClipboard,
            canShareClipboardTemporarily: canShareClipboardTemporarily
        )
    }
}
