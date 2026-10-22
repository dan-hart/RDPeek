# Remote display selection

RDPeek on macOS displays physical desktop-sharing sessions and virtual RDP
sessions using the same server-reported monitor topology. Compatibility depends
on the remote RDP server exposing those displays; the client cannot enumerate
hardware the server does not share. Do not guess monitor boundaries from frame
dimensions or surface IDs, or claim that RDP monitor order matches OS display IDs.

## Behavior

- The session titlebar menu contains Displays, All Displays, and numbered monitor
  toggles. Any nonempty subset is supported, including nonadjacent monitors.
- All Displays is the default and follows new layouts. Explicit selections are
  reconciled by exact monitor descriptor (position, dimensions, flags) when the
  layout changes, falling back to all if none remain. Reordering must not silently
  select another monitor. Monitor numbers follow server order, not OS identity.
- Selected monitors retain their relative arrangement. Excluded displays and gaps
  are black and reject pointer input. Pointer coordinates map into the original
  session desktop. Changing selection releases held inputs before remapping.
  Apply frame and topology together so input never uses a newer layout than the
  visible frame. Normalize signed monitor coordinates against layout bounds;
  preserve zero-based graphics output coordinates for actual input events.
- Selecting displays changes only viewing, never the server layout. Automatic
  window matching must not collapse a multi-monitor layout to one display.
- If monitor metadata is unavailable, show the complete desktop and explain that
  the server did not supply individual display information.
- Metadata belongs in RDPKit; selection and geometry belong in Sources/Session.
  SwiftUI controls use SessionHUDModel populated by SessionViewController.render().
  Informational overlays remain pass-through and the local cursor stays visible.

## Integration

Extend RDPKit 0.3.1 on its own branch in dan-hart/RDPKit, preserving public API
compatibility. Expose raw server monitor descriptors alongside graphics
frames, propagate them through hardware and bitmap composition, and clear them
on reset. RDPeek validates rectangle order, extents, duplicates and overlaps
against the composed frame before offering display choices; invalid topology
uses the full desktop. RDPeek pins the fork to the exact tested commit until upstream can
release that API. Keep the original RDPKit URL documented for upstreaming.

## Validation

Tests cover topology propagation, single/all/subset selection, gaps, negative
monitor origins, layout replacement, input mapping and held-button release.
Run RDPKit tests, RDPeek tests, strict SwiftLint, a clean macOS build, and launch
the app. Physical and virtual server validation is a separate acceptance check;
do not describe it as verified without actual server evidence.
