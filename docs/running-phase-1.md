# Running RDPie — Phase 1

## Build

```sh
git submodule update --init --recursive   # first checkout only
cargo build -p rdpie-core --release
cbindgen --config crates/rdpie-core/cbindgen.toml --crate rdpie-core \
  --output macos/Sources/CRdpieCore/include/rdpie_core.h
swift build --package-path macos
```

The Swift build links `../target/release/librdpie_core.a` via an
`.unsafeFlags` linker path relative to `macos/`, so `swift build` must be run
from the repo root with `--package-path macos` (or from inside `macos/`
directly) — a bare invocation from elsewhere resolves the relative path
against the wrong directory and fails at link time.

**Note:** SwiftPM does not track `librdpie_core.a` as a build input. If you
rebuild the Rust side after already building the Swift side once, `swift
build` will report "Build complete!" without relinking. Force a relink with:

```sh
rm macos/.build/debug/rdpied macos/.build/arm64-apple-macosx/debug/rdpied
swift build --package-path macos
```

## Run

```sh
cd macos
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 365 -subj "/CN=rdpie"
RDPIE_PASSWORD=hunter2 ./.build/debug/rdpied
```

Screen Recording permission is required (checked at startup; `rdpied` exits
with a clear message if it's missing). Set `RDPIE_SYNTHETIC=1` to run against
`SyntheticCaptureSource` instead of the real display — useful for isolating
protocol issues from capture issues. Set `RUST_LOG=debug` (or `info`) for
Rust-side tracing output; without it, nothing is logged (see Findings below).

Connect from another machine over an SSH tunnel, since the listener is
loopback-only:

```sh
ssh -L 3389:127.0.0.1:3389 user@the-mac
```

## Client compatibility results — 2026-08-24

Tested on macOS 26.5.1 (Mac mini, Apple M1) against `rdpied` bound to
`127.0.0.1:3389`, both with `RDPIE_SYNTHETIC=1` and against the real display.

| Client | Result | Notes |
|---|---|---|
| FreeRDP `sdl-freerdp` 3.30.0 (`brew install freerdp`) | **Works.** Full connection: TLS, credential validation, capability negotiation, sustained bitmap delivery (30+ frames observed over ~15s with no errors). | Run headless with `SDL_VIDEODRIVER=dummy` since this machine has no attached display server for the test client; visual rendering itself was not eyeballed, but the client received and decoded real, varying screen content without protocol errors. |
| FreeRDP `xfreerdp` (X11 client) 3.30.0 | **Not tested.** | Requires an X11 server; this machine has none and installing XQuartz was out of scope for this pass. |
| Microsoft Remote Desktop for macOS | **Not tested.** | Not installed on the test machine; no Mac App Store interaction was performed as part of this pass. |
| Windows `mstsc` | **Not tested.** | No Windows machine available in this environment. |

`+auth-only` was tried first as a way to test credentials without a display,
but produced identical output for a correct and an incorrect password — this
server does not appear to use NLA/CredSSP pre-authentication (auth happens
post-TLS, inside the RDP `ClientInfo` PDU), so `+auth-only` isn't a
meaningful test against it. The SDL client with a dummy video driver was
used instead, since it completes a full connection without needing a real
window server.

## Findings from this run

- **`tracing` had no subscriber anywhere in the crate**, so every
  `tracing::error!`/`info!`/`debug!` call — including on error paths — was
  silently discarded. `rdpie_server_start` now calls
  `tracing_subscriber::fmt().with_env_filter(EnvFilter::from_default_env()).try_init()`
  once, controlled by `RUST_LOG`. This was essential for diagnosing the
  issues below; without it, a failed connection produced zero server-side
  output.
- **`SCShareableContent.excludingDesktopWindows` returns zero displays while
  the screen is locked or asleep**, even though spike Task 1 found that an
  *already-running* `SCStream` keeps delivering frames through a lock.
  `ScreenCaptureKitSource.start()` calls `SCShareableContent` fresh each
  time, so starting `rdpied` while the screen happens to be locked throws
  `CaptureError.noDisplayAvailable` (currently an uncaught fatal error in
  `main.swift`, since Phase 1 has no supervisor). Reproduced directly:
  waking the display made a fresh `sck-check` probe go from `display count: 0`
  to `display count: 1` with no code change. Worth a retry-with-backoff or a
  clearer startup error in a later phase — Phase 7's permission wizard is
  the natural place, since it already needs to handle "screen not available
  yet" states.
- **A DVC channel creation consistently fails**: of the three dynamic virtual
  channels FreeRDP's client requests (`FreeRDP::Advanced::Input`,
  `Microsoft::Windows::RDS::DisplayControl`, `ECHO`), the third
  (`ECHO`) comes back with `creation_status: CreationStatus(3221226021)`
  (`0xC00000E5`) on every connection tested. The other two succeed
  (`CreationStatus(0)`), and the session proceeds normally afterward —
  bitmap delivery is unaffected. Not investigated further since it didn't
  block the Phase 1 deliverable, but worth knowing before Phase 3 (input)
  touches `FreeRDP::Advanced::Input`, since that one *does* create
  successfully.
- Two small Swift/C-ABI fixes needed beyond the plan's given `RustBridge.swift`:
  `Data.withUnsafeBytes` needed an explicit `(buffer: UnsafeRawBufferPointer)`
  closure parameter type to avoid resolving to the deprecated
  `ContentType`-generic overload; and the C ABI's `uintptr_t` fields
  (`stride`, `len`) map to Swift `UInt`, not `Int` — `frame.stride` and
  `buffer.count` need explicit `UInt(...)` conversions.
- Linking `rdpied` needs two more flags beyond what the plan's Package.swift
  gives: `.linkedLibrary("z")` (for `flate2`, pulled in transitively) and
  `.linkedFramework("SystemConfiguration")` (for the `system-configuration`
  crate, pulled in by `hyper_util`'s proxy detection). Without them the link
  fails with dozens of undefined `_inflate*`/`_kSCNetworkInterfaceType*`
  symbols.
