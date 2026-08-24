# Spike: does CGEventPost inject synthetic input, and how does Accessibility TCC attribute it?

**Hardware:** Mac mini (Macmini9,1), Apple M1
**macOS:** 26.5.1 (build 25F80)
**Date:** 2026-08-24

## Procedure

Built a raw CLI binary calling `AXIsProcessTrusted()`/`AXIsProcessTrustedWithOptions(prompt: true)`,
then, once trusted, posting a synthetic keyboard keypress (`kVK_ANSI_A`) and a
synthetic mouse-move event via `CGEvent(...).post(tap: .cghidEventTap)`. Ran
from an interactive terminal (iTerm2), same pattern as the Screen Recording
and TCC-attribution spikes from Phase 0-1.

## Result

- **TCC attribution matches Phase 0-1's Screen Recording finding exactly**:
  the Accessibility prompt named the containing terminal app ("iTerm2.app"),
  not the raw binary — "'iTerm2.app' would like to control this computer
  using accessibility features."
- **Keyboard injection confirmed twice, directly observed**: the synthetic
  'A' keypress landed in the terminal's own input stream both runs — visible
  inline in the captured output as a stray `a` character appearing exactly
  where the keydown/keyup pair was posted, mid-print-statement.
- **Mouse injection confirmed programmatically**, not just by eye: posting a
  move to `(600, 400)` and reading the cursor position back via
  `CGEventCreate(nil)?.location` afterward returned exactly `(600.0,
  400.0)` — an exact match, not an approximation.
- No entitlement, code signature, or elevated privilege was needed beyond
  the standard Accessibility TCC grant — this was a plain, unsigned,
  ad-hoc-built CLI binary.

## Answer to spec §5.3 / §6 / Phase 3 open question

`CGEventPost` genuinely injects both keyboard and mouse input system-wide
once Accessibility access is granted to the responsible (containing) app —
confirmed by direct observation (keyboard) and by reading the actual OS
cursor state back after the fact (mouse), not just assuming success from a
lack of error. This is the mechanism spec §5.3 assumes; it works as
described.

## Implication for Phase 3

Accessibility TCC attributes to the containing app exactly like Screen
Recording did — this reinforces the Phase 0-1 finding that the real, signed
`RDPie.app` bundle (not a loose `rdpied` binary) is what should carry the
grant once packaged (Phase 7), and that development/testing from a terminal
will always show the terminal app's name in the permission prompt, not
`rdpied`'s.

## Caveats

- Single data point: one Mac, one macOS version, one terminal app identity
  (iTerm2). Not verified under the packaged daemon's real signed identity.
- Coordinates posted were in the main display's global coordinate space;
  multi-monitor coordinate mapping (RDP client coordinates → the correct
  macOS display's global space) was not exercised here — out of scope for
  this spike, relevant when Phase 3 actually implements the RDP→CGEvent
  coordinate translation.
- `AXIsProcessTrusted()` mid-session revocation (spec §6's error-table row)
  was not tested — only the initial grant flow.
