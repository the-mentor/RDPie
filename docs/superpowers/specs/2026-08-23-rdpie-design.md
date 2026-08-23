# RDPie — Design

**Status:** Draft for review
**Date:** 2026-08-23

RDPie is a native RDP server for macOS. It lets any standard RDP client —
Windows `mstsc`, Microsoft Remote Desktop, FreeRDP, iOS/Android clients —
connect to and control a Mac, including while the Mac's screen is locked.

## 1. Goals and non-goals

### Goals

- Serve RDP from macOS with display, keyboard, and mouse control.
- Keep working when the screen is locked and the user remains logged in.
- Clipboard sync, audio output, and dynamic resize in v1.
- Multi-monitor in v1 *if it proves stable*; it carries an explicit descope
  trigger to v2 (see §5.5) and nothing else may depend on it.
- Ship as an open-source, notarized, installable macOS app under the MIT license
  (matching the repository's existing `LICENSE`). IronRDP is MIT OR Apache-2.0,
  which is compatible.
- Keep the protocol engine free of Apple dependencies so it is testable on Linux CI.

### Non-goals

- **Login-window support.** Serving the screen before any user logs in, or after
  logout, is explicitly out of scope. See §3.2 for why.
- **File transfer (RDPDR drive redirection).** Deferred to v2.
- **RemoteApp / seamless windows, session shadowing, multi-user concurrent
  sessions.** Out of scope entirely.
- Replacing Apple Screen Sharing for users who are happy with it.

## 2. Prior art

**MacRDP** (https://github.com/x6nux/macrdp, GPL-3.0) is a native macOS RDP
server built on a *fork* of `ironrdp-server` with GFX/AVC444 extensions. It is
prior art and a useful reference, but not a base: its GPL-3.0 license would be
inherited by anything built on it, which conflicts with shipping RDPie under MIT.

**FreeRDP's shadow server** (`server/shadow/Mac`) was the obvious starting point
and was rejected. FreeRDP issue #10558 — still open, labelled `help-wanted` —
records that the macOS backend fails to build against the macOS 15 SDK because it
depends on six obsoleted `CGDisplayStream*` functions. Adopting it would mean
porting a C backend to ScreenCaptureKit and maintaining that fork indefinitely.

## 3. Key decisions

### 3.1 Protocol foundation: upstream `ironrdp-server`

RDPie builds on Devolutions' `ironrdp-server` (Rust, MIT/Apache-2.0), which
describes itself as an extendable skeleton for implementing custom RDP servers.
It provides the connection sequence, TLS 1.2/1.3, NLA via CredSSP (NTLM and
Kerberos), RDP 6.0 bitmap compression, RemoteFX, optional NSCodec and QOI, and
the CLIPRDR, RDPSND, RDPDR and Display Control channels. Its client-side stack is
production infrastructure at Cloudflare Access, Teleport, and Devolutions Gateway.

The extension points RDPie implements are the `RdpServerDisplay`,
`RdpServerDisplayUpdates`, and `RdpServerInputHandler` traits.

As of 0.13.0 the crate ships an `egfx` feature exposing `send_avc420_frame()` and
`send_avc444_frame()`. This is the capability MacRDP forked to obtain; it is now
upstream, so RDPie is not expected to need a fork.

Upstream is vendored as a git submodule at `third_party/ironrdp`, pinned to tag
`ironrdp-server-v0.13.0`, and bound in via `[patch.crates-io]` so that routine
version bumps remain a one-line change. See `third_party/README.md`.

**Toolchain floor:** Rust 1.94 (`ironrdp-server`'s `rust-version`).

### 3.2 Process model: a LaunchAgent, not a LaunchDaemon

This decision is what makes the locked-screen requirement work, and what makes
the login-window case impossible, so it is worth stating precisely.

Screen capture and event injection both require a connection to WindowServer,
which exists only inside a user's GUI (Aqua) session. A system-domain
LaunchDaemon has no such connection: at the login window, ScreenCaptureKit
returns null frames or fails to initialise for lack of a graphical context, no
TCC prompt can appear because no user session exists to show it, and a daemon
cannot bridge into `loginwindow`'s Mach bootstrap namespace. macOS 15 added a
`com.apple.developer.persistent-content-capture` entitlement for screen-sharing
products; obtaining it is not a path RDPie will pursue.

A LaunchAgent lives *inside* the user's session. Screen lock does not end that
session — the user stays logged in and WindowServer keeps running — so the agent
keeps its connection across lock. It terminates at logout, which is exactly the
boundary declared out of scope.

### 3.3 Language split: Swift for platform, Rust for protocol

Each side uses APIs that are first-class in its own language. ScreenCaptureKit,
VideoToolbox, CoreAudio, `CGEvent`, `NSPasteboard`, Keychain, TCC, and
`SMAppService` are used from Swift, where they are documented and idiomatic. The
RDP protocol is handled by Rust, which never touches an Apple framework.

The alternative — driving ScreenCaptureKit and CoreAudio through Rust `objc2`
bindings — was rejected: those bindings are immature enough that they would
become a sub-project in their own right.

### 3.4 macOS floor: 14.0 (Sonoma)

Driven by API requirements: ScreenCaptureKit needs 12.3+, `SCStream` system-audio
capture needs 13+, `SMAppService` needs 13+. 14.0 is chosen over 13.0 to reduce
the support matrix and to match prior art. macOS 15 changed how Screen Recording
permission is presented in System Settings; RDPie must handle both presentations.

### 3.5 Authentication: dedicated credential, with an optional PAM gate

RDP clients expect NLA/CredSSP. With NTLM the server must hold the NT hash (MD4
of the UTF-16LE password) to verify the client's NTLMv2 response. macOS stores
account passwords as a salted SHA-512 PBKDF2 shadow hash, from which an NT hash
**cannot** be derived. Authenticating against the user's macOS account password
is therefore not implementable by reading the system; it would require prompting
for and storing a login-equivalent secret.

RDPie instead uses its own credential:

- The user sets an RDPie-specific username and password in the menu-bar app.
- RDPie derives the NT hash and stores it in the macOS Keychain, ACL-restricted
  to the RDPie code signature.
- NLA/CredSSP authenticates against that hash.
- **Optionally**, before granting *input control* (as opposed to view-only), the
  daemon prompts the connected client for macOS account credentials and verifies
  them against a local account via PAM. This is a second, distinct credential
  from the RDPie one used for NLA — it is not derived from it and is never
  stored. Off by default, opt-in per the user's configuration.

The always-on secret is therefore RDPie's own, not a login-equivalent one; the
login-equivalent check is a second, opt-in gate on the more dangerous capability.

## 4. Architecture

### 4.1 Bundle layout

One signed bundle containing two executables:

```
RDPie.app/Contents/
├── MacOS/
│   ├── RDPie                        # menu-bar UI (SwiftUI, LSUIElement=true)
│   └── rdpied                       # engine daemon (Swift + librdpie_core.a)
├── Library/LaunchAgents/
│   └── com.rdpie.agent.plist        # registered via SMAppService
└── Info.plist
```

Shipping `rdpied` inside the bundle and registering it with `SMAppService` means
its TCC grants attach to a stable, signed identity rather than a loose binary.

### 4.2 Responsibilities

**`rdpied`** is the product. It owns the RDP listener, the capture and encode
pipeline, input injection, the channel handlers, the Keychain secret, and the
TCC-gated permissions. It runs whether or not any UI exists, and `launchd`
restarts it on crash via `KeepAlive`.

**`RDPie`** is a pure client of the daemon: status display, configuration,
first-run permission wizard, connection log. Quitting it does not affect serving.

**Transport between them** is XPC over the Mach service `com.rdpie.agent`. The
daemon validates each peer connection's code-signing identity from its audit
token, so only the bundled UI can drive it.

### 4.3 The Rust/Swift boundary

`librdpie_core.a` is a Rust `staticlib` crate wrapping `ironrdp-server`, linked
into `rdpied`. The C ABI is generated with `cbindgen` and wrapped in a thin,
hand-written Swift layer.

**The boundary carries encoded bitstream and events, never raw pixel buffers.**
Swift captures via ScreenCaptureKit and encodes via VideoToolbox; only H.264 NAL
units reach Rust, which frames them into RDP GFX PDUs. This keeps the FFI narrow
and cheap, and prevents it from widening as the pipeline grows.

Direction of travel:

- **Swift → Rust:** encoded video frames, encoded audio frames, display
  topology changes, clipboard contents offered by the Mac.
- **Rust → Swift:** input events (keyboard, mouse, scroll), clipboard contents
  offered by the client, client-requested resolution changes, session lifecycle
  callbacks (connected, authenticated, disconnected).

Rust owns a `tokio` runtime on its own threads. Swift capture callbacks arrive on
ScreenCaptureKit's dispatch queue and must never block: frame submission goes
through a bounded ring buffer that drops the oldest frame under backpressure.

### 4.4 Capture source abstraction

The locked-screen capture path is **unverified** (see §8). The design therefore
does not hard-code a capture mechanism. Swift defines:

```swift
protocol CaptureSource {
    var isAvailableWhileLocked: Bool { get }
    func start(configuration: CaptureConfiguration) throws
    func stop()
    var frames: AsyncStream<CapturedFrame> { get }
}
```

`ScreenCaptureKitSource` is the primary implementation. If the spike in §8 shows
that ScreenCaptureKit stops delivering frames while locked, a second
implementation is added behind the same interface and the daemon swaps sources on
lock/unlock transitions, observed via the `com.apple.screenIsLocked` and
`com.apple.screenIsUnlocked` distributed notifications.

This abstraction is the load-bearing hedge in the design: it lets the
locked-screen strategy change without disturbing anything above it.

## 5. Data flow

### 5.1 Video

```
SCStream ──CMSampleBuffer──▶ VTCompressionSession ──NAL units──▶ ring buffer
                                                                     │
                                                                     ▼
                                              Rust: RdpServerDisplayUpdates
                                                                     │
                                                                     ▼
                                              egfx: send_avc420/444_frame()
                                                                     │
                                                                     ▼
                                                                RDP client
```

`SCStreamConfiguration` sets dimensions, pixel format, `minimumFrameInterval`,
cursor visibility, and `capturesAudio = true`. VideoToolbox runs in realtime mode
with a configurable bitrate and quality preset. AVCC-to-Annex-B conversion happens
Swift-side before the NAL units cross the FFI.

A RemoteFX/bitmap path is retained as a fallback for clients that do not
negotiate GFX, and as a degradation path if the hardware encoder fails.

### 5.2 Audio

Since macOS 13, `SCStream` captures system audio from the same stream as video
via `SCStreamConfiguration.capturesAudio`. **No virtual audio device or CoreAudio
tap is required.** Audio arrives as PCM `CMSampleBuffer`s on the `.audio` output,
is resampled and packed Swift-side, and is delivered to the RDPSND channel.

### 5.3 Input

Client input arrives on the Rust side, is translated from RDP scancodes and
pointer events into `CGEvent`s, and is posted via `CGEventPost`. This requires
Accessibility permission. If §3.5's PAM gate is enabled and the connecting user
has not satisfied it, the session is view-only and input events are dropped with
a notice sent to the client.

### 5.4 Clipboard

Bidirectional via CLIPRDR. Mac side is `NSPasteboard`, polled on change count
(there is no reliable change notification). v1 supports plain text (UTF-8/UTF-16),
RTF, and PNG/TIFF images. Large transfers use CLIPRDR's delayed-rendering
mechanism rather than being pushed eagerly.

### 5.5 Dynamic resize and multi-monitor

The Display Control channel carries client-requested resolution changes. On
request, the daemon reconfigures `SCStreamConfiguration` and rebuilds the
`VTCompressionSession`, then resets the GFX surface.

Multi-monitor exposes each `SCDisplay` as an RDP monitor in the monitor layout.
Each display is captured by its own `SCStream`. Display hot-plug and
reconfiguration are observed via `CGDisplayReconfigurationCallback` and trigger a
topology update to the client.

**This is the highest-risk item in v1.** Multiple concurrent `SCStream`s feeding a
single GFX surface, with independent frame timing, is materially harder than the
single-display case. If it proves unstable it should ship in v2 rather than
delaying everything else; the single-display path must not depend on it.

## 6. Error handling

| Condition | Detection | Response |
|---|---|---|
| Screen Recording revoked mid-session | `SCStream` error callback | Tear down session cleanly, notify client and UI, await re-grant |
| Accessibility revoked mid-session | `AXIsProcessTrusted()` poll | Downgrade to view-only, notify UI |
| Hardware encoder failure | `VTCompressionSession` status | Fall back to RemoteFX/bitmap path |
| Display hot-plug or reconfigure | `CGDisplayReconfigurationCallback` | Rebuild affected stream, send topology update |
| Screen lock / unlock | `com.apple.screenIsLocked` / `...Unlocked` | Swap `CaptureSource` if required |
| Client disconnect | `ironrdp-server` session end | Release capture resources, return to listening |
| Authentication failure | CredSSP result | Reject, rate-limit the source address, log to UI |
| Daemon crash | `launchd` | `KeepAlive` restart; UI reconnects over XPC |
| User logout | Agent termination | Clean shutdown; sessions end (documented behaviour, not a bug) |

Capture resources are released on every session-end path, including crash-adjacent
ones, so that a dead session never holds the Screen Recording indicator on.

## 7. Testing

**Rust core — runs on Linux CI.** This is the payoff of the §4.3 boundary: the
engine has no Apple dependencies, so protocol adapters, the display-update
plumbing, input translation, and the channel handlers are unit-testable on a
Linux runner with no Mac in the loop.

**Swift platform layer — XCTest on macOS runners.** Capture, encode, injection,
and clipboard are tested against a synthetic frame source implementing
`CaptureSource`, so tests need neither a real display nor TCC grants.

**Integration.** A headless RDP client (`ironrdp-client` or FreeRDP) connects to a
daemon backed by the synthetic capture source. Assertions cover the connection
sequence, NLA success and failure, resize, clipboard round-trip, and clean
disconnect.

**Manual matrix.** Necessarily manual, on real hardware: lock and unlock
transitions, display hot-plug, multi-monitor, permission revoke and re-grant,
Apple Silicon and Intel, macOS 14 and 15, and interoperability against `mstsc`,
Microsoft Remote Desktop for macOS/iOS, and FreeRDP.

**CI.** GitHub Actions: a Linux job for the Rust core, a macOS job for the Swift
build and XCTest. Notarization runs only on tagged releases.

## 8. Open questions and risks

These are unresolved and must not be treated as settled by the implementation plan.

1. **Does ScreenCaptureKit deliver frames while the screen is locked?**
   *Unverified.* MacRDP's README describes an "automatic CoreGraphics fallback
   when the screen is locked", which implies ScreenCaptureKit does not, and that
   the fallback is the CoreGraphics API family Apple obsoleted in the macOS 15
   SDK — the same removal that broke FreeRDP's macOS backend. If both are true,
   the locked-screen path is on borrowed time and needs a different answer.
   **Mitigated by** the §4.4 abstraction. **Resolve with** a spike on real
   hardware before Phase 1 completes.

2. **How does TCC attribute grants to a bundled `SMAppService` agent?**
   *Unverified.* The design assumes `rdpied` and `RDPie` receive separate Screen
   Recording entries, and that the daemon can trigger the system prompt despite
   being a background process. The permission wizard depends on this. **Resolve
   with** a spike alongside (1).

3. **Multi-monitor stability.** See §5.5. Highest-risk v1 feature; descope to v2
   if it destabilises the single-display path.

4. **NTLM-only NLA.** RDPie implements CredSSP with NTLM. Some hardened Windows
   configurations restrict NTLM. Kerberos is available in `ironrdp-server` but
   requires domain infrastructure that a standalone Mac does not have. Accepted
   limitation; document it.

5. **Network exposure.** RDPie listens on 3389 by default. The README must be
   unambiguous that exposing it directly to the internet is unsafe and that users
   should front it with a VPN, Tailscale, or an SSH tunnel. Binding to loopback
   only, with explicit opt-in to a wider interface, is the correct default.

**Environment constraint:** the design was produced in a Linux container with no
access to macOS. Nothing macOS-specific in this document has been compiled or
executed. Every item marked *unverified* needs hardware.

## 9. Phasing

Each phase should end with something demonstrable.

| Phase | Deliverable |
|---|---|
| 0 | Spikes for open questions (1) and (2). Nothing else depends on guesswork. |
| 1 | Rust core + minimal Swift daemon. Single display, RemoteFX/bitmap only, no input. A client connects and sees the screen. |
| 2 | VideoToolbox H.264 encode via `egfx` AVC420/444. |
| 3 | Input injection, Accessibility handling, optional PAM gate. |
| 4 | Clipboard (CLIPRDR). |
| 5 | Audio (RDPSND via `SCStream` audio). |
| 6 | Dynamic resize; multi-monitor (descopable to v2). |
| 7 | Menu-bar UI, permission wizard, configuration, connection log. |
| 8 | Packaging: `SMAppService` registration, hardened runtime, signing, notarization, installer. |

v2 backlog: file transfer (RDPDR), Kerberos, login-window support if Apple's
entitlement position changes.
