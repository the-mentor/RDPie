# Running RDPie — Phase 5 (Clipboard)

## What changed

Adds bidirectional plain-text clipboard sync via CLIPRDR (MS-RDPECLIP).
`crates/rdpie-core/src/clipboard.rs` implements `CliprdrBackend`; Swift
polls `NSPasteboard.general.changeCount` inside the existing capture loop
(no new timer) and writes remote-copied text back via a new FFI callback.

Deliberately out of scope: RTF, images, files, clipboard locking. See the
plan's header (`docs/superpowers/plans/2026-08-25-rdpie-phase-5-clipboard.md`)
for the two documented deviations from the design spec's original v1
clipboard scope.

No new server-side permission or environment variable: CLIPRDR only
activates if the connecting RDP client opens that channel (e.g. mstsc's
"Clipboard" checkbox under Local Resources), exactly like EGFX only
activates when a client negotiates it.

## Build

```sh
just build
```

## Run

```sh
RDPIE_PASSWORD=<password> RDPIE_USERNAME=<username> just run
```

## Verification checklist for a live pass

- [x] Connect with a real RDP client that has clipboard redirection enabled
      (mstsc: Show Options → Local Resources → Clipboard, checked).
- [x] Copy text on the Mac, paste it on the remote client. Confirm it
      arrives correctly.
- [x] Copy text on the remote client, paste it on the Mac. Confirm it
      arrives correctly.
- [ ] Copy text on the Mac, then immediately copy something *different* on
      the Mac before pasting anywhere — confirm the remote receives the
      second, most recent text (not the first).
- [ ] Copy text on the Mac, paste it back into a Mac app (not the remote)
      — confirm this does not create a feedback loop that spams
      re-advertisements (watch `RUST_LOG=debug` output for repeated
      `SendInitiateCopy` messages that don't correspond to an actual new
      copy).
- [ ] Confirm a non-text copy on either side (e.g. copying a file in
      Finder, or an image) does not crash or hang the session — it should
      simply not sync, silently.
