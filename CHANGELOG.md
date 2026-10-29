# Changelog

## Unreleased

Security, input, clipboard, and session fixes from the RDPKit example
client and from a full review of RDPeek, on RDPKit 0.4.0.

### Security

- A server certificate that neither this Mac nor RDPeek trusts, or one
  that differs from the certificate trusted for that host, now stops the
  connection before any credential is sent. The certificate banner
  offers Trust and Connect. Profiles set to accept untrusted
  certificates still connect, except to a certificate that replaced a
  trusted one.
- Trusting a certificate for a host replaces the one trusted before,
  and a server redirection's certificate is pinned under its own host.
- “Hide certificate warnings” is now “Accept untrusted certificates”,
  which says what it does.
- Files pasted from the remote clipboard are quarantined like
  downloads, so Gatekeeper checks them before they open.
- A password is kept only after the server accepts it, the Keychain is
  read only for a PC that remembers its password, and a password the
  server rejected is not sent again.

### Connecting

- A wrong user name or password reopens the sign-in sheet. Locked,
  disabled, or expired accounts, idle timeouts, another connection
  taking over, administrator disconnects, and licensing failures are
  explained in plain words; Stats for Nerds keeps the details.
- Only a server that could not be reached is retried automatically, so
  a failed sign-in is not repeated and a mistyped host name is reported
  at once.
- Servers whose RSA certificate does not allow digital signatures
  connect, using the RSA key exchange for that connection.
- “DOMAIN\user” user names sign in to that domain.
- The remote desktop starts at the window's size in points and grows to
  full Retina resolution on servers that support resizing, so servers
  that do not no longer show a tiny desktop.
- A session that signs in but never shows the desktop reconnects once,
  then says so, instead of showing Connecting forever.
- macOS's local network prompt now says why RDPeek asks.

### Remote input

- The remote desktop is told the Mac's keyboard layout instead of US
  English, and a key that types the same character there is sent as
  its scancode, so remote input methods see it.
- Right ⌥ types the character it gives on the Mac, such as @ with ⌥L on
  a German layout; left ⌥ stays Alt.
- ⌘ reaches the remote as the Windows key only together with another
  key or click, or when tapped alone, so ⌘-Tab and Spotlight no longer
  open the remote Start menu; neither do ⌘-clicking a background
  session window or scrolling with ⌘ held.
- Keys pressed with ⌘ are released on the remote as soon as they go up,
  so pressing ⌘W twice quickly works.
- Modifiers whose release the window never saw, for example with a
  menu open or Spotlight up, are released on the next event, and
  keyboards that report no left/right modifier bits work.
- Caps Lock and Num Lock follow the Mac when the window regains focus,
  so keypad digits type digits; keypad Clear no longer toggles Num
  Lock, and keypad = types “=” on every layout.
- F2, F4, F13–F20, the ISO and JIS keys and the context-menu key are
  sent, the ISO key beside left Shift reaches the remote as that key,
  and a held key keeps repeating as the same key.
- Horizontal scrolling goes the right way, trackpad scrolling keeps
  its fractions, and a drag past the edge of the desktop holds the
  pointer on the edge.

### Clipboard

- Clipboard sharing can be turned on during a session for PCs that
  start with it off, and Share for 30 Seconds is offered while sharing
  is off and no longer turns sharing off when it ends.
- Copied files are read off the main thread, so a large or iCloud file
  no longer freezes the window.
- Remote files download in 1 MiB ranges, so pasting large files from
  Windows and gnome-remote-desktop no longer fails. A download gives
  way to a newer copy, stops when the server stops answering, and its
  files are deleted once they leave the clipboard.
- Copied files whose names Windows rejects are renamed, and files with
  the same name are numbered.
- “Clipboard synced” appears only after Sync Now.

### Sessions

- A graphics update that fails to decode no longer ends the session;
  RDPeek asks the server for a fresh picture instead.
- Each session runs on its own thread, so many open windows cannot
  starve video decoding, and a session that fails or ends can no longer
  leave its window on Connecting.
- The remote desktop is drawn on whole pixels, so it is sharp at 1x in
  any window size.
- Resizing a window and back quickly leaves the remote at the window's
  size, and a redirected server receives the window's size.
- An idle desktop no longer keeps the display link running, and the
  window does far less work per frame.
- Reconnect is unavailable while the password is read or the sign-in
  sheet is up, and the connecting status says why a session reconnects.
- Stats for Nerds shows the server's warnings and whether the RSA key
  exchange was used. The overlays respect Reduce Motion.

### Connection Center

- Return and Delete act on the selected PC only while the grid has
  focus, not while typing in the search field.
- The PC editor can set the connection timeout, shows validation errors
  where they can be seen, opens without waiting for the Keychain, and
  is no longer discarded by ⌘N.
- PC cards have VoiceOver actions for Connect, Edit, Duplicate, and
  Delete.
- Saved PCs stay readable when one is damaged or was written by another
  version, and an unreadable list is reported instead of shown empty.
- Duplicating a PC keeps Remember Password, and deleting one keeps a
  password that another PC still remembers.

### Under the hood

- Updated to RDPKit 0.4.0: timeouts bound every step before the first
  frame, errors name their reason, and Windows, KRdp and
  gnome-remote-desktop video and bitmap codecs are faster and more
  correct.
- Package versions are pinned in Package.resolved, CI builds with a
  pinned Xcode, and SwiftLint checks the tests too.

## 1.1.1

Compatibility and reliability improvements for Windows and KDE KRdp
servers through RDPKit 0.3.1.

### Sessions

- Follow server redirections and handle more Windows and KRdp activation,
  reconnect, clipboard, audio, and input flows.
- Render RemoteFX Progressive, classic RemoteFX, ClearCodec, NSCodec,
  bitmap-compressed, and interleaved RLE updates, with more complete
  multi-surface composition and AVC444 reconstruction.
- Keep decoded-frame acknowledgements synchronized with presentation and
  recover the display layer without flushing every frame.
- Save server-issued RDP client licenses in Keychain and reuse them on
  later connections.

### Under the hood

- Updated to RDPKit 0.3.1 for broader graphics capability negotiation,
  stricter protocol validation, and expanded interoperability coverage.

## 1.1.0

Windows support: connect to Windows hosts that require Network Level
Authentication, in addition to the existing servers.

### Sessions

- Windows RDP compatibility through RDPKit 0.2.0 — CredSSP with NTLM for
  hosts that require Network Level Authentication, plus the graphics,
  codec, clipboard, input, and audio paths Windows negotiates.
- Graphics capability negotiation runs in automatic mode, picking the
  best path per host (Windows included) with no profile knobs to set.

### Under the hood

- Updated to RDPKit 0.2.0, which also brings a lighter, faster decode
  path with bounded in-order video buffering.

## 1.0.1

Bug-fix release: remote input, session window, and credential-storage
fixes, plus the project's first unit-test suite.

### Remote input

- Modifier keys no longer get stuck down on the remote. Modifier state
  is reconciled from each event's device flags (so one missed event can
  no longer invert a key permanently), everything held is released when
  the session window loses focus, and the keyUps AppKit swallows while
  ⌘ is held are flushed when ⌘ comes back up.
- ⌘ and ⌃ shortcuts are sent to the remote desktop while controlling
  it, instead of triggering local menu items — ⌘R now opens the remote
  Run dialog rather than reconnecting the session.

### Session windows

- Connecting to a PC that already has a session focuses its window
  without re-maximizing it or churning the remote resolution.
- After a server-side disconnect, clipboard sync and polling stop
  talking to the dead connection and no longer show false success
  toasts.
- Closing a background session window no longer removes the Session
  menu for the focused one, and menu items now enable, disable, and
  title themselves from live session state.
- Quitting with open sessions cancels them cleanly instead of dropping
  the connections mid-stream.

### Devices and credentials

- A corrupted or unreadable saved-PC list can no longer be wiped by the
  next edit: writes fail with a visible error and leave the stored data
  intact.
- Keychain entries survive profile duplication and deletion when
  another profile connects to the same machine, case-only host edits
  keep addressing the same entry (existing items migrate
  automatically), and passwords remembered from the in-session sign-in
  now show up in the device editor.
- Deleting a PC surfaces Keychain errors instead of silently ignoring
  them, and clears the in-memory password cache.
- Saving a PC while it is connecting no longer reverts its Recently
  Used timestamp, and Add PC (⌘N) opens the Connection Center first
  when its window is closed.
- Keychain writes happen off the connection path, so a Keychain
  approval prompt can no longer trigger a spurious connection timeout.

### Testing

- New unit-test target covering remote input key state, the device
  profile store, and keychain account normalization; CI runs the suite
  on every push.

## 1.0.0

Initial release of RDPeek, a native macOS remote desktop client built on
[RDPKit](https://github.com/steelbrain/RDPKit).

### Connection Center

- Searchable grid of saved PCs with per-device gradient tiles, hover
  lift, play-to-connect, context menus, and sort by name or recent use.
- Add/edit sheet with live tile preview; duplicate and delete (with
  Keychain cleanup and confirmation).
- First-run empty state, Devices window keyboard flow (Return to
  connect, Delete to remove), and a Settings window with defaults for
  new PCs.
- No resolution knobs anywhere: the remote desktop starts at the
  screen's size and follows the window as it resizes, HiDPI aware.

### Sessions

- Full-bleed hardware-decoded video (AVC420/AVC444/H.264 and HEVC via
  VideoToolbox) paced on the display link, under a transparent glass
  titlebar that never overlaps the remote desktop's input area.
- Animated connecting overlay, in-window sign-in when no password is
  available, and a reconnect overlay with "Use different credentials…".
- Live TLS certificate trust banner with per-host pinning, surfaced at
  handshake time.
- Two-way clipboard for text and files (up to 32 MiB) with always-on,
  one-shot, and 30-second time-boxed sharing; optional remote audio.
- Titlebar status pill and session menu; performance overlay chip and a
  full Stats for Nerds diagnostics window.

### Reliability

- Credentials resolve from Keychain, then an in-memory per-run cache,
  then the sign-in overlay — without blocking on Keychain approval.
- Transport failures and pre-frame stalls retry automatically (bounded);
  a first-frame watchdog converts silent hangs into clear failures.
  Credential-bearing failures never retry automatically.

### App

- Original vector app icon (frosted window with a warm desktop peeking
  from behind), in-app Help window (⌘?), About panel linking
  [rdpeek.com](https://rdpeek.com), contextual menus that follow window
  focus, and CI running lint and build on every push.
