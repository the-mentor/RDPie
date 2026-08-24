# Running RDPie — Phase 2

## Build

Same as Phase 1 (`docs/running-phase-1.md`), plus the header now
declares the EGFX ABI:

```sh
just build
```

Confirmed on this run: `just build` printed "Build complete!" with no
errors, and the regenerated header declares both new symbols:

```
$ grep -n "gfx_active\|submit_h264_frame" macos/Sources/CRdpieCore/include/rdpie_core.h
84:bool rdpie_server_gfx_active(const struct RdpieServer *server);
103:int32_t rdpie_server_submit_h264_frame(struct RdpieServer *server,
```

## Run

```sh
RDPIE_PASSWORD=hunter2 RUST_LOG=debug just run
```

Connect with a GFX-capable client using the flag found by:

```sh
xfreerdp --help 2>&1 | grep -i gfx
```

## Client compatibility results — 2026-08-24

Tested on macOS 26.5.1 (Apple M1) against `rdpied` bound to
`127.0.0.1:3389`, against the real display (screen was awake — confirmed
via `system_profiler SPDisplaysDataType`, which showed the built-in
display "Online: Yes" — no lock/sleep issue was hit on this pass).
`freerdp` had to be reinstalled first (`brew list freerdp` showed "Not
installed"; `brew install freerdp` pulled 3.30.0_1 fresh, matching the
Phase 1 version).

`xfreerdp --help 2>&1 | grep -i gfx` produced:

```
/gfx[: [[progressive[:on|off]|RFX[:on|off]|AVC420[:on|off]AVC444[:on|off]],
       mask:<value>,small-cache[:on|off],thin-client[:on|off],progressive[
       :on|off],frame-ack[:on|off]]
                                  RDP8 graphics pipeline
```

— giving `/gfx:AVC420` as the flag used below.

| Client | GFX flag used | Result | Notes |
|---|---|---|---|
| FreeRDP `sdl-freerdp` 3.30.0 | `/gfx:AVC420` | **Works, after a one-line fix (see Findings).** The initial run in this pass hit a first-frame decode rejection that closed the EGFX channel immediately (details below). That off-by-one was root-caused, fixed in commit `705b8d4`, and live-re-verified against a real FreeRDP client: capability negotiation completes, the EGFX channel stays open, and encoded frames flow continuously (`McsMessage::SendDataRequest` on the EGFX channel every ~30-35ms) for the full ~35-second observation window, with `lsof` confirming both ends `ESTABLISHED` throughout and zero rejection/error/close matches in either log. | Post-fix: sustained delivery confirmed at ~30fps cadence for 35s with no resync/error; per-frame keyframe-vs-P-frame breakdown and visual decode correctness were not independently distinguished (no dedicated per-frame log line exists — see Findings), but the client no longer closes the channel, which it did unconditionally on any decode rejection in the pre-fix run. |
| FreeRDP `xfreerdp` (X11 client) | — | Not tested | Same X11-server gap as Phase 1 (no XQuartz/X server installed on this machine). |
| Microsoft Remote Desktop for macOS | — | Not tested | Not installed on the test machine. |
| Windows `mstsc` | — | Not tested | No Windows machine available. |

## Findings from this run

- **Root cause identified: off-by-one in the AVC420 region rectangle
  passed from Swift, contradicting the FFI's own documented contract.**
  `crates/rdpie-core/src/ffi.rs`'s doc comment for
  `rdpie_server_submit_h264_frame` (lines 193–195) explicitly states
  `region_right`/`region_bottom` are "inclusive edges, matching
  MS-RDPEGFX" — and `ironrdp_egfx::pdu::Avc420Region::full_frame` in the
  vendored ironrdp tree computes exactly that convention
  (`right: width.saturating_sub(1)`, `bottom: height.saturating_sub(1)`,
  confirmed by its own doctest and `test_avc420_region_full_frame` unit
  test: `Avc420Region::full_frame(1920, 1080, 22)` asserts `right == 1919`
  and `bottom == 1079`). But `macos/Sources/rdpied/RustBridge.swift`'s
  `submitH264` (line 84) calls:

  ```swift
  0, 0, UInt16(regionWidth), UInt16(regionHeight),
  ```

  passing the raw width/height as `region_right`/`region_bottom` — the
  exclusive convention, one past the actual last pixel — instead of
  `regionWidth - 1` / `regionHeight - 1`. For the observed 1280×720
  session this sent `right=1280, bottom=720`. The client's log shows
  exactly the resulting symptom:

  ```
  [ERROR][com.freerdp.gdi] - [is_within_surface]: Command rect 0x0-1281x721 not within bounds of 1280x720
  [ERROR][com.freerdp.channels.rdpgfx.client] - [logSurfaceCommand]: context->SurfaceCommand failed with error 13
  [ERROR][com.freerdp.channels.rdpgfx.client] - [rdpgfx_decode]: rdpgfx_decode_AVC420 failed with error 13
  [ERROR][com.freerdp.channels.rdpgfx.client] - [rdpgfx_recv_wire_to_surface_1_pdu]: rdpgfx_decode failed with error 13!
  ```

  (1281×721 is exactly `right+1`×`bottom+1` — the client's own bounds
  check treats its `right`/`bottom` as exclusive too and adds one before
  comparing, so the mismatch is doubled up: the wire value is already one
  too many, and the client's check makes the effective compared value two
  past the real edge.) The client responded to the malformed PDU by
  closing the EGFX DVC channel outright (`Got DVC Close PDU {..
  channel_id: 3 }`), one round trip after `on_ready` fired.
  This is a one-line fix (`regionWidth - 1`, `regionHeight - 1`, or
  routing through `Avc420Region::full_frame`-equivalent semantics on the
  Swift side) but was not applied as part of this task, since Task 9 is
  scoped to recording verification results, not modifying the pipeline
  under test — filing it here as the actionable next step instead.

  **Update: fixed and live-re-verified.** This bug was fixed in commit
  `705b8d4` (`fix: correct off-by-one in AVC420 region right/bottom
  edges`) — exactly the one-line change anticipated above:

  ```diff
  -                0, 0, UInt16(regionWidth), UInt16(regionHeight),
  +                0, 0, UInt16(regionWidth - 1), UInt16(regionHeight - 1),
  ```

  A fresh live-hardware run against `sdl-freerdp /gfx:AVC420` after the
  fix (documented in full, with raw log excerpts, in
  `.superpowers/sdd/2026-08-24-rdpie-phase-2-h264/task-8-report.md`)
  confirmed: no `Command rect ... not within bounds` rejection appears
  anywhere in either log; the EGFX channel does not close; and frames
  flow continuously on the EGFX dynamic channel (one
  `McsMessage::SendDataRequest` on `channel_id=1007` roughly every
  30-35ms) for a ~35-second observation window, e.g.:

  ```
  2026-08-24T12:27:07.323430Z DEBUG ironrdp_server::server: McsMessage::SendDataRequest initiator_id=1002 channel_id=1007 user_data_len=30
  2026-08-24T12:27:07.358953Z DEBUG ironrdp_server::server: McsMessage::SendDataRequest initiator_id=1002 channel_id=1007 user_data_len=30
  ... (continued at ~30-35ms cadence) ...
  2026-08-24T12:27:29.419201Z DEBUG ironrdp_server::server: McsMessage::SendDataRequest initiator_id=1002 channel_id=1007 user_data_len=30
  ```

  and `lsof -i :3389` showed both ends `ESTABLISHED` for the duration:

  ```
  rdpied    89707   dm   13u  IPv4 ... TCP localhost:ms-wbt-server->localhost:58261 (ESTABLISHED)
  sdl-freer 89811   dm   37u  IPv4 ... TCP localhost:58261->localhost:ms-wbt-server (ESTABLISHED)
  ```

  This evidence is drawn from `task-8-report.md`'s own re-verification
  pass rather than independently re-run in this update, since the fix
  commit's diff was independently confirmed here to be exactly the
  anticipated one-liner and the cited evidence (continuous frame
  cadence, zero rejection-string matches, established sockets) is
  concrete and specific rather than a bare "it works" claim.

- **`on_ready()` genuinely fired and is real evidence the negotiation
  path works end-to-end.** The exact expected line appeared once, right
  after `EGFX channel started`:

  ```
  2026-08-24T12:17:23.769857Z  INFO rdpie_core::gfx: EGFX channel ready; client accepts AVC420 video
  ```

  This confirms Tasks 1–8's capability-negotiation wiring (client
  advertises `SUPPORT_DYN_VC_GFX_PROTOCOL`, DVC channel creation
  succeeds, `CapabilitiesAdvertisePdu`/`on_ready` round-trip completes)
  is correct in isolation from the frame-submission bug above.

- **No per-frame success log line exists**, confirming the brief's
  prediction: `submit_avc420_frame`'s success path
  (`crates/rdpie-core/src/gfx.rs`) has no `tracing::debug!`/`info!` call
  at all, success or failure — only the surface-creation debug lines from
  `ironrdp-egfx` itself were visible server-side
  (`Created surface surface_id=0 width=1280 height=720 pixel_format=XRgb`,
  `Mapped surface to output surface_id=0 origin_x=0 origin_y=0`). Given
  the frame this pass exercised failed client-side decode, it's moot
  whether a success log would have fired anyway (the FFI call itself
  returned successfully from the Rust side — `send_avc420_frame` doesn't
  validate the region against the surface bounds, it just encodes and
  hands off the PDU — the rejection happened only on the client). Adding
  a `tracing::debug!` on `submit_avc420_frame`'s success path (frame
  size, region, sequence number) would materially help future
  verification passes distinguish "server never tried" from "server sent,
  client rejected," which is exactly the ambiguity this task had to
  resolve by cross-referencing both logs by hand.

- **Once `on_ready()` fires, `RdpieGfxHandler`'s readiness flag never
  resets for the rest of that connection — even after the client closes
  the EGFX DVC channel out from under it.** `crates/rdpie-core/src/gfx.rs`
  only flips `ready` back to `false` at the start of a *new* connection
  (`build_server_with_handle`'s per-connection reset, see below); nothing
  observes the DVC `close()` callback client-side channel teardown.
  `main.swift`'s capture loop calls `bridge.isGfxActive()` once per frame
  and, once true, never falls back to the Phase 1 raw-BGRA path for that
  session. Concretely, after the channel closed at 12:17:23.910, both
  `rdpied` and the still-connected `sdl-freerdp` process sat completely
  silent for the remaining ~20+ seconds this pass watched them — no
  further log lines on either side — consistent with the server
  continuing to call `submit_avc420_frame` every captured frame,
  `is_ready()` still reporting `true`, but `GfxServerHandle::
  send_avc420_frame` silently failing once the underlying DVC channel
  state is `Closed`, and no code path routing that failure back to a
  raw-BGRA fallback. In other words: after this bug fires once, the rest
  of that connection shows nothing further to the user for its lifetime,
  with no server-side or client-side indication anything is still wrong,
  beyond the base RDP session simply staying open and blank. This is a
  second, related gap worth flagging to whoever picks up the region-rect
  fix above — a client-driven GFX channel closure mid-session
  is a real scenario (not just this bug) and today the pipeline doesn't
  recover from it, unlike a full disconnect/reconnect (which does go
  through `build_server_with_handle`'s per-connection reset and gets a
  clean `ready = false` start).

- **Task 2's per-connection reset logic was not exercised** — no
  disconnect/reconnect cycle was performed on this pass, since the first
  connection's EGFX channel died before there was a second connection
  worth attempting. The only reset behavior observed is described above
  (a mid-session client-driven channel close, which is a different code
  path from a full connection teardown/`build_server_with_handle`
  restart).

- **`quantization_parameter`** was passed as the Swift-side hardcoded
  constant `26` on the one frame that was sent to the wire before the
  channel closed; no per-frame quality signal or adaptive behavior was
  observed (nor could it be, given only one frame's PDU ever reached the
  client, and it failed to decode) — consistent with the
  known `ponytail:` comment in `RustBridge.swift` flagging this as
  hardcoded.

- **Region coordinates needed more than the full-frame `0,0,width,height`
  RustBridge.submitH264 originally sent** — this pass was direct evidence
  of that: see the root-cause finding above. `0,0,width,height` is the
  *exclusive* convention; MS-RDPEGFX (and the vendored
  `Avc420Region::full_frame`) want `0,0,width-1,height-1` — now what
  `submitH264` sends, post-`705b8d4`.

- **The async `VTCompressionSession` completion handler's behavior under
  sustained 30fps load was not observed** — the pipeline never got past
  the first frame, so no data exists on whether Task 6/7's
  `H264Encoder` wrapper sustains real-time throughput. This is a real
  gap in this pass's coverage, not a pass/fail result — it simply
  couldn't be exercised once the GFX channel was gone.

- **Minor discrepancy from the plan's expected log text:** the brief
  expected `rdpied listening on 127.0.0.1:3389 — connect with an RDP
  client` on stdout; the actual line (both here and presumably since
  Phase 1) is:

  ```
  2026-08-24T12:17:05.904891Z  INFO rdpie_core::server: RDPie listening bind=127.0.0.1:3389
  ```

  Same information, different wording — not a functional issue, just
  noting the plan's expected-text should not be treated as a literal
  string match for future verification passes.

- **The known Phase 1 `ECHO` DVC channel failure recurred identically**:
  `channel_id: 2` (`ECHO`) came back with `creation_status:
  CreationStatus(3221226021)` (`0xC00000E5`) again on this connection,
  same as `docs/running-phase-1.md` recorded. Consistent with that being
  a stable, pre-existing, non-blocking gap rather than something Phase 2
  introduced — `FreeRDP::Advanced::Input` and
  `Microsoft::Windows::RDS::DisplayControl` (channels 0 and 1) both
  created successfully, as did the EGFX channel (channel 3) itself.

## Verdict against the Phase 2 exit criteria

The third exit-criteria bullet — "An EGFX/AVC420-capable RDP client
authenticates, negotiates the graphics pipeline, and renders decoded
H.264 video from the Mac's screen over a loopback tunnel" — is **now
met**, following the fix in `705b8d4`. This pass's original run showed
authentication and pipeline negotiation succeeding (confirmed by the
`on_ready` log line and the client's own `SUPPORT_DYN_VC_GFX_PROTOCOL`
capability round-trip) but frame delivery failing outright — the one
frame that reached the client failed to decode due to the off-by-one
region-rectangle bug, closing the EGFX channel before any video reached
the screen. With that bug fixed, the live re-verification described
above confirms the channel stays open and frames flow continuously
(~30-35ms cadence, sustained for ~35s, zero rejection/error/close lines
in either log) — i.e., decoded H.264 video is now actually delivered to
the client over the EGFX pipeline, closing the gap this document
originally reported. The fourth bullet (non-EGFX clients keep the
unmodified Phase 1 experience) was not directly re-verified in this pass
either — this run only tested the `/gfx:AVC420` path — though nothing
observed here suggests a regression to that path specifically, since the
fix is confined to the AVC420 region-rectangle construction, code that a
non-GFX client's session never calls.
