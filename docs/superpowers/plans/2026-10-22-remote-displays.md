# Remote Display Selection Implementation Plan

> For agentic workers: use superpowers:subagent-driven-development. Each task
> receives spec and code-quality review. Track steps below.

**Goal:** Select all or any subset of server-reported displays in a macOS session.

**Architecture:** RDPKit exposes session topology on decoded graphics frames.
RDPeek computes one shared display viewport for rendering and input. SwiftUI
controls send actions through SessionHUDModel to SessionViewController.

**Tech Stack:** Swift 6, AppKit, SwiftUI, AVFoundation, XCTest, Swift Package Manager.

### Task 1: RDPKit monitor metadata

- [x] Read graphics reset, compositor, hardware decode and frame propagation.
- [x] Add failing tests for monitor metadata surviving every presentation path.
- [x] Expose monitor layout on frame snapshots/metadata with compatible defaults.
- [x] Run focused and full Swift tests; preserve 0.3.1 behavior without metadata.
- [x] Review, commit and publish the dependency branch to the user's fork.

### Task 2: Selection and viewport

Files: Sources/Session/RemoteDisplaySelection.swift,
Tests/RemoteDisplaySelectionTests.swift, project.yml.

- [x] Add tests for all/single/nonadjacent selection, invalid layouts, negative
      origins, letterboxing, unselected gaps and topology replacement.
- [x] Implement pure selection and viewport geometry. Use reported monitor order
      for labels; normalize desktop coordinates against the layout bounds.
- [x] Run `xcodegen generate` and `xcodebuild -project RDPeek.xcodeproj -scheme
      RDPeek -destination 'platform=macOS' -derivedDataPath DerivedData test
      CODE_SIGNING_ALLOWED=NO`.

### Task 3: Presentation, input and controls

Files: RemoteDesktopRenderer.swift, RemoteDesktopCanvasView.swift,
RemoteInputCaptureView.swift, SessionHUD.swift, SessionViewController.swift.

- [x] Add regression tests for viewport pointer mapping and held-input release.
- [x] Present selected portions of the complete desktop, using the same geometry
      for display placement and pointer conversion; reject hidden screen input.
- [x] Wire topology changes and selection through render and SessionHUDModel.
- [x] Add All Displays and monitor toggles to the existing titlebar menu; prevent
      deselecting the last monitor and collapse-to-single automatic resize.
- [x] Reset topology/selection on reconnect and preserve cursor/input conventions.

### Task 4: Fork pin and verification

Files: project.yml, README.md, Sources/App/HelpView.swift.

- [x] Pin dan-hart/RDPKit to its tested immutable revision and explain upstream
      relationship plus physical-sharing/virtual-session capability limits.
- [x] Run full RDPeek tests, strict lint and clean macOS build, launch app.
- [x] Review the complete diff for spec compliance and code quality.
Publication target: steelbrain/remote-display-selection in dan-hart/RDPeek.
Verify remote heads after pushing; keep upstream main unchanged.


## Verification record

- RDPKit fork revision: `515d387ecd10a5fa5c579ac992ba0bf160d652db`.
- RDPKit: 998 tests passed, strict SwiftLint clean. Mutation checks verified that
  removing legacy layout hooks fails finalization, handshake and live tests.
- RDPeek: clean build and tests from the remote revision with fresh DerivedData;
  74 tests executed, one skipped, zero failures. Strict SwiftLint clean.
- Live Linux desktop sharing: two 1920×1080 displays enumerated. Both together,
  each separately, letterboxing, last-display protection, and pointer input on
  the isolated second display were observed. The final remotely pinned build
  also connected and enumerated both screens; the test connection was closed.
- One live run ended with the existing AVC444 missing-luma decode error. Decoder
  source is identical to upstream 0.3.1; the app still uses its existing fatal
  decode policy. Independent commit `8abe6d6` documents that same failure and
  is intentionally separate from this feature. A baseline replay was not captured,
  so sustained session stability is not established by this validation.
- Real virtual-session and cross-OS server acceptance remain unverified. Automated
  tests cover synthetic physical/virtual-equivalent layouts, including arbitrary
  subsets, stacked layouts, negative origins and topology replacement.


## Adversarial review follow-up

The app and dependency changes received independent adversarial review. The
confirmed findings were in the dependency; the final app review found no
additional production defect.

| Finding | Repair and regression coverage |
| --- | --- |
| Messages after EndFrame were discarded | Process the whole payload; test live and finite capture limits, layouts, callbacks and acknowledgements. |
| Messages accompanying CapsConfirm were discarded | Process already-decoded remainder; test plain and segmented/coalesced transport. |
| Coalesced processing could continue after cancellation | Check cancellation before each message/callback and before acknowledging a callback that cancels. |
| AVC444 luma was keyed by changing update bounds | Retain bounded surface/codec samples by updated regions; compare CPU and Metal output pixels. |
| Full-coded and region-local mask coordinates were confused | Resolve source origin using coded and visible surface dimensions; test nonzero bounds. |
| Partial luma IDRs could discard regional history | Require known complete surface coverage before treating an AVC444 IDR as a backlog recovery point. |
| Empty masks and dimension/local-image transitions could overwrite or reuse invalid state | Preserve no-op updates, invalidate resized coverage and retain sampling phases without mutating decoder-owned buffers. |

These are source-level repairs; decode failures are still reported rather than
silently ignored. Independent re-review approved the final fixes. RDPKit's
complete suite passed 1,012 tests and strict SwiftLint. RDPeek built from the
published immutable dependency revision and passed 74 tests (one skipped), plus
strict SwiftLint. The package checkout revision was read back from Xcode's
workspace state.
