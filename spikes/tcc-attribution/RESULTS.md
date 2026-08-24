# Spike: TCC grant attribution for a bundled SMAppService agent

**Hardware:** Mac mini (Macmini9,1), Apple M1
**macOS:** 26.5.1 (build 25F80)
**Signing:** ad-hoc only (`codesign --sign -`). Developer ID was not tested —
see Caveats.
**Date:** 2026-08-24

## Procedure

`probe-agent` was built and assembled into `Probe.app` (Contents/MacOS +
Contents/Library/LaunchAgents, per spec §4.1's layout), ad-hoc signed, then
registered via `SMAppService.agent(plistName:).register()` with a
`RunAtLoad` LaunchAgent plist using the `BundleProgram` key. On registration,
launchd immediately launched the agent, which called
`CGRequestScreenCaptureAccess()`.

## Answers to spec §8 open question (2)

1. **Does a TCC prompt appear when a background agent calls
   `CGRequestScreenCaptureAccess()`?** Yes — immediately, with no delay,
   the moment the agent's request-access call executed after `RunAtLoad`
   launched it.

2. **Does the agent appear under its own name, the containing app's name, or
   not at all?** Under the bundle's name — "Probe.app" — appearing as its own
   independent entry in System Settings → Privacy & Security → Screen & System
   Audio Recording, alongside unrelated apps (AltTab.app, iTerm2.app,
   Mumble.app) as separate peers. Nothing else appeared for the raw
   `probe-agent` executable name.

3. **Does a grant to the containing app cover the agent, or are they
   separate?** In this spike the "containing app" and "the agent" are the
   same signed bundle (`Probe.app` contains only `probe-agent`, which serves
   both the register-caller and the launchd-invoked roles — see
   `main.swift`'s `--register`/`--status` vs. no-argument paths). The TCC
   grant attached to that one bundle identity: `CGPreflightScreenCaptureAccess()`
   read `false` before granting and `true` after, when re-invoked as the
   same executable. This is directly relevant to the real architecture (spec
   §4.1), where `RDPie` and `rdpied` are two executables inside **one**
   signed bundle: the result here suggests both would share the same TCC
   identity, so a grant should cover both — but this was not directly tested
   with two distinct executables in one bundle (see Caveats).

4. **macOS version and signing:** macOS 26.5.1 (25F80), ad-hoc signed only.
   Developer ID signing was not tested; TCC is documented to treat ad-hoc and
   Developer ID identities differently, so this result should be re-verified
   once real signing credentials exist.

## Raw log (`/tmp/rdpie-tcc-probe.log`, after granting)

```
[2026-08-24T09:07:54Z] bundle id: com.rdpie.tccprobe.app
[2026-08-24T09:07:54Z] executable: .../Probe.app/Contents/MacOS/probe-agent
[2026-08-24T09:07:54Z] screen recording preflight: true
[2026-08-24T09:07:54Z] accessibility trusted: false
[2026-08-24T09:07:54Z] requesting screen capture access…
[2026-08-24T09:07:54Z] request returned: true
[2026-08-24T09:07:54Z] screen recording preflight after request: true
```

`--status` after granting reported `SMAppServiceStatus(rawValue: 1)`, i.e.
`.enabled`.

## Caveats

- Single data point: one Mac, one macOS version, ad-hoc signing only.
- The spike's `Probe.app` has one executable playing both the "containing
  app" and "the agent" roles, rather than two separate executables in one
  bundle as spec §4.1 describes for the real product. The bundle-level
  attribution finding likely generalizes, but wasn't proven with two
  distinct binaries.
- Only Screen Recording was exercised; Accessibility (`AXIsProcessTrusted`)
  was probed but never requested, so its prompt behavior is unverified.
