# Running RDPie — Phase 3

## Build

Same as Phase 1/2 (`docs/running-phase-1.md`), plus the header now
declares the input ABI:

```sh
just build
```

Confirmed the regenerated header declares the new symbols:

```sh
grep -n "RdpieInputEvent\|RdpieInputCallback\|input_callback" macos/Sources/CRdpieCore/include/rdpie_core.h
```

## Run

```sh
RDPIE_PASSWORD=hunter2 RUST_LOG=debug just run
```

See "Testing from a real RDP client, not just loopback" below for
`RDPIE_BIND_ALL`, and "Matching a client's desktop size" for
`RDPIE_WIDTH`/`RDPIE_HEIGHT`.

### Matching a client's desktop size

The daemon presents a fixed desktop size (1280×720 by default) — dynamic
resize negotiation is Phase 6, not this one. A client whose real viewport
doesn't match that size may not tolerate the mismatch gracefully: during
Phase 3 live testing, a mobile client (1080×1920 portrait) closed its
graphics channel and dropped the connection outright shortly after capability
negotiation, rather than letterboxing or scrolling. If a client disconnects
right after negotiating EGFX with no input ever exchanged, check
`RUST_LOG=debug` output for a `Client size doesn't fit the server size`
warning — that's this mismatch, not an input-injection bug.

Override the desktop size to match a specific client:

```sh
RDPIE_PASSWORD=hunter2 RDPIE_WIDTH=1080 RDPIE_HEIGHT=1920 just run
```

Defaults to 1280×720 if unset.

### Granting Accessibility

`rdpied` now checks Accessibility at startup and warns (but keeps running
in view-only mode) if it's missing — unlike Screen Recording (exit code 3),
which is load-bearing for the whole product and still hard-exits if
missing. Grant Accessibility in **System Settings › Privacy & Security ›
Accessibility**. Like Screen Recording, TCC attributes the grant to the
*containing* app, not the `rdpied` binary itself — running from a terminal
during development prompts for that terminal app (e.g. "iTerm2.app would
like to control this computer using accessibility features"), not
`rdpied` (see `spikes/cgevent-injection/RESULTS.md`). The packaged
`RDPie.app` bundle (Phase 7) is what should actually carry this grant in
production.

If Accessibility is revoked while `rdpied` is already running with a
client connected, the session stays open and view-only — captured
frames keep flowing, input events are silently dropped, and a
"Accessibility permission revoked — continuing in view-only mode." line
appears on stderr once, on the frame where the revocation is first
observed.

### Testing from a real RDP client, not just loopback

By default `rdpied` only accepts connections from the same machine (spec
section 8.5's mandated default). To test input from an actual device on
your network:

```sh
RDPIE_PASSWORD=hunter2 RDPIE_BIND_ALL=1 just run
```

This binds all interfaces, not just loopback. Do not do this on a network
you don't trust, and never expose port 3389 directly to the internet — see
the top-level README's network-exposure warning (VPN/Tailscale/SSH tunnel
for anything beyond a trusted LAN). Omit `RDPIE_BIND_ALL` (or set it to
anything other than `1`) to stay loopback-only.

## Verification checklist for a live pass

- [x] Connect with an RDP client and confirm keyboard input (a plain
      letter, a digit, an arrow key, Backspace/Delete) reaches the
      focused application on the Mac. Confirmed live from a mobile
      device over `RDPIE_BIND_ALL=1` — see the EGFX caveat below.
- [x] Confirm mouse move, left-click, and right-click all work. Confirmed
      live alongside the keyboard check above.
- [ ] Confirm vertical scroll moves content in the expected direction
      (`scroll_delta`'s sign is passed straight through from the RDP wire
      value — see `InputInjector`'s `ponytail:` comment on the scroll
      case if the direction or magnitude looks wrong).
- [ ] Revoke Accessibility mid-session (System Settings) and confirm the
      session does *not* disconnect, video keeps updating, and input
      stops being applied.
- [ ] Re-grant Accessibility mid-session and confirm input resumes without
      a reconnect.
- [ ] Known limitation, not a bug to chase: a plain CapsLock keyDown/keyUp
      does not latch the lock state on macOS (that needs
      `IOHIDSetModifierLockState`, out of scope for this phase) — CapsLock
      may not visibly toggle even though the event was injected.

### Fixed: some clients used to disconnect during EGFX/AVC420 negotiation

At least one mobile RDP client (Microsoft's official Android app) was
closing the EGFX channel and dropping the connection ~45ms after
accepting AVC420 capabilities, before the daemon's first encoded frame
was ready. Pre-warming the H.264 encoder (`main.swift`'s
`freshH264Encoder`) cut that latency roughly in half but didn't change
the client's close-timing at all — it stayed a constant ~43-47ms
regardless of desktop size or encoder speed, which ruled out a frame-race
explanation and pointed at the client expecting to see
`ResetGraphics`/`CreateSurface` shortly after negotiation rather than
whenever a captured frame happened to be ready.

Root cause: `crates/rdpie-core/src/gfx.rs` only created and mapped the
EGFX surface lazily, bundled with the first frame submission — so a
client got no acknowledgment at all until capture and encoding produced
something, which could take longer than this client's patience. Fixed by
creating and flushing the surface proactively, as soon as the client
accepts capabilities (`GraphicsPipelineHandler::on_ready`), decoupled
from frame timing entirely. Live-tested against the same client that
surfaced the issue.

(Disabling the graphics pipeline entirely — commenting out
`.with_gfx_factory(...)` in `server.rs` to force the plain bitmap/RemoteFX
fallback — was used during investigation to confirm the problem was
AVC420/EGFX-specific, not a general connection or input-path issue. No
longer needed now that the real fix is in.)
