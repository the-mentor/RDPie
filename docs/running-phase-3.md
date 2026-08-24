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

No new environment variables were added for Phase 3.

### Granting Accessibility

`rdpied` now checks Accessibility at startup (exit code 4, with a message,
if it's missing) the same way it already checks Screen Recording (exit
code 3). Grant it in **System Settings › Privacy & Security ›
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

- [ ] Connect with an RDP client and confirm keyboard input (a plain
      letter, a digit, an arrow key, Backspace/Delete) reaches the
      focused application on the Mac.
- [ ] Confirm mouse move, left-click, and right-click all work.
- [ ] Confirm vertical scroll moves content in the expected direction
      (`scroll_delta`'s sign is passed straight through from the RDP wire
      value — see `InputInjector`'s `ponytail:` comment on the scroll
      case if the direction or magnitude looks wrong).
- [ ] Revoke Accessibility mid-session (System Settings) and confirm the
      session does *not* disconnect, video keeps updating, and input
      stops being applied.
- [ ] Re-grant Accessibility mid-session and confirm input resumes without
      a reconnect.
