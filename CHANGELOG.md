# Changelog

## Unreleased

Security, input, clipboard, and session fixes from the RDPKit example
client and from a full review of RDPeek, on RDPKit 0.5.0.

### Security

- A server certificate that neither this Mac nor RDPeek trusts now stops
  the connection before any credential is sent. The certificate banner
  offers Trust and Connect. Profiles set to accept untrusted
  certificates still connect, except when such a certificate replaced
  the one trusted for that host.
- Trusting a certificate for a host replaces the one trusted before,
  and a server redirection's certificate is pinned under its own host.
- “Hide certificate warnings” is now “Accept untrusted certificates”,
  which says what it does, and its help says credentials then go to a
  server nobody verified.
- Files pasted from the remote clipboard are quarantined like
  downloads, so Gatekeeper checks them before they open.
- A password is kept only after the server accepts it, the Keychain is
  read only for a PC that remembers its password, and a password the
  server rejected is no longer kept in memory or offered again in that
  window.

### Connecting

- A wrong user name or password reopens the sign-in sheet. Locked,
  disabled, or expired accounts, idle timeouts, another connection
  taking over, administrator disconnects, a server shutting down or
  restarting, and licensing failures are explained in plain words from
  RDPKit's typed result, not its error text; Stats for Nerds keeps the
  details.
- When a connection fails, only a server that could not be reached is
  retried automatically, so a failed sign-in is not repeated, and a
  mistyped host name, a refused connection, or one macOS blocked is
  reported at once. The message says which it was, and for an
  unreachable host on the local network points to the Local Network
  privacy setting.
- Servers whose RSA certificate does not allow digital signatures
  connect, using the RSA key exchange for that connection. It is never
  used to reconnect to a server that passed the session on, so a
  sign-in that server took is not sent again without forward secrecy.
- When a server passes the session on to one that cannot be found or
  reached, the message names that server instead of blaming the host
  typed in.
- A server that requires a client certificate says so.
- Signing in with every field empty to a server that needs a sign-in
  asks for a user name and password again, and the sign-in sheet names
  a field too long to send.
- “DOMAIN\user” user names sign in to that domain.
- The remote desktop starts at the window's size in points and grows to
  full Retina resolution on servers that support resizing, so servers
  that do not no longer show a tiny desktop.
- A session that signs in but never shows the desktop reconnects once,
  then says so, instead of showing Connecting forever.
- A session whose desktop RDPeek cannot decode, such as video in a
  format this Mac cannot play, ends at the connection timeout and says
  RDPeek could not show it, instead of showing Connecting until
  cancelled.
- Servers list RDPeek's sessions under the Mac's name, and when
  licensing fails with a stored client license, RDPeek connects once
  more without it, so the server can issue a new one.
- macOS's local network prompt now says why RDPeek asks.

### Remote input

- The remote desktop is told the Mac's keyboard layout instead of US
  English, and a key that types the same character there is sent as
  its scancode, so remote input methods see it, letters typed with
  Caps Lock included.
- Right ⌥ types the character it gives on the Mac, such as @ with ⌥L on
  a German layout, and its dead keys compose accents without sending
  Alt; left ⌥ stays Alt. This also works when ⌥ was held before the
  window became key, and right ⌥ then ⌘ reach the remote in that order.
- On a server that takes no Unicode input, typing no longer
  disappears: keys go as their scancodes for the server's own layout,
  with right ⌥ as AltGr.
- ⌘ reaches the remote as the Windows key only together with another
  key or click, or when tapped alone, so ⌘-Tab and Spotlight no longer
  open the remote Start menu; neither do ⌘-clicking a background
  session window, scrolling with ⌘ held, pressing both ⌘ keys, or
  tapping ⌘ or right ⌥ while the other is already held on the remote.
  Releasing right ⌥ after pressing another modifier with it taps no
  Alt, which opened the app's menu bar.
- A dead key's accent is no longer lost when Return, Tab, or Esc
  follows it, and is not typed ahead of a ⌘ or ⌃ shortcut. After an
  Alt shortcut on a dead key with left ⌥, such as ⌥E on a US layout,
  the next key reaches the remote as itself, so Alt+E then A works.
- Keys pressed with ⌘ are released on the remote as soon as they go up,
  so pressing ⌘W twice quickly works.
- Modifiers whose release the window never saw, for example with a
  menu open or Spotlight up, are released on the next event, also while
  connecting, so the remote does not start with one held down, and
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
  start with it off, and Share for 30 Seconds is offered only while
  sharing is off, so it no longer turns off sharing you turned on. To
  allow this, RDPeek always joins the remote clipboard, which makes
  Windows empty its clipboard at connect even with sharing off.
- Copied files are read off the main thread, so a large or iCloud file
  no longer freezes the window.
- Remote files download in 512 KiB ranges, so pasting large files from
  Windows and gnome-remote-desktop no longer fails, even on slow links. A download gives
  way to a newer copy, stops when the server stops answering, and its
  files are deleted once they leave the clipboard, or at a later launch.
- Copied files whose names Windows rejects, or finds too long, are
  renamed, and files with the same name are numbered. Names keep
  zero-width joiners, soft hyphens, and direction marks.
- Files copied from folders on Windows arrive without their folders,
  and RDPeek says so.
- Sync Now sends the Mac clipboard again only when the server does not
  have it, for example a file iCloud had not downloaded, so it never
  strips the formatting of a copy made on the server or cancels a
  download; otherwise it says the clipboard is up to date. “Clipboard
  synced” appears only after Sync Now.
- Turning sharing off, or a 30-second share ending, takes back the
  Mac's copy only while the server still holds it, so a copy made on
  the server since is kept. Text too large to send empties the server's
  clipboard, as files too large do, so its older copy cannot come back.
- With sharing off, nothing of the server's clipboard is fetched. Once
  on, the server's copy at connect reaches the Mac, and files copied on
  the Mac are sent rather than an older server copy.
- When the server empties its clipboard, as a password manager does,
  the Mac clipboard is cleared too while it still holds what came from
  that server. A server copy RDPeek cannot take, such as an image, or
  one that fails to arrive, says so.

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
  sheet is up, the Session menu and the window agree on Connect and
  Reconnect, and the connecting status says why a session reconnects.
- On a 1x display the remote desktop is no longer resized by a pixel
  right after connecting.
- When the server ends a session, the desktop is hidden as after
  Disconnect: the ended screen's buttons can be reached from the
  keyboard, and the last frame no longer stays in memory.
- After the video layer fails, the desktop reappears even when nothing
  on it changes.
- A session window follows edits to its PC: a new name shows at once,
  and other settings apply from the next connection. Connect on a PC
  whose session ended connects that window again, and a window whose
  PC was deleted keeps no password.
- The performance overlay shows only over the live desktop, and its
  rates fall to zero within seconds of the desktop going still, as do
  those in Stats for Nerds.
- Stats for Nerds shows the server's warnings and whether the RSA key
  exchange, without forward secrecy, was used. It shows connection
  details while the session runs and keeps them after Disconnect, counts
  every frame acknowledgement, shows how the server ended a session, the
  client name, redirections, an issued license, the scale sent, and
  whether the server takes Unicode input, and updates only while it is
  open.
- The overlays respect Reduce Motion, and VoiceOver announces session
  messages.

### Connection Center

- Return and Delete act on the selected PC only while the grid has
  focus, not while typing in the search field.
- The PC editor can set the connection timeout, shows validation errors
  where they can be seen, opens without waiting for the Keychain, and
  is no longer discarded by ⌘N.
- PC cards have VoiceOver actions for Connect, Edit, Duplicate, and
  Delete, and VoiceOver reads each card's user, host, and last use. The
  arrow keys move the selection, and the Connection Center respects
  Reduce Motion.
- Saved PCs stay readable when one is damaged or was written by another
  version, and an unreadable list is reported instead of shown empty.
  PCs this version cannot read are kept and counted in a notice, and
  settings a newer version added survive a save.
- Saving the PC editor no longer undoes a Remember Password change, or
  a newer password, a session saved while it was open.
- Changing a PC's host or user keeps its saved password if saving the
  new Keychain item fails, and the editor says when it cannot read the
  saved password; turning Remember off then still removes it.
- Duplicating a PC keeps Remember Password, and deleting one keeps a
  password that another PC still remembers, including one that writes
  the same sign-in as “CORP\bob” instead of “bob” in domain “CORP”.
- A password saved by RDPeek 1.0 under the host name as typed moves to
  its current name in one step, so a deleted one no longer comes back
  and a newer one is not overwritten.

### Under the hood

- Updated to RDPKit 0.5.0: timeouts bound every step before
  the first frame, failures are typed, and Windows, KRdp and
  gnome-remote-desktop video and bitmap codecs are faster and more
  correct. RDPeek's own workarounds for what RDPKit now does (error
  text matching, DOMAIN\user splitting, Windows file names, legacy
  Keychain names, the first-frame timer) are gone.
- Package versions are pinned in Package.resolved, CI builds with a
  pinned Xcode, SwiftLint checks the tests too, and its analyzer guards
  against unused code.

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
