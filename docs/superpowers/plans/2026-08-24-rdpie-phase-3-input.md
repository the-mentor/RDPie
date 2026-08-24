# RDPie Phase 3: Input Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a connected RDP client actually control the Mac — translate RDP
keyboard and mouse events into real `CGEvent`s, injected system-wide via
`CGEventPost`, gated behind macOS Accessibility permission.

**Architecture:** A new direction of travel across the Rust/Swift FFI
boundary: Phases 1-2 only ever pushed data Swift→Rust (captured frames).
Phase 3 adds Rust→Swift: `ironrdp-server` delivers keyboard/mouse events to
a Rust-side `RdpServerInputHandler` implementation synchronously, on the
server's dedicated thread; that handler invokes a C function-pointer
callback registered by Swift at `rdpie_server_start` time, carrying a flat,
`#[repr(C)]` event struct. Swift's callback implementation is the only place
that touches `CGEvent`/`ApplicationServices` — Rust never links an Apple
framework, unchanged from every prior phase's Global Constraint. RDP's PC/AT
Set 1 scancodes are translated to macOS `CGKeyCode` virtual keycodes via a
lookup table on the Swift side.

**Tech Stack:** Rust `ironrdp-server`'s existing `RdpServerInputHandler`
trait (already present in the pinned submodule, unconditionally available —
no new feature flag needed, unlike Phase 2's `egfx`); Swift
`ApplicationServices`/`CoreGraphics` (`CGEvent`, `AXIsProcessTrusted`).

**Spec:** `docs/superpowers/specs/2026-08-23-rdpie-design.md` (§5.3 Input,
§6 error-handling table's Accessibility-revoked row, §3.5's PAM gate — see
Scope below for what this plan actually covers of that section)

**Prior plans:** `docs/superpowers/plans/2026-08-23-rdpie-phase-0-1.md` and
`docs/superpowers/plans/2026-08-24-rdpie-phase-2-h264.md` — conventions
established there (eager `AsyncStream`, XCTest over Swift Testing on this
machine, `UInt`/`UInt16` casts for C ABI integer fields, the explicit
`(buffer: UnsafeRawBufferPointer)` closure-parameter-type fix for
`Data.withUnsafeBytes`, mutex-poisoning `.expect()` as the sanctioned
exception to no-`unwrap`/`expect`) apply unchanged here and are not
re-derived below. Phase 2 also established the pattern this plan follows
for a brand-new FFI direction: verify the exact upstream dispatch mechanism
by reading the pinned submodule source before writing any Rust, not from
memory.

## Scope

**In scope:** Keyboard input (`KeyboardEvent::Pressed`/`Released` — scancode
form only), mouse input (move, left/right/middle/button4/button5 press and
release, vertical scroll), Accessibility permission handling (initial check
+ mid-session revocation per spec §6), the RDP-scancode-to-macOS-keycode
translation table, and an opt-in, env-var-gated non-loopback bind (Task 7)
so input can actually be tested from a real RDP client on the network —
input is the one feature loopback-only testing (Phases 1-2's approach)
can't meaningfully exercise. Spec §8.5's loopback-by-default mandate is
unchanged; this only adds the explicit opt-in §8.5 itself calls for.

**Explicitly out of scope, deferred to a later phase:**
- **`KeyboardEvent::UnicodePressed`/`UnicodeReleased`** (RDP's Unicode input
  path, used for IME/non-scancode-representable input) and
  **`KeyboardEvent::Synchronize`** (lock-key LED state sync). Standard
  scancode-based input covers normal typing; Unicode input and lock-key
  synchronization are real but narrower gaps than basic keyboard control
  working at all.
- **`MouseEvent::RelMove`** (relative mouse motion) and
  **`MouseEvent::Scroll`** (horizontal scroll). RDP's default and
  overwhelmingly common mode is absolute positioning (`MouseEvent::Move`)
  with vertical-only scroll; relative motion and horizontal scroll are
  real gaps, not silently-dropped-and-unnoticed ones — every unhandled
  variant is explicitly matched and logged, not caught by a wildcard.
- **The optional PAM gate (spec §3.5, §5.3).** The PAM *mechanism* itself
  is verified and ready (`spikes/pam-auth/RESULTS.md`: `pam_authenticate`
  against the `login` service works correctly, unprivileged, on this
  hardware) — but the spec does not actually specify **how** a connected
  RDP client provides the second, distinct macOS-account credential the
  gate needs. Input is what's being gated, so the obvious mechanisms both
  have a real chicken-and-egg problem: input can't be used to fill in a
  credential prompt if input is what's blocked pending that credential.
  Resolving this needs a UX/protocol design decision the spec doesn't make
  (e.g., a scoped exception letting input reach only an ephemeral PAM
  dialog; reusing the existing RDP `ClientInfo` PDU credentials as the PAM
  input instead of a separate mid-session prompt; something else). This
  plan ships input injection fully view-*and*-control capable with the
  gate simply not built, rather than inventing an unreviewed design for a
  gate the spec doesn't actually resolve. The spike results are preserved
  as groundwork for whoever designs that follow-up.
- **Multi-monitor coordinate mapping.** `MouseEvent::Move`'s `x`/`y` map to
  the single configured desktop's coordinate space, matching every prior
  phase's single-display scope (spec §5.5 flags multi-monitor as v1's
  highest-risk item generally, not input-specific).

## Global Constraints

- **Rust toolchain floor: 1.94**, **macOS floor: 14.0**, **License: MIT**,
  **submodule pin: `third_party/ironrdp` at tag `ironrdp-server-v0.13.0`** —
  unchanged from every prior phase's Global Constraints.
- **The Rust core must not depend on any Apple framework.** This is the
  load-bearing constraint this phase's whole architecture is designed
  around: `CGEvent`/`ApplicationServices` calls live exclusively in Swift's
  callback implementation, never in Rust. `crates/rdpie-core`'s
  `RdpieInputHandler` only ever produces the flat `#[repr(C)]` event struct
  and invokes the registered callback — it does not know what a `CGEvent`
  is.
- **No `unwrap()` or `expect()` on any path reachable from a network peer.**
  Unchanged. `RdpServerInputHandler::keyboard`/`mouse` are called directly
  from client-supplied PDU data — this is exactly a network-reachable path,
  not an exception to guard loosely.
- **The input callback must not block the server's connection-processing
  thread for meaningfully long.** Verified by reading
  `third_party/ironrdp/crates/ironrdp-server/src/server.rs`: `handler.keyboard(...)`/
  `handler.mouse(...)` are called synchronously, inline, in the same loop
  that processes every other incoming PDU on that connection (video
  acknowledgements, EGFX capability messages, etc.) — the same dedicated
  `std::thread` Phase 0-1 established runs the whole connection. A slow
  callback stalls the entire session, not just input. `CGEventPost` itself
  is a fast, non-blocking Core Graphics call with no I/O wait, so a direct
  synchronous FFI callback (no queue/channel indirection) is the right
  choice for this phase — note this explicitly if a future phase's
  profiling shows otherwise.
- **Non-input-capable clients, and clients before Accessibility is granted,
  must not crash the session.** Matches spec §5.3 exactly: "If ... input
  events are dropped with a notice sent to the client" — dropping, not
  erroring the connection. This also covers Accessibility being revoked
  mid-session (spec §6): downgrade to view-only, don't tear down the
  connection.
- **Verify upstream API and RDP protocol conventions against real sources,
  not memory.** `RdpServerInputHandler`'s trait and its call sites were
  read directly from `third_party/ironrdp/crates/ironrdp-server/src/{handler,server,builder}.rs`
  for this plan — see the Task sections for exact line references. The
  RDP-scancode-to-macOS-`CGKeyCode` mapping table must be built from at
  least one authoritative external reference (not invented from partial
  memory of ~15 well-known keys and guessed for the rest) — Task 7 requires
  this explicitly.

## File Structure

```
crates/rdpie-core/
├── src/
│   ├── input.rs                             # NEW: RdpieInputHandler, RdpieInputEvent, callback registration
│   ├── ffi.rs                                # + input_callback/input_context fields on RdpieConfig
│   └── server.rs                             # .with_input_handler(...) replaces .with_no_input()
├── include/rdpie_core.h                      # regenerated: + RdpieInputEvent, RdpieInputCallback typedef
macos/Sources/RdpieCapture/
├── ScancodeMap.swift                         # NEW: pure RDP-scancode -> CGKeyCode lookup table, no CGEvent dep
└── InputInjector.swift                       # NEW: CGEvent construction/posting from RdpieInputEvent, Accessibility checks
macos/Sources/rdpied/
├── RustBridge.swift                          # + input callback registration, Accessibility poll wiring
└── main.swift                                # + Accessibility check at startup, revocation poll loop
macos/Tests/RdpieCaptureTests/
├── ScancodeMapTests.swift                    # NEW
└── InputInjectorTests.swift                  # NEW (structural/construction tests; live CGEventPost is Task 9's job)
docs/running-phase-3.md                       # NEW: build/run/verification results, mirrors Phase 1/2's docs
```

Rationale for the split: `ScancodeMap.swift` stays free of `CGEvent`/`ApplicationServices`
so the scancode table itself is testable as pure data — the same reasoning
that kept `H264NALConverter.swift` free of VideoToolbox in Phase 2.
`InputInjector.swift` is the one file that actually calls `CGEventPost`,
mirroring how `ffi.rs` is "the only file with `unsafe`" in the Rust core —
one file owns one platform-specific responsibility.

---
## Task 1: `RdpieInputEvent`/`RdpieInputHandler` — event translation and callback dispatch

**Files:**
- Create: `crates/rdpie-core/src/input.rs`
- Modify: `crates/rdpie-core/src/lib.rs`

**Interfaces:**
- Consumes: `ironrdp_server::{KeyboardEvent, MouseEvent, RdpServerInputHandler}` — verified at `third_party/ironrdp/crates/ironrdp-server/src/handler.rs` lines 9-76, re-exported at the `ironrdp_server` crate root (`third_party/ironrdp/crates/ironrdp-server/src/lib.rs` line 32).
- Produces:
  - `pub enum RdpieInputEventKind` (14 variants, `#[repr(C)]` — not `#[repr(u8)]`, see Step 1's doc comment — discriminants 0-13 exactly as below)
  - `pub struct RdpieInputEvent` (`#[repr(C)]`, fields `kind`/`scancode`/`extended`/`x`/`y`/`scroll_delta`)
  - `pub type RdpieInputCallback = unsafe extern "C" fn(context: *mut c_void, event: *const RdpieInputEvent)`
  - `pub struct RdpieInputHandler` with `pub fn new(callback: RdpieInputCallback, context: *mut c_void) -> Self`, implementing `ironrdp_server::RdpServerInputHandler`
  - All four re-exported from the crate root (`rdpie_core::{RdpieInputEventKind, RdpieInputEvent, RdpieInputCallback, RdpieInputHandler}`) for Task 2 and Task 3 to consume.

This is the only task in this plan that touches `ironrdp_server::KeyboardEvent`/`MouseEvent` directly — Task 2 and Task 3 only ever see `RdpieInputHandler` as an opaque `RdpServerInputHandler` implementor.

- [ ] **Step 1: Write the failing tests**

Create `crates/rdpie-core/src/input.rs` with just the types and a stub `RdpServerInputHandler` impl that never calls the callback, plus this test module, so the first test run is genuinely red against real translation logic (not just "module doesn't exist"):

```rust
//! Translates `ironrdp-server` input events into the flat C ABI shape a
//! registered Swift callback consumes. This crate never touches `CGEvent`
//! itself — see the "no Apple framework" constraint in `ffi.rs`.

use core::ffi::c_void;

use ironrdp_server::{KeyboardEvent, MouseEvent, RdpServerInputHandler};

/// Discriminant for `RdpieInputEvent`. `#[repr(C)]`, deliberately not
/// `#[repr(u8)]`: a sized repr makes `cbindgen` emit a
/// `#if __STDC_VERSION__ >= 202311L` conditional — a C23-typed enum plus a
/// pre-C23 `typedef uint8_t RdpieInputEventKind` fallback — that Swift's
/// Clang importer reports as genuinely ambiguous ("'RdpieInputEventKind' is
/// ambiguous for type lookup"), confirmed by generating that exact header
/// shape and compiling a matching Swift file against it. `#[repr(C)]` on a
/// fieldless enum emits a single, unambiguous `enum` typedef instead — the
/// same style already used for every other type in this header — and costs
/// nothing here: this enum crosses the FFI boundary as a field inside
/// `RdpieInputEvent`, not as a tightly packed wire format needing a 1-byte
/// guarantee.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RdpieInputEventKind {
    KeyPressed = 0,
    KeyReleased = 1,
    MouseMove = 2,
    MouseLeftPressed = 3,
    MouseLeftReleased = 4,
    MouseRightPressed = 5,
    MouseRightReleased = 6,
    MouseMiddlePressed = 7,
    MouseMiddleReleased = 8,
    MouseButton4Pressed = 9,
    MouseButton4Released = 10,
    MouseButton5Pressed = 11,
    MouseButton5Released = 12,
    MouseVerticalScroll = 13,
}

/// Flat event struct crossing the FFI boundary. Only the fields relevant to
/// `kind` are meaningful for a given event; the rest are zeroed. Keyboard
/// events carry `scancode`/`extended` (RDP PC/AT Set 1 scancode — Swift maps
/// this to a `CGKeyCode`, this crate never touches `CGEvent`). `MouseMove`
/// carries `x`/`y` in the single configured desktop's coordinate space.
/// `MouseVerticalScroll` carries `scroll_delta` (positive = away from user,
/// matching `MouseEvent::VerticalScroll`'s `value` sign — do not renormalize
/// it here; document the passthrough).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RdpieInputEvent {
    pub kind: RdpieInputEventKind,
    pub scancode: u8,
    pub extended: bool,
    pub x: u16,
    pub y: u16,
    pub scroll_delta: i16,
}

/// Registered once at `rdpie_server_start` time. Called synchronously from
/// the server's connection thread — must not block for meaningfully long.
/// `context` is the opaque pointer Swift supplied in `RdpieConfig`, passed
/// back unchanged on every call so Swift can recover object identity
/// (`Unmanaged<T>`) across the boundary.
///
/// # Safety
/// `event` is valid only for the duration of the call. `context` must
/// remain valid for as long as the server handle is alive.
pub type RdpieInputCallback = unsafe extern "C" fn(context: *mut c_void, event: *const RdpieInputEvent);

/// `*mut c_void` is not `Send`, but `RdpServerInputHandler` requires it (the
/// trait's own `Send` bound). Safety: this pointer is never dereferenced by
/// Rust — it is only ever handed back, unchanged, to the same Swift code
/// that produced it via `RdpieConfig::input_context`. Swift's callback is
/// responsible for whatever thread-safety `context` itself needs.
struct SendableContext(*mut c_void);
unsafe impl Send for SendableContext {}

/// Translates in-scope `KeyboardEvent`/`MouseEvent` variants and invokes the
/// registered callback. Constructed once per server start in `ffi.rs`.
pub struct RdpieInputHandler {
    callback: RdpieInputCallback,
    context: SendableContext,
}

impl RdpieInputHandler {
    pub fn new(callback: RdpieInputCallback, context: *mut c_void) -> Self {
        Self { callback, context: SendableContext(context) }
    }
}

impl RdpServerInputHandler for RdpieInputHandler {
    fn keyboard(&mut self, _event: KeyboardEvent) {
        // Translation lands in Step 3 — this stub exists only so the crate
        // compiles for the red test run in Step 2.
    }

    fn mouse(&mut self, _event: MouseEvent) {}
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use ironrdp_server::RdpServerInputHandler as _;

    use super::*;

    /// Test double standing in for Swift's callback: casts `context` back to
    /// the `Mutex<Vec<RdpieInputEvent>>` the test allocated and records a
    /// copy of every event it receives.
    unsafe extern "C" fn record(context: *mut c_void, event: *const RdpieInputEvent) {
        let log = unsafe { &*(context as *const Mutex<Vec<RdpieInputEvent>>) };
        log.lock().expect("test event log mutex poisoned").push(unsafe { *event });
    }

    fn handler_with_log() -> (RdpieInputHandler, Arc<Mutex<Vec<RdpieInputEvent>>>) {
        let log = Arc::new(Mutex::new(Vec::new()));
        let context = Arc::as_ptr(&log) as *mut c_void;
        (RdpieInputHandler::new(record, context), log)
    }

    #[test]
    fn a_plain_scancode_press_is_translated() {
        let (mut handler, log) = handler_with_log();
        handler.keyboard(KeyboardEvent::Pressed { code: 0x1e, extended: false });

        let events = log.lock().expect("test event log mutex poisoned");
        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0],
            RdpieInputEvent {
                kind: RdpieInputEventKind::KeyPressed,
                scancode: 0x1e,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            }
        );
    }

    #[test]
    fn an_extended_flag_press_is_translated() {
        let (mut handler, log) = handler_with_log();
        handler.keyboard(KeyboardEvent::Pressed { code: 0x4b, extended: true });

        let events = log.lock().expect("test event log mutex poisoned");
        assert_eq!(
            events[0],
            RdpieInputEvent {
                kind: RdpieInputEventKind::KeyPressed,
                scancode: 0x4b,
                extended: true,
                x: 0,
                y: 0,
                scroll_delta: 0,
            }
        );
    }

    #[test]
    fn a_mouse_move_is_translated() {
        let (mut handler, log) = handler_with_log();
        handler.mouse(MouseEvent::Move { x: 100, y: 200 });

        let events = log.lock().expect("test event log mutex poisoned");
        assert_eq!(
            events[0],
            RdpieInputEvent {
                kind: RdpieInputEventKind::MouseMove,
                scancode: 0,
                extended: false,
                x: 100,
                y: 200,
                scroll_delta: 0,
            }
        );
    }

    #[test]
    fn a_button_press_release_pair_is_translated() {
        let (mut handler, log) = handler_with_log();
        handler.mouse(MouseEvent::LeftPressed);
        handler.mouse(MouseEvent::LeftReleased);

        let events = log.lock().expect("test event log mutex poisoned");
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, RdpieInputEventKind::MouseLeftPressed);
        assert_eq!(events[1].kind, RdpieInputEventKind::MouseLeftReleased);
    }

    #[test]
    fn a_vertical_scroll_is_translated_without_renormalizing_the_sign() {
        let (mut handler, log) = handler_with_log();
        handler.mouse(MouseEvent::VerticalScroll { value: -120 });

        let events = log.lock().expect("test event log mutex poisoned");
        assert_eq!(
            events[0],
            RdpieInputEvent {
                kind: RdpieInputEventKind::MouseVerticalScroll,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: -120,
            }
        );
    }

    #[test]
    fn an_out_of_scope_keyboard_variant_does_not_invoke_the_callback() {
        let (mut handler, log) = handler_with_log();
        handler.keyboard(KeyboardEvent::UnicodePressed(0x41));

        assert!(log.lock().expect("test event log mutex poisoned").is_empty());
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p rdpie-core input::`
Expected: FAIL — every assertion trips because `keyboard`/`mouse` are still stubs that never call the callback (`log` stays empty, so `events[0]` panics on an out-of-bounds index).

- [ ] **Step 3: Implement the translation**

Replace the two stub methods in `crates/rdpie-core/src/input.rs`:

```rust
impl RdpieInputHandler {
    fn emit(&self, event: RdpieInputEvent) {
        unsafe { (self.callback)(self.context.0, &event as *const RdpieInputEvent) };
    }
}

impl RdpServerInputHandler for RdpieInputHandler {
    fn keyboard(&mut self, event: KeyboardEvent) {
        let translated = match &event {
            KeyboardEvent::Pressed { code, extended } => RdpieInputEvent {
                kind: RdpieInputEventKind::KeyPressed,
                scancode: *code,
                extended: *extended,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            KeyboardEvent::Released { code, extended } => RdpieInputEvent {
                kind: RdpieInputEventKind::KeyReleased,
                scancode: *code,
                extended: *extended,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            // Out of scope for Phase 3 — see the plan's Scope section. Logged,
            // not silently dropped: a wildcard here would also swallow any
            // future variant upstream adds without anyone noticing.
            KeyboardEvent::UnicodePressed(_)
            | KeyboardEvent::UnicodeReleased(_)
            | KeyboardEvent::Synchronize(_) => {
                tracing::debug!(?event, "keyboard event variant out of scope for Phase 3; dropped");
                return;
            }
        };
        self.emit(translated);
    }

    fn mouse(&mut self, event: MouseEvent) {
        let translated = match &event {
            MouseEvent::Move { x, y } => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseMove,
                scancode: 0,
                extended: false,
                x: *x,
                y: *y,
                scroll_delta: 0,
            },
            MouseEvent::LeftPressed => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseLeftPressed,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::LeftReleased => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseLeftReleased,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::RightPressed => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseRightPressed,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::RightReleased => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseRightReleased,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::MiddlePressed => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseMiddlePressed,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::MiddleReleased => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseMiddleReleased,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::Button4Pressed => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseButton4Pressed,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::Button4Released => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseButton4Released,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::Button5Pressed => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseButton5Pressed,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::Button5Released => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseButton5Released,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            MouseEvent::VerticalScroll { value } => RdpieInputEvent {
                kind: RdpieInputEventKind::MouseVerticalScroll,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: *value,
            },
            // Out of scope for Phase 3 — see the plan's Scope section.
            MouseEvent::Scroll { .. } | MouseEvent::RelMove { .. } => {
                tracing::debug!(?event, "mouse event variant out of scope for Phase 3; dropped");
                return;
            }
        };
        self.emit(translated);
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p rdpie-core input::`
Expected: PASS — all seven tests green.

- [ ] **Step 5: Register the module and re-export its public types**

In `crates/rdpie-core/src/lib.rs`, after the existing `gfx` module block:

```rust
pub mod gfx;

pub use gfx::{RdpieGfxFactory, RdpieGfxHandle, gfx_channel};
pub mod input;

pub use input::{RdpieInputCallback, RdpieInputEvent, RdpieInputEventKind, RdpieInputHandler};
```

- [ ] **Step 6: Run the full crate test suite**

Run: `cargo test -p rdpie-core`
Expected: PASS — no regressions in `frame`, `display`, `server`, `ffi`, or `gfx` tests.

- [ ] **Step 7: Commit**

```bash
git add crates/rdpie-core/src/input.rs crates/rdpie-core/src/lib.rs
git commit -m "feat: translate RDP keyboard/mouse events to the input FFI struct"
```

---

## Task 2: FFI additions — `RdpieConfig` input fields and header

**Files:**
- Modify: `crates/rdpie-core/src/ffi.rs`
- Modify: `crates/rdpie-core/cbindgen.toml`
- Modify: `crates/rdpie-core/include/rdpie_core.h`

**Interfaces:**
- Consumes: `RdpieInputCallback`, `RdpieInputHandler::new(callback, context)` (Task 1).
- Produces:
  - `RdpieConfig` gains `pub input_callback: Option<unsafe extern "C" fn(context: *mut c_void, event: *const RdpieInputEvent)>` (the signature written inline, not through the `RdpieInputCallback` alias — see the doc comment on the field in Step 3 for why) and `pub input_context: *mut c_void`.
  - `fn input_handler_from_config(config: &RdpieConfig) -> Option<RdpieInputHandler>` — private, the seam Task 3's `crate::server::run` is fed through from `rdpie_server_start`.
  - The regenerated header exposes `RdpieInputEventKind`, `RdpieInputEvent`, `RdpieInputCallback`, and `RdpieConfig`'s two new fields — exact declarations below.

`rdpie_server_start` itself does not change its exported signature — it already takes `*const RdpieConfig`, and the two new fields ride along inside that struct.

- [ ] **Step 1: Write the failing tests**

Add to the existing `#[cfg(test)] mod tests` block in `crates/rdpie-core/src/ffi.rs`:

```rust
#[test]
fn null_input_callback_yields_no_handler() {
    let config = RdpieConfig {
        port: 0,
        width: 0,
        height: 0,
        username: core::ptr::null(),
        password: core::ptr::null(),
        cert_pem_path: core::ptr::null(),
        key_pem_path: core::ptr::null(),
        input_callback: None,
        input_context: core::ptr::null_mut(),
    };
    assert!(input_handler_from_config(&config).is_none());
}

#[test]
fn a_registered_callback_is_reachable_through_the_constructed_handler() {
    use std::ffi::CString;
    use std::sync::{Arc, Mutex};

    use ironrdp_server::{MouseEvent, RdpServerInputHandler as _};

    use crate::input::{RdpieInputEvent, RdpieInputEventKind};

    unsafe extern "C" fn record(context: *mut c_void, event: *const RdpieInputEvent) {
        let log = unsafe { &*(context as *const Mutex<Vec<RdpieInputEvent>>) };
        log.lock().expect("test event log mutex poisoned").push(unsafe { *event });
    }

    let username = CString::new("rdpie").unwrap();
    let password = CString::new("hunter2").unwrap();
    let cert = CString::new("/tmp/cert.pem").unwrap();
    let key = CString::new("/tmp/key.pem").unwrap();
    let log: Arc<Mutex<Vec<RdpieInputEvent>>> = Arc::new(Mutex::new(Vec::new()));
    let context = Arc::as_ptr(&log) as *mut c_void;

    let config = RdpieConfig {
        port: 3389,
        width: 1280,
        height: 720,
        username: username.as_ptr(),
        password: password.as_ptr(),
        cert_pem_path: cert.as_ptr(),
        key_pem_path: key.as_ptr(),
        input_callback: Some(record),
        input_context: context,
    };

    let mut handler =
        input_handler_from_config(&config).expect("a non-null input_callback must build a handler");
    handler.mouse(MouseEvent::LeftPressed);

    let events = log.lock().expect("test event log mutex poisoned");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].kind, RdpieInputEventKind::MouseLeftPressed);
}

#[test]
fn starting_with_a_null_input_callback_still_succeeds_view_only() {
    use std::ffi::CString;

    let dir = tempfile::tempdir().expect("temp dir");
    let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).expect("self-signed cert");
    let cert_path = dir.path().join("cert.pem");
    let key_path = dir.path().join("key.pem");
    std::fs::write(&cert_path, cert.cert.pem()).expect("writing cert.pem");
    std::fs::write(&key_path, cert.signing_key.serialize_pem()).expect("writing key.pem");

    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .expect("binding an ephemeral port")
        .local_addr()
        .expect("reading the ephemeral port")
        .port();

    let username = CString::new("rdpie").unwrap();
    let password = CString::new("hunter2").unwrap();
    let cert_c = CString::new(cert_path.to_str().expect("utf-8 temp path")).unwrap();
    let key_c = CString::new(key_path.to_str().expect("utf-8 temp path")).unwrap();

    let config = RdpieConfig {
        port,
        width: 640,
        height: 480,
        username: username.as_ptr(),
        password: password.as_ptr(),
        cert_pem_path: cert_c.as_ptr(),
        key_pem_path: key_c.as_ptr(),
        input_callback: None,
        input_context: core::ptr::null_mut(),
    };

    let server = unsafe { rdpie_server_start(&config as *const RdpieConfig) };
    assert!(!server.is_null(), "a null input_callback must still start a view-only server, not fail");
    unsafe { rdpie_server_stop(server) };
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p rdpie-core ffi::`
Expected: FAIL to compile — `input_handler_from_config` does not exist yet, and `RdpieConfig` has no `input_callback`/`input_context` fields.

- [ ] **Step 3: Add the config fields and the translation seam**

In `crates/rdpie-core/src/ffi.rs`, widen the import and struct:

```rust
use core::ffi::{CStr, c_char, c_void};

use crate::frame::{Frame, FrameSink, SubmitOutcome};
use crate::input::{RdpieInputCallback, RdpieInputEvent, RdpieInputHandler};
```

```rust
/// Configuration passed across the ABI. All strings are NUL-terminated UTF-8
/// owned by the caller; they are copied before this function returns.
#[repr(C)]
pub struct RdpieConfig {
    pub port: u16,
    pub width: u16,
    pub height: u16,
    pub username: *const c_char,
    pub password: *const c_char,
    pub cert_pem_path: *const c_char,
    pub key_pem_path: *const c_char,
    /// `None` (a null function pointer from C) means the client's session
    /// is view-only — matches spec's "non-input-capable clients ... input
    /// events are dropped" behavior, driven from the Swift side by simply
    /// never registering a callback rather than Rust guessing capability.
    ///
    /// Written as `Option<unsafe extern "C" fn(...)>` with the signature
    /// inlined, not `Option<RdpieInputCallback>` through the named alias —
    /// confirmed by generating the header both ways: going through a named
    /// alias defeats `cbindgen`'s `Option<T>`-to-nullable-pointer collapsing
    /// (it only resolves `T` to a function-pointer type when the signature
    /// is written in place), producing a broken opaque
    /// `struct Option_RdpieInputCallback` wrapper Swift cannot assign a
    /// callback to at all. The inline form produces a plain
    /// `void (*input_callback)(...)` field, exactly as needed. This is a
    /// Rust-alias-vs-cbindgen quirk only — `RdpieInputCallback` the type
    /// alias is unaffected everywhere else in this file and remains the
    /// right type to use for `RdpieInputHandler::new`'s parameter.
    pub input_callback: Option<unsafe extern "C" fn(context: *mut c_void, event: *const RdpieInputEvent)>,
    /// Opaque; passed back unchanged on every `input_callback` invocation.
    /// Ignored when `input_callback` is `None`.
    pub input_context: *mut c_void,
}

/// Builds the input handler `rdpie_server_start` threads into
/// `crate::server::run`, or `None` when Swift registered no callback (a
/// view-only session — `crate::server::run` falls back to
/// `.with_no_input()` in that case, same as every prior phase).
fn input_handler_from_config(config: &RdpieConfig) -> Option<RdpieInputHandler> {
    config.input_callback.map(|callback| RdpieInputHandler::new(callback, config.input_context))
}
```

- [ ] **Step 4: Wire the handler into `rdpie_server_start`**

In `rdpie_server_start`, build the handler alongside the existing config assembly and pass it through:

```rust
    let server_config = crate::server::ServerConfig::loopback(
        config.port,
        crate::DesktopSize { width: config.width, height: config.height },
        username,
        password,
        cert.into(),
        key.into(),
    );
    let input_handler = input_handler_from_config(config);

    let (sink, stream) = crate::frame::channel(3);
    let (gfx_factory, gfx) = crate::gfx::gfx_channel(config.width, config.height);
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    let worker = std::thread::Builder::new()
        .name("rdpie-server".to_owned())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
                Ok(rt) => rt,
                Err(error) => {
                    tracing::error!(%error, "could not start the tokio runtime");
                    return;
                }
            };
            runtime.block_on(async move {
                tokio::select! {
                    result = crate::server::run(server_config, stream, gfx_factory, input_handler) => {
                        if let Err(error) = result {
                            tracing::error!(%error, "RDP server stopped");
                        }
                    }
                    _ = shutdown_rx => {
                        tracing::info!("RDPie server shutting down");
                    }
                }
            });
        });
```

(Only the two lines — `let input_handler = ...` and the `crate::server::run(...)` call inside `tokio::select!` — actually change; everything else in the function body is unchanged from the current source and shown here only for placement.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cargo test -p rdpie-core ffi::`
Expected: FAIL to link/build — `crate::server::run` still only takes three arguments. This is expected: Task 3 changes `run`'s signature. Do not attempt to make this pass yet; proceed to Step 6, which is unaffected by that signature, then finish greening this file's tests once Task 3 lands (Task 3's Step 4 re-runs `cargo test -p rdpie-core ffi::` and must show these tests passing).

- [ ] **Step 6: Update `cbindgen.toml`'s export allowlist**

```toml
[export]
include = ["RdpieConfig", "RdpieServer", "RdpieInputEventKind", "RdpieInputEvent", "RdpieInputCallback"]
```

- [ ] **Step 7: Regenerate and verify the header against this pre-verified text**

This is not a hand-derivation — the exact shape below was produced by
actually running `cbindgen` against a throwaway crate carrying this same
`RdpieInputEventKind`/`RdpieInputEvent`/`RdpieInputCallback`/`RdpieConfig`
shape, and then confirmed to compile with `swiftc -typecheck` against a
matching Swift consumer (struct construction, top-level-function-to-C-
callback assignment, and an exhaustive `switch` over the enum). Two
behaviors this uncovered, corrected in Step 3's field declaration above and
worth restating here since they're easy to get wrong from memory:

- `input_callback`'s Rust type must be `Option<unsafe extern "C" fn(...)>`
  with the signature written **inline**, not `Option<RdpieInputCallback>`
  through the named alias. `cbindgen` only collapses `Option<T>` to a bare
  nullable C pointer when it can resolve `T` to a function-pointer type in
  place; routed through a named alias, it instead emits a broken opaque
  `struct Option_RdpieInputCallback` wrapper that Swift cannot assign a
  callback to — confirmed by generating the header both ways and diffing.
  The field must show up as plain
  `void (*input_callback)(void *context, const struct RdpieInputEvent *event);`.
- `RdpieInputEventKind` must be declared `#[repr(C)]`, not `#[repr(u8)]` (see
  Task 1's doc comment on the enum) — a sized repr makes `cbindgen` emit a
  `#if __STDC_VERSION__ >= 202311L` conditional dual declaration that Swift's
  Clang importer reports as genuinely ambiguous. `#[repr(C)]` produces the
  single, plain `typedef enum { ... } RdpieInputEventKind;` shown below, with
  unprefixed case names (`KeyPressed`, not `RdpieInputEventKind_KeyPressed`).

`cbindgen` topologically sorts type declarations by dependency. With the
`input_callback` field now written as an inline function-pointer signature
rather than a reference to the `RdpieInputCallback` alias, `RdpieConfig` no
longer depends on that alias as a *type* — only on `RdpieInputEvent`
(through the inline signature) and, transitively, `RdpieInputEventKind`.
`RdpieInputCallback` itself remains in the header (it's in the `[export]`
allowlist and Task 1's Rust code still uses it internally), but with nothing
left depending on it as a type, it sorts to *after* `RdpieConfig` rather than
before it. None of the four existing `rdpie_server_*` function declarations
change, since none of their signatures changed.

The full new `crates/rdpie-core/include/rdpie_core.h`, with insertions marked:

```c
#ifndef RDPIE_CORE_H
#define RDPIE_CORE_H

// Generated by cbindgen. Do not edit by hand.

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/* --- NEW: inserted here, before RdpieServer --- */

/**
 * Discriminant for `RdpieInputEvent`. `#[repr(C)]` (not `#[repr(u8)]` — a
 * sized repr triggers a C23-conditional dual declaration that is genuinely
 * ambiguous to Swift's Clang importer; confirmed by compiling that exact
 * shape) so cbindgen emits a single, unambiguous C `enum` typedef.
 */
typedef enum RdpieInputEventKind {
  KeyPressed = 0,
  KeyReleased = 1,
  MouseMove = 2,
  MouseLeftPressed = 3,
  MouseLeftReleased = 4,
  MouseRightPressed = 5,
  MouseRightReleased = 6,
  MouseMiddlePressed = 7,
  MouseMiddleReleased = 8,
  MouseButton4Pressed = 9,
  MouseButton4Released = 10,
  MouseButton5Pressed = 11,
  MouseButton5Released = 12,
  MouseVerticalScroll = 13,
} RdpieInputEventKind;

/* --- END NEW --- */

/**
 * Opaque handle returned to Swift.
 *
 * `RdpServer::run()`'s future is not `Send` — upstream holds an
 * `Rc<tokio::sync::Mutex<&mut RdpServer>>` across awaits — so it cannot be
 * handed to `Runtime::spawn`. Instead a dedicated thread owns the runtime and
 * drives the server with `block_on`, which carries no `Send` bound.
 */
typedef struct RdpieServer RdpieServer;

/* --- NEW: inserted here, before RdpieConfig --- */

/**
 * Flat event struct crossing the FFI boundary. Only the fields relevant to
 * `kind` are meaningful for a given event; the rest are zeroed. Keyboard
 * events carry `scancode`/`extended` (RDP PC/AT Set 1 scancode — Swift maps
 * this to a `CGKeyCode`, this crate never touches `CGEvent`). `MouseMove`
 * carries `x`/`y` in the single configured desktop's coordinate space.
 * `MouseVerticalScroll` carries `scroll_delta` (positive = away from user,
 * matching `MouseEvent::VerticalScroll`'s `value` sign — do not renormalize
 * it here; document the passthrough).
 */
typedef struct RdpieInputEvent {
  enum RdpieInputEventKind kind;
  uint8_t scancode;
  bool extended;
  uint16_t x;
  uint16_t y;
  int16_t scroll_delta;
} RdpieInputEvent;

/* --- END NEW --- */

/**
 * Configuration passed across the ABI. All strings are NUL-terminated UTF-8
 * owned by the caller; they are copied before this function returns.
 */
typedef struct RdpieConfig {
  uint16_t port;
  uint16_t width;
  uint16_t height;
  const char *username;
  const char *password;
  const char *cert_pem_path;
  const char *key_pem_path;
  void (*input_callback)(void *context, const struct RdpieInputEvent *event); /* NEW */
  void *input_context; /* NEW */
} RdpieConfig;

/* --- NEW: inserted here, after RdpieConfig --- */

/**
 * Registered once at `rdpie_server_start` time. Called synchronously from
 * the server's connection thread — must not block for meaningfully long.
 * `context` is the opaque pointer Swift supplied in `RdpieConfig`, passed
 * back unchanged on every call so Swift can recover object identity
 * (`Unmanaged<T>`) across the boundary.
 *
 * # Safety
 *
 * `event` is valid only for the duration of the call. `context` must
 * remain valid for as long as the server handle is alive.
 */
typedef void (*RdpieInputCallback)(void *context, const struct RdpieInputEvent *event);

/* --- END NEW --- */

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Start the RDP listener on a dedicated runtime.
 *
 * Returns a handle, or null if configuration was invalid. The caller owns the
 * handle and must release it with `rdpie_server_stop`.
 *
 * # Safety
 *
 * `config` must point to a valid `RdpieConfig` whose string fields are either
 * null or valid NUL-terminated UTF-8.
 */
struct RdpieServer *rdpie_server_start(const struct RdpieConfig *config);

/**
 * Submit one BGRA8888 frame. Never blocks.
 *
 * Returns 0 accepted, 1 accepted after dropping the oldest queued frame,
 * -1 on a closed session or invalid arguments.
 *
 * # Safety
 *
 * `server` must be a handle from `rdpie_server_start` that has not been
 * stopped. `data` must point to at least `len` readable bytes.
 */
int32_t rdpie_server_submit_frame(struct RdpieServer *server,
                                  uint16_t width,
                                  uint16_t height,
                                  uintptr_t stride,
                                  const uint8_t *data,
                                  uintptr_t len);

/**
 * Whether the connected client has finished EGFX/AVC420 capability
 * negotiation. Swift should submit H.264 via
 * `rdpie_server_submit_h264_frame` once this returns `true`, and fall back
 * to raw BGRA via `rdpie_server_submit_frame` otherwise — the two paths
 * coexist; this never disables the raw path.
 *
 * Returns `false` for a null handle.
 *
 * # Safety
 *
 * `server` must be a handle from `rdpie_server_start` that has not been
 * stopped, or null.
 */
bool rdpie_server_gfx_active(const struct RdpieServer *server);

/**
 * Submit one AVC420-encoded H.264 frame covering a single full-frame
 * region (`region_left`/`region_top`/`region_right`/`region_bottom` are
 * inclusive edges, matching MS-RDPEGFX). `data` must already be Annex-B
 * formatted (start-code-prefixed NAL units) — VideoToolbox's AVCC output
 * needs converting to Annex-B before calling this, which happens on the
 * Swift side, not here.
 *
 * Returns 0 on success, -1 on invalid arguments or a rejected frame
 * (channel not negotiated yet, backpressure, or an encoding failure).
 * Multi-region submission is not supported in this phase.
 *
 * # Safety
 *
 * `server` must be a handle from `rdpie_server_start` that has not been
 * stopped. `data` must point to at least `len` readable bytes.
 */
int32_t rdpie_server_submit_h264_frame(struct RdpieServer *server,
                                       const uint8_t *data,
                                       uintptr_t len,
                                       uint16_t region_left,
                                       uint16_t region_top,
                                       uint16_t region_right,
                                       uint16_t region_bottom,
                                       uint8_t quantization_parameter,
                                       uint32_t timestamp_ms);

/**
 * Stop the server and release the handle. Safe to call with null.
 *
 * # Safety
 *
 * `server` must be a handle from `rdpie_server_start`, and must not be used
 * again afterwards.
 */
void rdpie_server_stop(struct RdpieServer *server);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* RDPIE_CORE_H */
```

The `/* NEW */` and `/* --- ... --- */` markers above are annotations for this diff description only — the actual regenerated file has no such comments; `cbindgen` output is plain C. When this task is executed, run:

```sh
cbindgen --config crates/rdpie-core/cbindgen.toml --crate rdpie-core --output crates/rdpie-core/include/rdpie_core.h
```

then diff the result against the block above with the markers mentally stripped — content must match exactly; exact blank-line placement between declarations is `cbindgen`'s own formatting and does not need to match this description line-for-line, only declaration content and ordering do.

- [ ] **Step 8: Verify the header contains the new declarations**

Run: `grep -E "RdpieInputEventKind|RdpieInputEvent|RdpieInputCallback|input_callback|input_context" crates/rdpie-core/include/rdpie_core.h`
Expected: all five names present, matching Step 7's content.

- [ ] **Step 9: Commit**

(This commit lands after Task 3 makes the crate compile again — see Task 3 Step 4 — but is listed here since the changes belong to this task's files.)

```bash
git add crates/rdpie-core/src/ffi.rs crates/rdpie-core/cbindgen.toml crates/rdpie-core/include/rdpie_core.h
git commit -m "feat: accept an input callback across the FFI boundary"
```

---

## Task 3: Wire the input handler into `crate::server::run`

**Files:**
- Modify: `crates/rdpie-core/src/server.rs`
- Modify: `crates/rdpie-core/tests/connect.rs`

**Interfaces:**
- Consumes: `RdpieInputHandler` (Task 1); `input_handler_from_config` output threaded in from `rdpie_server_start` (Task 2).
- Produces: `pub async fn run(config: ServerConfig, frames: FrameStream, gfx_factory: RdpieGfxFactory, input_handler: Option<RdpieInputHandler>) -> Result<()>` — the fourth parameter is additive; `None` reproduces the exact pre-Phase-3 `.with_no_input()` behavior.

Builder typestate, verified by reading `third_party/ironrdp/crates/ironrdp-server/src/builder.rs`: `.with_tls(acceptor)` (line 81, on `RdpServerBuilder<WantsSecurity>`) returns `RdpServerBuilder<WantsHandler>`. `.with_input_handler(handler)` and `.with_no_input()` (lines 101 and 114, both `impl RdpServerBuilder<WantsHandler>` starting at line 100) are the two — mutually exclusive — ways to leave that stage; both return `RdpServerBuilder<WantsDisplay>`, so an `if`/`match` choosing between them type-checks cleanly as long as both arms are reached from the same `RdpServerBuilder<WantsHandler>` value. `.with_display_handler(display)` (line 126, `impl RdpServerBuilder<WantsDisplay>`) must come after either of those, exactly matching the existing code's `.with_tls(acceptor).with_no_input().with_display_handler(display)` ordering — this task only replaces the middle call, it does not reorder anything.

- [ ] **Step 1: Change `run`'s signature and builder chain**

In `crates/rdpie-core/src/server.rs`, add the import and update the doc comment and function:

```rust
use crate::display::RdpieDisplay;
use crate::frame::FrameStream;
use crate::gfx::RdpieGfxFactory;
use crate::input::RdpieInputHandler;
```

```rust
/// Build and run the RDP listener until it stops.
///
/// Phase 2 added `gfx_factory`: EGFX/AVC420 joins the raw-bitmap path built
/// in Phase 1 as an alternative, higher-efficiency path for clients that
/// negotiate it — the raw path is not removed, since RemoteFX/bitmap
/// fallback is spec's permanent baseline for clients that don't support
/// EGFX. Phase 3 adds `input_handler`: `Some` wires RDP keyboard/mouse
/// events through to the registered FFI callback (`RdpieInputHandler`,
/// see `input.rs`); `None` preserves the original `.with_no_input()`
/// view-only behavior for callers that never registered one — the FFI
/// layer passes `None` whenever Swift's `RdpieConfig.input_callback` is
/// null, so a non-input-capable session is a deliberate config choice, not
/// a special case threaded through here.
pub async fn run(
    config: ServerConfig,
    frames: FrameStream,
    gfx_factory: RdpieGfxFactory,
    input_handler: Option<RdpieInputHandler>,
) -> Result<()> {
    let identity = TlsIdentityCtx::init_from_paths(&config.cert_pem, &config.key_pem)
        .context("loading the TLS identity")?;
    let acceptor = identity.make_acceptor().context("building the TLS acceptor")?;

    let validator = ExactMatchCredentialValidator::new(config.credentials());
    let display = RdpieDisplay::new(config.size, frames);

    let builder = RdpServer::builder().with_addr(config.bind).with_tls(acceptor);
    let builder = match input_handler {
        Some(handler) => builder.with_input_handler(handler),
        None => builder.with_no_input(),
    };

    let mut server = builder
        .with_display_handler(display)
        .with_credential_validator(Some(Arc::new(validator)))
        .with_gfx_factory(Some(Box::new(gfx_factory)))
        .build();

    tracing::info!(bind = %config.bind, "RDPie listening");
    server.run().await.context("the RDP server stopped with an error")
}
```

- [ ] **Step 2: Run the crate build to confirm the expected break**

Run: `cargo build -p rdpie-core --all-targets`
Expected: FAIL — `crates/rdpie-core/tests/connect.rs` calls `run(config, stream, gfx_factory)` at two call sites (both currently three arguments); the compiler reports a missing fourth argument at both.

- [ ] **Step 3: Update the two `run(...)` call sites in `tests/connect.rs`**

In `crates/rdpie-core/tests/connect.rs`, `server_stays_up_and_accepts_a_connection`:

```rust
            let server =
                tokio::task::spawn_local(async move { run(config, stream, gfx_factory, None).await });
```

And in `a_missing_tls_identity_is_reported_not_panicked`:

```rust
    let error = run(config, stream, gfx_factory, None).await.expect_err("a missing identity must be an error");
```

Both pass `None`: neither test registers an input callback, and both are unaffected by input handling — they only exercise TLS/listener startup, matching their existing scope.

- [ ] **Step 4: Run the full crate test suite to confirm everything compiles and passes**

Run: `cargo test -p rdpie-core`
Expected: PASS, including:
- Task 1's `input::` tests (unaffected by this task).
- Task 2's `ffi::` tests, now able to link since `crate::server::run` finally takes four arguments — in particular `starting_with_a_null_input_callback_still_succeeds_view_only` and `a_registered_callback_is_reachable_through_the_constructed_handler` from Task 2 now pass for the first time.
- `server.rs`'s existing `loopback_config_binds_to_localhost_only` and `credentials_round_trip_into_upstream_type` — unchanged, since they exercise `ServerConfig`, not `run`, and this task adds no new assertions there (this task is wiring, not new logic; Task 1 already covers the translation behavior).

Then run: `cargo test -p rdpie-core --test connect`
Expected: PASS — both integration tests green with the `None` argument added.

- [ ] **Step 5: Commit**

```bash
git add crates/rdpie-core/src/server.rs crates/rdpie-core/tests/connect.rs
git commit -m "feat: thread the optional input handler into the server builder"
```

---

## Task 4: Scancode-to-CGKeyCode lookup table

**Files:**
- Create: `macos/Sources/RdpieCapture/ScancodeMap.swift`
- Test: `macos/Tests/RdpieCaptureTests/ScancodeMapTests.swift`

**Interfaces:**
- Consumes: nothing from an earlier task. Consumes the wire convention fixed
  by the Rust-side FFI contract — `RdpieInputEvent.scancode: uint8_t` is a
  PC/AT Set 1 scancode, `.extended: bool` is the `E0`-prefix flag — without
  depending on the `RdpieInputEvent` type itself (that dependency belongs to
  Task 5, which is the file allowed to import `CRdpieCore`).
- Produces: `struct ScancodeKey: Hashable { let scancode: UInt8; let
  extended: Bool }` and `enum ScancodeMap { static func lookup(scancode:
  UInt8, extended: Bool) -> CGKeyCode? }`, consumed by Task 5's
  `InputInjector.postKey`.

- [ ] **Step 1: Confirm the macOS half of the table against the real SDK header**

Run this exact command (the header path this plan already confirmed present):

```bash
grep -nE "kVK_(ANSI_[A-Za-z0-9]+|Return|Tab|Space|Delete|Escape|Control|Shift|RightControl|RightShift|Option|RightOption|F[0-9]+|Home|End|PageUp|PageDown|ForwardDelete|LeftArrow|RightArrow|UpArrow|DownArrow)\s*=" \
  "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h"
```

This plan's own drafting pass already ran this grep (against the real file,
not from memory) and captured the values every table entry below is built
from — re-run it yourself before typing the table; do not trust the values
transcribed here without that check. Matched lines that anchor the table
(non-exhaustive; the full match set is much longer):

```
kVK_ANSI_A                    = 0x00
kVK_ANSI_0                    = 0x1D
kVK_Return                    = 0x24
kVK_Tab                       = 0x30
kVK_Delete                    = 0x33
kVK_Escape                    = 0x35
kVK_Control                   = 0x3B
kVK_RightControl              = 0x3E
kVK_F1                        = 0x7A
kVK_F5                        = 0x60
kVK_LeftArrow                 = 0x7B
kVK_RightArrow                = 0x7C
kVK_UpArrow                   = 0x7E
kVK_DownArrow                 = 0x7D
kVK_ANSI_KeypadEnter          = 0x4C
kVK_ForwardDelete             = 0x75
```

Also confirm the two imports this file needs, since neither is
`ApplicationServices`: `CGKeyCode` is declared in `CGRemoteOperation.h`
(`typedef uint16_t CGKeyCode;`), part of the `CoreGraphics` module, not
`ApplicationServices` — `import CoreGraphics` alone exposes the typealias.
The `kVK_*` constants themselves live in a completely different framework,
`Carbon.HIToolbox` (the header path above), which Swift cannot see through
`import CoreGraphics` — this needs its own `import Carbon.HIToolbox`. Both
were live-verified during this plan's drafting: `import CoreGraphics` alone
fails to compile `kVK_ANSI_A` ("cannot find 'kVK_ANSI_A' in scope"); adding
`import Carbon.HIToolbox` alongside it compiles and links clean with no
`Package.swift` changes (Swift's autolinking picks up `Carbon.framework`
the same way it already picks up `VideoToolbox`/`CoreMedia`/`CoreVideo` for
`H264Encoder.swift`, with zero `.linkedFramework` entries for any of them).
Neither import pulls in `CGEvent`/`CGEventPost` — `Carbon.HIToolbox` is a
keycode-constants header with no event-posting API in it, so this file stays
exactly as free of live-injection code as `H264NALConverter.swift` stays
free of `VideoToolbox`.

- [ ] **Step 2: Write the failing tests**

```swift
// macos/Tests/RdpieCaptureTests/ScancodeMapTests.swift
import XCTest
@testable import RdpieCapture

final class ScancodeMapTests: XCTestCase {

    func testPlainLetterA() {
        // Set 1 scancode 0x1E is the physical 'A' key -> kVK_ANSI_A (0x00).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x1E, extended: false), 0x00)
    }

    func testDigit1() {
        // Set 1 scancode 0x02 is the physical '1' key -> kVK_ANSI_1 (0x12).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x02, extended: false), 0x12)
    }

    func testExtendedLeftArrow() {
        // E0 0x4B is the Left Arrow -> kVK_LeftArrow (0x7B).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x4B, extended: true), 0x7B)
    }

    func testExtendedRightControl() {
        // E0 0x1D is Right Control -> kVK_RightControl (0x3E). Same base
        // scancode as non-extended 0x1D (Left Control, kVK_Control = 0x3B) —
        // this is the case most likely to get the `extended` flag backwards.
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x1D, extended: true), 0x3E)
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x1D, extended: false), 0x3B)
        XCTAssertNotEqual(
            ScancodeMap.lookup(scancode: 0x1D, extended: false),
            ScancodeMap.lookup(scancode: 0x1D, extended: true))
    }

    func testFunctionKeyF5() {
        // Set 1 scancode 0x3F is F5 -> kVK_F5 (0x60).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x3F, extended: false), 0x60)
    }

    func testUnmappedScancodeReturnsNil() {
        // 0x00 is never assigned in PC/AT Set 1 (scancodes start at 0x01) —
        // a genuinely reserved code, distinct from NumLock/ScrollLock/Insert
        // below, which are real Set 1 codes this table deliberately omits.
        XCTAssertNil(ScancodeMap.lookup(scancode: 0x00, extended: false))
    }

    func testDeliberatelyUnmappedKeysReturnNil() {
        // NumLock (0x45) and ScrollLock (0x46): no physical or virtual
        // equivalent on any modern Mac keyboard — mapping them to something
        // adjacent (e.g. kVK_ANSI_KeypadClear for NumLock) would silently
        // reinterpret a lock-key toggle as an unrelated keypress. Left
        // unmapped rather than guessed; the RDP `Synchronize` PDU that would
        // actually carry lock-key state is out of scope for this phase.
        XCTAssertNil(ScancodeMap.lookup(scancode: 0x45, extended: false))
        XCTAssertNil(ScancodeMap.lookup(scancode: 0x46, extended: false))
        // Insert (E0 0x52): the closest Apple Extended Keyboard correspondence
        // is kVK_Help (0x72), but that key opens macOS Help, a different
        // semantic action from an editor's insert-mode toggle — not a safe
        // guess to bake into a lookup table silently. Left unmapped.
        XCTAssertNil(ScancodeMap.lookup(scancode: 0x52, extended: true))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path macos --filter ScancodeMapTests`
Expected: FAIL — `ScancodeMap` does not exist yet.

- [ ] **Step 4: Write the lookup table**

```swift
// macos/Sources/RdpieCapture/ScancodeMap.swift
import CoreGraphics    // CGKeyCode typealias only (CGRemoteOperation.h)
import Carbon.HIToolbox // kVK_* constants only — no CGEvent API in this header

/// One PC/AT Set 1 scancode, keyed the same way `RdpieInputEvent` carries
/// it on the wire: a base scancode plus the RDP extended-key (`E0`-prefix)
/// flag. Several keys (Left/Right Control, the arrow keys vs. the numeric
/// keypad, KeypadEnter vs. Return) share a base scancode and are only
/// distinguished by this flag — it must be part of the lookup key, not an
/// afterthought.
public struct ScancodeKey: Hashable {
    public let scancode: UInt8
    public let extended: Bool

    public init(scancode: UInt8, extended: Bool) {
        self.scancode = scancode
        self.extended = extended
    }
}

/// RDP's PC/AT Set 1 keyboard scancode -> macOS `CGKeyCode` virtual
/// keycode. Pure data, no `CGEvent`/`ApplicationServices` dependency — see
/// the plan's File Structure rationale (mirrors `H264NALConverter.swift`
/// staying free of `VideoToolbox`).
///
/// The Set 1 half of this table is the standard, widely-documented PC/AT
/// scancode layout. The macOS half was read directly from
/// `Carbon.framework`'s `HIToolbox.framework/Headers/Events.h` (see Task 4
/// Step 1's grep) — not from memory. Keys with no confident macOS
/// equivalent (NumLock, ScrollLock, Insert — see `ScancodeMapTests
/// .testDeliberatelyUnmappedKeysReturnNil`) are left out of the table
/// entirely; `lookup` returns `nil` for them, and the caller (Task 5's
/// `InputInjector`) drops the event rather than injecting a guessed key.
public enum ScancodeMap {

    public static func lookup(scancode: UInt8, extended: Bool) -> CGKeyCode? {
        table[ScancodeKey(scancode: scancode, extended: extended)]
    }

    private static let table: [ScancodeKey: CGKeyCode] = [
        // Row 1: Escape, digits, Minus/Equals, Backspace
        ScancodeKey(scancode: 0x01, extended: false): CGKeyCode(kVK_Escape),
        ScancodeKey(scancode: 0x02, extended: false): CGKeyCode(kVK_ANSI_1),
        ScancodeKey(scancode: 0x03, extended: false): CGKeyCode(kVK_ANSI_2),
        ScancodeKey(scancode: 0x04, extended: false): CGKeyCode(kVK_ANSI_3),
        ScancodeKey(scancode: 0x05, extended: false): CGKeyCode(kVK_ANSI_4),
        ScancodeKey(scancode: 0x06, extended: false): CGKeyCode(kVK_ANSI_5),
        ScancodeKey(scancode: 0x07, extended: false): CGKeyCode(kVK_ANSI_6),
        ScancodeKey(scancode: 0x08, extended: false): CGKeyCode(kVK_ANSI_7),
        ScancodeKey(scancode: 0x09, extended: false): CGKeyCode(kVK_ANSI_8),
        ScancodeKey(scancode: 0x0A, extended: false): CGKeyCode(kVK_ANSI_9),
        ScancodeKey(scancode: 0x0B, extended: false): CGKeyCode(kVK_ANSI_0),
        ScancodeKey(scancode: 0x0C, extended: false): CGKeyCode(kVK_ANSI_Minus),
        ScancodeKey(scancode: 0x0D, extended: false): CGKeyCode(kVK_ANSI_Equal),
        ScancodeKey(scancode: 0x0E, extended: false): CGKeyCode(kVK_Delete), // Backspace

        // Row 2: Tab, Q-P row, brackets, Enter
        ScancodeKey(scancode: 0x0F, extended: false): CGKeyCode(kVK_Tab),
        ScancodeKey(scancode: 0x10, extended: false): CGKeyCode(kVK_ANSI_Q),
        ScancodeKey(scancode: 0x11, extended: false): CGKeyCode(kVK_ANSI_W),
        ScancodeKey(scancode: 0x12, extended: false): CGKeyCode(kVK_ANSI_E),
        ScancodeKey(scancode: 0x13, extended: false): CGKeyCode(kVK_ANSI_R),
        ScancodeKey(scancode: 0x14, extended: false): CGKeyCode(kVK_ANSI_T),
        ScancodeKey(scancode: 0x15, extended: false): CGKeyCode(kVK_ANSI_Y),
        ScancodeKey(scancode: 0x16, extended: false): CGKeyCode(kVK_ANSI_U),
        ScancodeKey(scancode: 0x17, extended: false): CGKeyCode(kVK_ANSI_I),
        ScancodeKey(scancode: 0x18, extended: false): CGKeyCode(kVK_ANSI_O),
        ScancodeKey(scancode: 0x19, extended: false): CGKeyCode(kVK_ANSI_P),
        ScancodeKey(scancode: 0x1A, extended: false): CGKeyCode(kVK_ANSI_LeftBracket),
        ScancodeKey(scancode: 0x1B, extended: false): CGKeyCode(kVK_ANSI_RightBracket),
        ScancodeKey(scancode: 0x1C, extended: false): CGKeyCode(kVK_Return),

        // Row 3: Left Control, A-L row, quotes/grave, Left Shift
        ScancodeKey(scancode: 0x1D, extended: false): CGKeyCode(kVK_Control), // Left Control
        ScancodeKey(scancode: 0x1E, extended: false): CGKeyCode(kVK_ANSI_A),
        ScancodeKey(scancode: 0x1F, extended: false): CGKeyCode(kVK_ANSI_S),
        ScancodeKey(scancode: 0x20, extended: false): CGKeyCode(kVK_ANSI_D),
        ScancodeKey(scancode: 0x21, extended: false): CGKeyCode(kVK_ANSI_F),
        ScancodeKey(scancode: 0x22, extended: false): CGKeyCode(kVK_ANSI_G),
        ScancodeKey(scancode: 0x23, extended: false): CGKeyCode(kVK_ANSI_H),
        ScancodeKey(scancode: 0x24, extended: false): CGKeyCode(kVK_ANSI_J),
        ScancodeKey(scancode: 0x25, extended: false): CGKeyCode(kVK_ANSI_K),
        ScancodeKey(scancode: 0x26, extended: false): CGKeyCode(kVK_ANSI_L),
        ScancodeKey(scancode: 0x27, extended: false): CGKeyCode(kVK_ANSI_Semicolon),
        ScancodeKey(scancode: 0x28, extended: false): CGKeyCode(kVK_ANSI_Quote),
        ScancodeKey(scancode: 0x29, extended: false): CGKeyCode(kVK_ANSI_Grave),
        ScancodeKey(scancode: 0x2A, extended: false): CGKeyCode(kVK_Shift), // Left Shift

        // Row 4: Backslash, Z-M row, punctuation, Right Shift
        ScancodeKey(scancode: 0x2B, extended: false): CGKeyCode(kVK_ANSI_Backslash),
        ScancodeKey(scancode: 0x2C, extended: false): CGKeyCode(kVK_ANSI_Z),
        ScancodeKey(scancode: 0x2D, extended: false): CGKeyCode(kVK_ANSI_X),
        ScancodeKey(scancode: 0x2E, extended: false): CGKeyCode(kVK_ANSI_C),
        ScancodeKey(scancode: 0x2F, extended: false): CGKeyCode(kVK_ANSI_V),
        ScancodeKey(scancode: 0x30, extended: false): CGKeyCode(kVK_ANSI_B),
        ScancodeKey(scancode: 0x31, extended: false): CGKeyCode(kVK_ANSI_N),
        ScancodeKey(scancode: 0x32, extended: false): CGKeyCode(kVK_ANSI_M),
        ScancodeKey(scancode: 0x33, extended: false): CGKeyCode(kVK_ANSI_Comma),
        ScancodeKey(scancode: 0x34, extended: false): CGKeyCode(kVK_ANSI_Period),
        ScancodeKey(scancode: 0x35, extended: false): CGKeyCode(kVK_ANSI_Slash),
        ScancodeKey(scancode: 0x36, extended: false): CGKeyCode(kVK_RightShift),

        // Bottom row: keypad multiply, Alt, Space, CapsLock
        ScancodeKey(scancode: 0x37, extended: false): CGKeyCode(kVK_ANSI_KeypadMultiply),
        ScancodeKey(scancode: 0x38, extended: false): CGKeyCode(kVK_Option), // Left Alt
        ScancodeKey(scancode: 0x39, extended: false): CGKeyCode(kVK_Space),
        ScancodeKey(scancode: 0x3A, extended: false): CGKeyCode(kVK_CapsLock),

        // F1-F10
        ScancodeKey(scancode: 0x3B, extended: false): CGKeyCode(kVK_F1),
        ScancodeKey(scancode: 0x3C, extended: false): CGKeyCode(kVK_F2),
        ScancodeKey(scancode: 0x3D, extended: false): CGKeyCode(kVK_F3),
        ScancodeKey(scancode: 0x3E, extended: false): CGKeyCode(kVK_F4),
        ScancodeKey(scancode: 0x3F, extended: false): CGKeyCode(kVK_F5),
        ScancodeKey(scancode: 0x40, extended: false): CGKeyCode(kVK_F6),
        ScancodeKey(scancode: 0x41, extended: false): CGKeyCode(kVK_F7),
        ScancodeKey(scancode: 0x42, extended: false): CGKeyCode(kVK_F8),
        ScancodeKey(scancode: 0x43, extended: false): CGKeyCode(kVK_F9),
        ScancodeKey(scancode: 0x44, extended: false): CGKeyCode(kVK_F10),

        // 0x45 NumLock, 0x46 ScrollLock: deliberately absent — see
        // ScancodeMapTests.testDeliberatelyUnmappedKeysReturnNil.

        // Numeric keypad
        ScancodeKey(scancode: 0x47, extended: false): CGKeyCode(kVK_ANSI_Keypad7),
        ScancodeKey(scancode: 0x48, extended: false): CGKeyCode(kVK_ANSI_Keypad8),
        ScancodeKey(scancode: 0x49, extended: false): CGKeyCode(kVK_ANSI_Keypad9),
        ScancodeKey(scancode: 0x4A, extended: false): CGKeyCode(kVK_ANSI_KeypadMinus),
        ScancodeKey(scancode: 0x4B, extended: false): CGKeyCode(kVK_ANSI_Keypad4),
        ScancodeKey(scancode: 0x4C, extended: false): CGKeyCode(kVK_ANSI_Keypad5),
        ScancodeKey(scancode: 0x4D, extended: false): CGKeyCode(kVK_ANSI_Keypad6),
        ScancodeKey(scancode: 0x4E, extended: false): CGKeyCode(kVK_ANSI_KeypadPlus),
        ScancodeKey(scancode: 0x4F, extended: false): CGKeyCode(kVK_ANSI_Keypad1),
        ScancodeKey(scancode: 0x50, extended: false): CGKeyCode(kVK_ANSI_Keypad2),
        ScancodeKey(scancode: 0x51, extended: false): CGKeyCode(kVK_ANSI_Keypad3),
        ScancodeKey(scancode: 0x52, extended: false): CGKeyCode(kVK_ANSI_Keypad0),
        ScancodeKey(scancode: 0x53, extended: false): CGKeyCode(kVK_ANSI_KeypadDecimal),

        // F11, F12
        ScancodeKey(scancode: 0x57, extended: false): CGKeyCode(kVK_F11),
        ScancodeKey(scancode: 0x58, extended: false): CGKeyCode(kVK_F12),

        // Extended (E0-prefixed) keys
        ScancodeKey(scancode: 0x1C, extended: true): CGKeyCode(kVK_ANSI_KeypadEnter),
        ScancodeKey(scancode: 0x1D, extended: true): CGKeyCode(kVK_RightControl),
        ScancodeKey(scancode: 0x35, extended: true): CGKeyCode(kVK_ANSI_KeypadDivide),
        ScancodeKey(scancode: 0x38, extended: true): CGKeyCode(kVK_RightOption), // Right Alt
        ScancodeKey(scancode: 0x47, extended: true): CGKeyCode(kVK_Home),
        ScancodeKey(scancode: 0x48, extended: true): CGKeyCode(kVK_UpArrow),
        ScancodeKey(scancode: 0x49, extended: true): CGKeyCode(kVK_PageUp),
        ScancodeKey(scancode: 0x4B, extended: true): CGKeyCode(kVK_LeftArrow),
        ScancodeKey(scancode: 0x4D, extended: true): CGKeyCode(kVK_RightArrow),
        ScancodeKey(scancode: 0x4F, extended: true): CGKeyCode(kVK_End),
        ScancodeKey(scancode: 0x50, extended: true): CGKeyCode(kVK_DownArrow),
        ScancodeKey(scancode: 0x51, extended: true): CGKeyCode(kVK_PageDown),
        // E0 0x52 Insert: deliberately absent — see
        // ScancodeMapTests.testDeliberatelyUnmappedKeysReturnNil.
        ScancodeKey(scancode: 0x53, extended: true): CGKeyCode(kVK_ForwardDelete),
    ]
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path macos --filter ScancodeMapTests`
Expected: PASS, all 7 tests.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/RdpieCapture/ScancodeMap.swift macos/Tests/RdpieCaptureTests/ScancodeMapTests.swift
git commit -m "feat: add RDP scancode to CGKeyCode lookup table"
```

---

## Task 5: CGEvent injection

**Files:**
- Create: `macos/Sources/RdpieCapture/InputInjector.swift`
- Modify: `macos/Package.swift`
- Test: `macos/Tests/RdpieCaptureTests/InputInjectorTests.swift`

**Interfaces:**
- Consumes: `ScancodeMap.lookup(scancode: UInt8, extended: Bool) -> CGKeyCode?`
  (Task 4); the fixed FFI contract's `RdpieInputEvent` (fields `kind:
  RdpieInputEventKind`, `scancode: UInt8`, `extended: Bool`, `x: UInt16`, `y:
  UInt16`, `scroll_delta: Int16`) and `RdpieInputEventKind` C enum (14
  cases, `KeyPressed` through `MouseVerticalScroll`, unprefixed — the Rust
  side declares this enum `#[repr(C)]`, not `#[repr(u8)]`, specifically so
  cbindgen emits a single plain `enum` typedef instead of the C23-conditional
  dual declaration a sized repr would trigger; the latter is genuinely
  ambiguous to Swift's Clang importer, confirmed by compiling a matching
  header — see Task 6 Step 1, which re-confirms this against the real
  generated header before this task's code is wired up), both imported from
  `CRdpieCore` once the Rust-side Tasks 1-3 land and the header is
  regenerated.
- Produces: `public final class InputInjector` with `public static func
  hasAccessibilityPermission() -> Bool`, `public static func
  requestAccessibilityPermission() -> Bool`, `public init()`, `public func
  handle(_ event: RdpieInputEvent)`, `public private(set) var
  droppedEventCount: Int` — consumed by Task 6's `RustBridge`.

- [ ] **Step 1: Give `RdpieCapture` a dependency on `CRdpieCore`**

`RdpieCapture` currently has zero target dependencies in `macos/Package.swift`
— only the `rdpied` executable target depends on `CRdpieCore` today. This
file needs `RdpieInputEvent`/`RdpieInputEventKind`, so the library target
itself needs the dependency, and the test target needs it too (the tests
construct raw `RdpieInputEvent` values directly). Diff:

```diff
     targets: [
-        .target(name: "RdpieCapture"),
+        .target(name: "RdpieCapture", dependencies: ["CRdpieCore"]),
         .systemLibrary(name: "CRdpieCore", path: "Sources/CRdpieCore"),
         .executableTarget(
             name: "rdpied",
             dependencies: ["RdpieCapture", "CRdpieCore"],
             linkerSettings: [
                 .linkedLibrary("z"),
                 .linkedFramework("SystemConfiguration"),
                 .unsafeFlags(["-L../target/release", "-lrdpie_core"])
             ]
         ),
-        .testTarget(name: "RdpieCaptureTests", dependencies: ["RdpieCapture"]),
+        .testTarget(name: "RdpieCaptureTests", dependencies: ["RdpieCapture", "CRdpieCore"]),
     ]
```

No `linkerSettings` addition is needed for `ApplicationServices`/
`CoreGraphics` on the `RdpieCapture` target. This was live-verified during
this plan's drafting: a plain `swiftc` file that does `import
ApplicationServices` and calls `AXIsProcessTrusted()`, constructs every
`CGEvent` variant this task needs, and links, with zero `-framework` flags
passed — Swift's autolinking resolves it from the `import` alone, the same
way `H264Encoder.swift` already gets `VideoToolbox`/`CoreMedia`/
`CoreVideo` linked with no corresponding `Package.swift` entry.

- [ ] **Step 2: Write the failing tests**

```swift
// macos/Tests/RdpieCaptureTests/InputInjectorTests.swift
import XCTest
import CRdpieCore
@testable import RdpieCapture

final class InputInjectorTests: XCTestCase {

    // Every kind the fixed FFI contract defines. Listed explicitly (not
    // derived by reflection) so this test breaks, loudly, if a case is ever
    // added here without a matching one in `InputInjector.handle`.
    private let allKinds: [RdpieInputEventKind] = [
        KeyPressed,
        KeyReleased,
        MouseMove,
        MouseLeftPressed,
        MouseLeftReleased,
        MouseRightPressed,
        MouseRightReleased,
        MouseMiddlePressed,
        MouseMiddleReleased,
        MouseButton4Pressed,
        MouseButton4Released,
        MouseButton5Pressed,
        MouseButton5Released,
        MouseVerticalScroll,
    ]

    private func sampleEvent(kind: RdpieInputEventKind) -> RdpieInputEvent {
        // Field values only need to be well-formed enough not to trap
        // (a mapped scancode, in-range coordinates) — this suite never
        // reaches the point of inspecting the posted event's content.
        RdpieInputEvent(kind: kind, scancode: 0x1E /* kVK_ANSI_A */,
                         extended: false, x: 100, y: 100, scroll_delta: 120)
    }

    func testHasAccessibilityPermissionReturnsWithoutCrashing() {
        // Never trusted in a CI/sandboxed test runner — this only proves
        // the call is safe to make and returns a Bool, not any particular
        // value. Do not assert `== false` here: an interactively-run local
        // test suite on an already-trusted terminal would fail spuriously.
        _ = InputInjector.hasAccessibilityPermission()
    }

    func testHandleDropsEveryKindWhenAccessibilityNotGranted() throws {
        try XCTSkipIf(
            InputInjector.hasAccessibilityPermission(),
            "This runner is Accessibility-trusted; the drop path can't be "
                + "exercised here. Live CGEventPost verification is a later task.")

        let injector = InputInjector()
        XCTAssertEqual(injector.droppedEventCount, 0)

        for (index, kind) in allKinds.enumerated() {
            injector.handle(sampleEvent(kind: kind))
            XCTAssertEqual(
                injector.droppedEventCount, index + 1,
                "kind at index \(index) should have been dropped exactly once")
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path macos --filter InputInjectorTests`
Expected: FAIL — `InputInjector` does not exist yet.

- [ ] **Step 4: Write `InputInjector`**

```swift
// macos/Sources/RdpieCapture/InputInjector.swift
import Foundation
import ApplicationServices // AXIsProcessTrusted + CGEvent; re-exports CoreGraphics,
                            // matching spikes/cgevent-injection/main.swift's import list
import CRdpieCore

/// Turns one `RdpieInputEvent` from the Rust core into a real, system-wide
/// `CGEvent`. The only file in this target that touches `CGEvent`/
/// `ApplicationServices` — see the plan's File Structure rationale.
///
/// One `InputInjector` is owned by `RustBridge` (Task 6) for the life of
/// the process and is called synchronously, serially, from the Rust core's
/// single dedicated per-connection thread (see this plan's Global
/// Constraints) — there is never more than one in-flight call into a given
/// instance, so `droppedEventCount` needs no synchronization.
public final class InputInjector {

    /// Counts every event this injector dropped instead of posting —
    /// Accessibility not granted, an unmapped scancode, or `CGEvent`
    /// construction itself returning `nil`. Mirrors `RustBridge
    /// .droppedFrames`: a plain counter is enough to notice drops are
    /// happening at all; per-drop diagnostics already go to stderr below.
    public private(set) var droppedEventCount = 0

    private let source = CGEventSource(stateID: .hidSystemState)

    public init() {}

    /// Confirmed by `spikes/cgevent-injection/RESULTS.md` to be exactly the
    /// gate `CGEventPost` needs, with no extra entitlement, from a plain
    /// (even unsigned) binary — this call mirrors that spike's usage
    /// verbatim.
    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// `AXIsProcessTrustedWithOptions(prompt: true)` — same spike. Only
    /// takes effect on next launch, the same one-shot-prompt pattern
    /// `ScreenCaptureKitSource`'s Screen Recording grant flow already uses.
    public static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Called from Task 6's `@convention(c)` callback with one already-
    /// copied event value (`event.pointee`, not the raw pointer) — the FFI
    /// contract's "valid only for the call's duration" note is Task 6's
    /// concern to satisfy before this method ever sees the value, so
    /// nothing here needs to reason about pointer lifetime.
    public func handle(_ event: RdpieInputEvent) {
        guard Self.hasAccessibilityPermission() else {
            // Global Constraint: clients before Accessibility is granted,
            // and Accessibility revoked mid-session, must not crash the
            // connection — drop the event, don't error the session.
            droppedEventCount += 1
            return
        }

        switch event.kind {
        case KeyPressed:
            postKey(event, keyDown: true)
        case KeyReleased:
            postKey(event, keyDown: false)
        case MouseMove:
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                          mouseCursorPosition: CGPoint(x: Int(event.x), y: Int(event.y)),
                          mouseButton: .left))
        case MouseLeftPressed:
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .left))
        case MouseLeftReleased:
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .left))
        case MouseRightPressed:
            post(CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .right))
        case MouseRightReleased:
            post(CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .right))
        case MouseMiddlePressed:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .center))
        case MouseMiddleReleased:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .center))
        case MouseButton4Pressed:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button4))
        case MouseButton4Released:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button4))
        case MouseButton5Pressed:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button5))
        case MouseButton5Released:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button5))
        case MouseVerticalScroll:
            // `CGMouseButton` only declares 3 named cases (left/right/center
            // = 0/1/2) — there is no `CGEventType` case for a 4th/5th
            // button either, only the generic `.otherMouseDown`/`Up` used
            // above for the middle button too, disambiguated by which
            // `CGMouseButton` raw value is passed. Verified live during
            // this plan's drafting: `CGMouseButton(rawValue: 3)` and
            // `(rawValue: 4)` both compile and construct successfully
            // (this initializer never actually fails for an in-range
            // `UInt32`, despite being spelled as failable) — matches the
            // documented technique other CGEvent-based automation tools use
            // for buttons beyond the first three.
            //
            // ponytail: RDP's wheel delta (~+-120 per notch, Windows
            // WHEEL_DELTA-scaled) is passed through unchanged per the FFI
            // contract's "do not renormalize" note. `.pixel` units keep
            // that magnitude closer to sane than `.line` units would (which
            // reads the same 120 as 120 *lines* per notch — a much larger
            // distortion). Revisit the unit choice if live client testing
            // shows scroll feels wrong; the contract forbids rescaling the
            // value itself, not picking a different `CGScrollEventUnit`.
            post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                          wheel1: Int32(event.scroll_delta), wheel2: 0, wheel3: 0))
        default:
            // Reachable only if the Rust core ever adds a new
            // `RdpieInputEventKind` case without a matching branch above —
            // cbindgen emits this as a plain C enum, which Swift imports as
            // an open, non-frozen type, so the compiler requires this
            // branch even though every currently-defined case is handled
            // explicitly above. Not a silent catch-all: it logs and drops,
            // same as every other drop path in this method.
            FileHandle.standardError.write(
                "InputInjector: unrecognized RdpieInputEventKind — dropping\n"
                    .data(using: .utf8)!)
            droppedEventCount += 1
        }
    }

    private static let button4 = CGMouseButton(rawValue: 3)!
    private static let button5 = CGMouseButton(rawValue: 4)!

    private func postKey(_ event: RdpieInputEvent, keyDown: Bool) {
        guard let keyCode = ScancodeMap.lookup(scancode: event.scancode, extended: event.extended) else {
            FileHandle.standardError.write(
                "InputInjector: no CGKeyCode for scancode 0x\(String(event.scancode, radix: 16)) (extended: \(event.extended)) — dropping\n"
                    .data(using: .utf8)!)
            droppedEventCount += 1
            return
        }
        post(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown))
    }

    /// Button press/release events carry no coordinates on the wire (`x`/`y`
    /// are documented as meaningful for `MouseMove` only) — RDP always
    /// sends a `Move` to position the cursor before a click. Reading the
    /// live cursor position back is the same technique
    /// `spikes/cgevent-injection/main.swift` used to confirm a posted move
    /// landed; reusing it here avoids this class tracking cursor state of
    /// its own.
    private func currentCursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func post(_ event: CGEvent?) {
        guard let event else {
            droppedEventCount += 1
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path macos --filter InputInjectorTests`
Expected: PASS if the runner is not Accessibility-trusted (the common case
in CI); `testHandleDropsEveryKindWhenAccessibilityNotGranted` reports as
skipped rather than failing if the runner happens to be trusted.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/RdpieCapture/InputInjector.swift macos/Package.swift macos/Tests/RdpieCaptureTests/InputInjectorTests.swift
git commit -m "feat: inject RDP input events as CGEvents behind an Accessibility gate"
```

---

## Task 6: Wire the callback into RustBridge and the daemon

**Files:**
- Modify: `macos/Sources/rdpied/RustBridge.swift:1-45` (imports, `start`)
- Modify: `macos/Sources/rdpied/main.swift:1-37` (startup), `:43-83` (frame loop)
- Modify: `docs/running-phase-3.md` (new file, written as part of this task)

**Interfaces:**
- Consumes: `InputInjector` (Task 5) — `init()`, `handle(_:)`,
  `hasAccessibilityPermission()`; the fixed FFI contract's `RdpieConfig
  .input_callback: RdpieInputCallback` / `.input_context: *mut c_void`
  fields and `RdpieInputCallback` typedef (Rust-side Tasks 1-3); the
  existing `RustBridge.start(port:width:height:username:password:
  certPath:keyPath:)` signature this task extends in place (no signature
  change — the new fields are populated internally, not passed in by
  `main.swift`).
- Produces: nothing consumed by a later task in this plan — this is the
  integration point that finishes the feature.

- [ ] **Step 1: Confirm the regenerated header matches the verified shape**

This task depends on Rust-side Tasks 1-3 (drafted in parallel against the
same fixed contract) having landed and `just build-rust` having regenerated
`macos/Sources/CRdpieCore/include/rdpie_core.h`. Task 2's header text was not
just hand-derived — it was confirmed by actually running `cbindgen` against a
matching throwaway crate and compiling the result against a matching Swift
file (`swiftc -typecheck`), so this step is a fast confirmation, not
open-ended discovery:

```bash
grep -n "RdpieConfig\|RdpieInputCallback\|input_callback\|input_context" \
  macos/Sources/CRdpieCore/include/rdpie_core.h
```

Confirm both of these hold (Task 2's Step 7 has the full verified header
text to compare against):

1. **`input_callback` is a plain nullable C function pointer**
   (`void (*input_callback)(void *context, const struct RdpieInputEvent
   *event);`), not an opaque `struct Option_RdpieInputCallback` wrapper.
   This only happens if Task 2 declared the field with the function
   signature written inline and wrapped in `Option`, not through the named
   `RdpieInputCallback` type alias — `cbindgen` only collapses `Option<T>`
   to a bare nullable pointer when it can resolve `T` to a function-pointer
   type in place; going through a named alias defeats that and produces the
   broken wrapper struct instead (confirmed by generating both forms and
   diffing the output). If Task 2 was implemented with the alias form
   instead, that is a defect to flag, not a naming variant to shrug off —
   the wrapper struct is not something Swift can assign a callback to at
   all.
2. **`RdpieInputEventKind`'s cases import into Swift unprefixed**
   (`KeyPressed`, not `RdpieInputEventKind_KeyPressed` or any other
   prefixed form) — this requires the enum to be declared `#[repr(C)]` on
   the Rust side, not `#[repr(u8)]`; a sized repr makes `cbindgen` emit a
   `#if __STDC_VERSION__ >= 202311L` conditional dual declaration (a
   C23-typed enum plus a pre-C23 `typedef uint8_t RdpieInputEventKind`
   fallback) that Swift's Clang importer reports as genuinely ambiguous
   (`'RdpieInputEventKind' is ambiguous for type lookup`) — confirmed by
   compiling exactly that shape. Task 5's `switch` and this task's
   `default`-branch comment already assume the plain, unprefixed,
   unambiguous form; if the header doesn't match, the fix is Task 1's enum
   declaration, not a rename here.

- [ ] **Step 2: Add the C-callable callback and wire it into `RustBridge`**

```diff
--- a/macos/Sources/rdpied/RustBridge.swift
+++ b/macos/Sources/rdpied/RustBridge.swift
@@
 import Foundation
 import CRdpieCore
 import RdpieCapture
 
 enum BridgeError: Error {
     case serverFailedToStart
 }
 
+/// The C ABI's `RdpieInputCallback` cannot capture Swift closure state — it
+/// is a bare function pointer. Object identity is recovered from `context`
+/// instead: `RustBridge.start` passes `Unmanaged.passUnretained(self)
+/// .toOpaque()` as `input_context`, and this function reverses that to get
+/// back the `RustBridge` instance whose `inputInjector` should handle the
+/// event. `passUnretained`, not `passRetained`: `RustBridge` (owned by
+/// `main.swift`'s top-level `bridge` binding) already outlives the Rust
+/// server handle for the whole process lifetime, so there is no dangling-
+/// pointer risk to guard against with an extra retain.
+///
+/// `event` is valid only for the duration of this call (per the FFI
+/// contract) — `.pointee` copies the value out before handing it to
+/// `InputInjector.handle`, which is free to outlive this call.
+private func rdpieHandleInputEvent(_ context: UnsafeMutableRawPointer?, _ event: UnsafePointer<RdpieInputEvent>?) {
+    guard let context, let event else { return }
+    let bridge = Unmanaged<RustBridge>.fromOpaque(context).takeUnretainedValue()
+    bridge.inputInjector.handle(event.pointee)
+}
+
 /// Owns the Rust server handle and pushes frames into it.
 ///
 /// cbindgen emits `typedef struct RdpieServer RdpieServer;` — an opaque
 /// forward declaration — so Swift imports every `RdpieServer *` as
 /// `OpaquePointer?`, not `UnsafeMutablePointer<RdpieServer>?`. Pass `handle`
 /// straight through to the C functions; no `assumingMemoryBound` cast needed
 /// or possible.
 final class RustBridge {
     private var handle: OpaquePointer?
     private(set) var droppedFrames = 0
+
+    /// Owned for the life of this bridge so `rdpieHandleInputEvent` always
+    /// has somewhere real to deliver events, from process startup — before
+    /// any client has connected — through to `stop()`.
+    let inputInjector = InputInjector()
 
     func start(port: UInt16, width: Int, height: Int,
                username: String, password: String,
                certPath: String, keyPath: String) throws {
         try username.withCString { user in
             try password.withCString { pass in
                 try certPath.withCString { cert in
                     try keyPath.withCString { key in
                         var config = RdpieConfig(
                             port: port,
                             width: UInt16(width),
                             height: UInt16(height),
                             username: user,
                             password: pass,
                             cert_pem_path: cert,
-                            key_pem_path: key
+                            key_pem_path: key,
+                            input_callback: rdpieHandleInputEvent,
+                            input_context: Unmanaged.passUnretained(self).toOpaque()
                         )
                         guard let handle = rdpie_server_start(&config) else {
                             throw BridgeError.serverFailedToStart
                         }
                         self.handle = handle
                     }
                 }
             }
         }
     }
```

(`input_callback`/`input_context` are appended after the existing seven
fields, matching Task 2's verified field order — Swift's imported
memberwise initializer for a C struct takes arguments in the struct's
actual declared order, which is why this diff appends rather than inserts
elsewhere.)

- [ ] **Step 3: Add the initial Accessibility check to `main.swift`**

Exit codes already in use: `2` (missing `RDPIE_PASSWORD`), `3` (missing
Screen Recording permission). This is the next one, `4`:

```diff
--- a/macos/Sources/rdpied/main.swift
+++ b/macos/Sources/rdpied/main.swift
@@
 if !useSynthetic && !ScreenCaptureKitSource.hasPermission() {
     FileHandle.standardError.write(
         "Screen Recording permission is required. Grant it in System Settings › Privacy & Security › Screen Recording, then run again.\n"
             .data(using: .utf8)!)
     exit(3)
 }
 
+if !InputInjector.hasAccessibilityPermission() {
+    FileHandle.standardError.write(
+        "Accessibility permission is required for input control. Grant it in System Settings › Privacy & Security › Accessibility, then run again.\n"
+            .data(using: .utf8)!)
+    exit(4)
+}
+
 let bridge = RustBridge()
```

- [ ] **Step 4: Add the mid-session revocation poll to the frame loop**

```diff
--- a/macos/Sources/rdpied/main.swift
+++ b/macos/Sources/rdpied/main.swift
@@
 var h264Encoder: H264Encoder?
 var wasGfxActive = false
+var wasAccessibilityGranted = true // Step 3's check already required this true to get here
 let encoderClockStart = DispatchTime.now()
 
 for await frame in source.frames {
+    let accessibilityGranted = InputInjector.hasAccessibilityPermission()
+    if wasAccessibilityGranted && !accessibilityGranted {
+        // Global Constraint: downgrade to view-only, don't tear down the
+        // connection. `InputInjector.handle` already drops every event on
+        // its own when this happens — nothing here needs to touch
+        // `source`/`bridge` — this line exists purely so a revocation is
+        // visible in the log instead of silently going unnoticed.
+        FileHandle.standardError.write(
+            "Accessibility permission revoked — continuing in view-only mode.\n"
+                .data(using: .utf8)!)
+    }
+    wasAccessibilityGranted = accessibilityGranted
+
     let gfxActive = bridge.isGfxActive()
     if gfxActive && !wasGfxActive {
```

- [ ] **Step 5: Build and confirm the new symbols compile**

```bash
just build
```

Expected: "Build complete!" with no errors. This is the first point at
which Swift actually sees the regenerated `RdpieInputEvent`/
`RdpieInputEventKind`/`RdpieInputCallback` symbols from Rust Tasks 1-3 —
Step 1's header check should already have caught a field-order or
enum-case-spelling mismatch, but a build failure here is the backstop.

- [ ] **Step 6: Run the full Swift test suite**

```bash
just test-swift
```

Expected: PASS, including Task 4's `ScancodeMapTests` and Task 5's
`InputInjectorTests`.

- [ ] **Step 7: Write `docs/running-phase-3.md`**

`docs/running-phase-1.md` and `docs/running-phase-2.md` both open with a
`## Build` / `## Run` pair before any live-verification section; this
follows the same shape. The live client-compatibility and Accessibility-
revocation verification passes are out of this task's scope (this task
wires the Swift side and gets it building and unit-tested, not a live
end-to-end RDP session) — this doc entry covers build/run/how-to-grant, not
fabricated test results.

```markdown
# Running RDPie — Phase 3

## Build

Same as Phase 1/2 (`docs/running-phase-1.md`), plus the header now
declares the input ABI:

\`\`\`sh
just build
\`\`\`

Confirmed the regenerated header declares the new symbols:

\`\`\`sh
grep -n "RdpieInputEvent\|RdpieInputCallback\|input_callback" macos/Sources/CRdpieCore/include/rdpie_core.h
\`\`\`

## Run

\`\`\`sh
RDPIE_PASSWORD=hunter2 RUST_LOG=debug just run
\`\`\`

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
```

- [ ] **Step 8: Commit**

```bash
git add macos/Sources/rdpied/RustBridge.swift macos/Sources/rdpied/main.swift docs/running-phase-3.md
git commit -m "feat: wire RDP input events into CGEvent injection"
```

---

## Task 7: Opt-in non-loopback bind for testing from a real RDP client

**Rationale:** Phases 1-2 verified over loopback only. Input is the one
feature where testing over a real network path from a real device — not
`xfreerdp` on the same machine — actually exercises something loopback
can't: real RDP traffic carrying keyboard/mouse PDUs. Spec §8.5 mandates
loopback as the default with "explicit opt-in to a wider interface" as the
correct shape for anything wider — this task is exactly that opt-in, gated
behind an env var nobody sets by accident, default behavior unchanged.

**Files:**
- Modify: `crates/rdpie-core/src/server.rs`
- Modify: `crates/rdpie-core/src/ffi.rs`
- Modify: `crates/rdpie-core/include/rdpie_core.h`
- Modify: `macos/Sources/rdpied/RustBridge.swift`
- Modify: `macos/Sources/rdpied/main.swift`
- Modify: `docs/running-phase-3.md`

**Interfaces:**
- Consumes: nothing from Tasks 1-6.
- Produces: `ServerConfig::new(port, bind_all, size, username, password, cert_pem, key_pem)` replacing `ServerConfig::loopback(...)`; `RdpieConfig.bind_all: bool`.

- [ ] **Step 1: Write the failing test**

Add to `crates/rdpie-core/src/server.rs`'s existing `#[cfg(test)] mod tests`:

```rust
#[test]
fn bind_all_true_binds_to_the_unspecified_address() {
    let config = ServerConfig::new(
        3389,
        true,
        DesktopSize { width: 1280, height: 720 },
        "rdpie".to_owned(),
        "hunter2".to_owned(),
        PathBuf::from("/tmp/cert.pem"),
        PathBuf::from("/tmp/key.pem"),
    );
    assert_eq!(config.bind.ip(), IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    assert_eq!(config.bind.port(), 3389);
}
```

Also update the existing `config()` test helper and `loopback_config_binds_to_localhost_only` to call `ServerConfig::new(3389, false, ...)` instead of `ServerConfig::loopback(3389, ...)` — same seven-then-eight-argument shift the whole task makes everywhere `loopback` was called.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p rdpie-core server::`
Expected: FAIL to compile — `ServerConfig::new` doesn't exist yet, and the updated `config()` helper's call doesn't match `loopback`'s signature.

- [ ] **Step 3: Rename `loopback` to `new` and add `bind_all`**

In `crates/rdpie-core/src/server.rs`:

```rust
impl ServerConfig {
    /// Binds to loopback unless `bind_all` is set, in which case it binds
    /// the unspecified address (all interfaces). Spec section 8.5 makes
    /// loopback the only safe default; `bind_all` is the explicit opt-in
    /// section 8.5 calls for, not a convenience — callers set it from an
    /// explicit environment variable, never implicitly.
    pub fn new(
        port: u16,
        bind_all: bool,
        size: DesktopSize,
        username: String,
        password: String,
        cert_pem: PathBuf,
        key_pem: PathBuf,
    ) -> Self {
        let bind_ip = if bind_all {
            IpAddr::V4(Ipv4Addr::UNSPECIFIED)
        } else {
            IpAddr::V4(Ipv4Addr::LOCALHOST)
        };
        Self {
            bind: SocketAddr::new(bind_ip, port),
            size,
            username,
            password,
            cert_pem,
            key_pem,
        }
    }
}
```

Remove the old `loopback` associated function; `new` replaces it (its only
caller is `ffi.rs`'s `rdpie_server_start`, updated in Step 4).

- [ ] **Step 4: Thread `bind_all` through the FFI**

In `crates/rdpie-core/src/ffi.rs`, add the field to `RdpieConfig`:

```rust
#[repr(C)]
pub struct RdpieConfig {
    pub port: u16,
    pub width: u16,
    pub height: u16,
    pub username: *const c_char,
    pub password: *const c_char,
    pub cert_pem_path: *const c_char,
    pub key_pem_path: *const c_char,
    pub input_callback: Option<unsafe extern "C" fn(context: *mut c_void, event: *const RdpieInputEvent)>,
    pub input_context: *mut c_void,
    /// See `ServerConfig::new`. `false` unless the caller has deliberately
    /// opted in — matches spec section 8.5's loopback-by-default mandate.
    pub bind_all: bool,
}
```

And update the one call site inside `rdpie_server_start` — only the
`ServerConfig::loopback(...)` call changes; the `input_handler` line Task 2
added directly beneath it is untouched:

```diff
-    let server_config = crate::server::ServerConfig::loopback(
-        config.port,
-        crate::DesktopSize { width: config.width, height: config.height },
-        username,
-        password,
-        cert.into(),
-        key.into(),
-    );
+    let server_config = crate::server::ServerConfig::new(
+        config.port,
+        config.bind_all,
+        crate::DesktopSize { width: config.width, height: config.height },
+        username,
+        password,
+        cert.into(),
+        key.into(),
+    );
     let input_handler = input_handler_from_config(config);
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cargo test -p rdpie-core`
Expected: PASS, including `bind_all_true_binds_to_the_unspecified_address` and every existing test updated in Step 1.

- [ ] **Step 6: Regenerate the header**

```sh
cbindgen --config crates/rdpie-core/cbindgen.toml --crate rdpie-core --output crates/rdpie-core/include/rdpie_core.h
grep -n "bind_all" crates/rdpie-core/include/rdpie_core.h
```

Expected: one new line, `bool bind_all;`, appended inside `RdpieConfig`'s
declaration after `input_context` — a plain `bool` field needs none of Task
2's `Option`/enum-repr care, since it isn't wrapped in `Option` and carries
no discriminant.

- [ ] **Step 7: Wire `bindAll` into `RustBridge` and `main.swift`**

In `macos/Sources/rdpied/RustBridge.swift`, extend `start` with a defaulted
parameter (Swift-internal API, not part of the C ABI, so a default is safe
here unlike anything crossing the FFI boundary) and thread it into the
config literal:

```diff
     func start(port: UInt16, width: Int, height: Int,
                username: String, password: String,
-               certPath: String, keyPath: String) throws {
+               certPath: String, keyPath: String, bindAll: Bool = false) throws {
         try username.withCString { user in
             try password.withCString { pass in
                 try certPath.withCString { cert in
                     try keyPath.withCString { key in
                         var config = RdpieConfig(
                             port: port,
                             width: UInt16(width),
                             height: UInt16(height),
                             username: user,
                             password: pass,
                             cert_pem_path: cert,
                             key_pem_path: key,
                             input_callback: rdpieHandleInputEvent,
-                            input_context: Unmanaged.passUnretained(self).toOpaque()
+                            input_context: Unmanaged.passUnretained(self).toOpaque(),
+                            bind_all: bindAll
                         )
```

In `macos/Sources/rdpied/main.swift`, read the opt-in env var and pass it
through:

```diff
 let certPath = ProcessInfo.processInfo.environment["RDPIE_CERT"] ?? "./cert.pem"
 let keyPath = ProcessInfo.processInfo.environment["RDPIE_KEY"] ?? "./key.pem"
+let bindAll = ProcessInfo.processInfo.environment["RDPIE_BIND_ALL"] == "1"
```

```diff
 let bridge = RustBridge()
 try bridge.start(port: 3389, width: width, height: height,
                  username: username, password: password,
-                 certPath: certPath, keyPath: keyPath)
+                 certPath: certPath, keyPath: keyPath, bindAll: bindAll)
```

- [ ] **Step 8: Build and confirm**

```bash
just build
```

Expected: "Build complete!" with no errors.

- [ ] **Step 9: Update `docs/running-phase-3.md`**

Add, under the existing "Run" section (written in Task 6 Step 7):

```markdown
### Testing from a real RDP client, not just loopback

By default `rdpied` only accepts connections from the same machine (spec
section 8.5's mandated default). To test input from an actual device on
your network:

\`\`\`sh
RDPIE_PASSWORD=hunter2 RDPIE_BIND_ALL=1 just run
\`\`\`

This binds all interfaces, not just loopback. Do not do this on a network
you don't trust, and never expose port 3389 directly to the internet — see
the top-level README's network-exposure warning (VPN/Tailscale/SSH tunnel
for anything beyond a trusted LAN). Omit `RDPIE_BIND_ALL` (or set it to
anything other than `1`) to stay loopback-only.
```

- [ ] **Step 10: Commit**

```bash
git add crates/rdpie-core/src/server.rs crates/rdpie-core/src/ffi.rs crates/rdpie-core/include/rdpie_core.h macos/Sources/rdpied/RustBridge.swift macos/Sources/rdpied/main.swift docs/running-phase-3.md
git commit -m "feat: add an opt-in non-loopback bind for testing from a real client"
```

---

## Exit Criteria

- `cargo test -p rdpie-core` passes, including Task 1's translation tests,
  Task 2's FFI construction/registration tests, and the updated `connect.rs`
  integration tests.
- `just test-swift` passes, including Task 4's `ScancodeMapTests` and Task
  5's `InputInjectorTests`.
- `just build` produces a daemon whose header (`rdpie_core.h`) declares
  `RdpieInputEventKind`, `RdpieInputEvent`, `RdpieInputCallback`, and
  `RdpieConfig`'s `input_callback`/`input_context`/`bind_all` fields exactly
  as verified in Task 2 Step 7 and Task 7 Step 6.
- A live pass of `docs/running-phase-3.md`'s verification checklist:
  keyboard input, mouse move/click, and vertical scroll all reach the Mac
  through a connected RDP client; Accessibility revoked mid-session leaves
  the connection open in view-only mode (video keeps flowing, input stops);
  re-granting Accessibility resumes input without a reconnect.
- At least one of those live passes happens over `RDPIE_BIND_ALL=1` from a
  second physical or virtual machine, not just loopback (Task 7) — the
  point of that task is exercising the real RDP input wire path, not just
  compiling it.
- No `unwrap()`/`expect()` on any path reachable from client-supplied PDU
  data, matching the plan's Global Constraints (mutex-poisoning `.expect()`
  in test-only code is the sole carried-over exception, per Phase 0-1/2).
- Every `KeyboardEvent`/`MouseEvent` variant is either translated or
  explicitly logged-and-dropped — no wildcard `_ =>` arm exists in
  `RdpieInputHandler::keyboard`/`mouse` (Task 1) or `InputInjector.handle`'s
  `RdpieInputEventKind` switch (Task 5, modulo the `default:` branch Swift's
  non-frozen-enum import forces syntactically, which itself logs and drops
  rather than silently swallowing).

## What Phase 4 Inherits

- A working, bidirectional Rust↔Swift FFI callback pattern
  (`RdpieInputCallback` + `Unmanaged<RustBridge>` context recovery) that
  Phase 4's clipboard channel (CLIPRDR) can follow directly rather than
  re-deriving — clipboard data flowing Swift→Rust→client and
  client→Rust→Swift is architecturally the same shape as input events
  flowing client→Rust→Swift, just with a byte buffer instead of a fixed
  struct.
- A verified, general answer to "how does a TCC permission gate get
  checked at startup and polled for mid-session revocation without tearing
  down the connection" (Task 6's Accessibility check/poll) — any future
  phase needing a similar macOS permission (e.g. a hypothetical clipboard
  entitlement, though none is currently expected) has a concrete pattern to
  copy instead of inventing one.
- The unresolved PAM-gate design question (this plan's Scope section) is
  still open and still not this phase's job to resolve — flagging it again
  here so it isn't lost: whoever picks up spec §3.5's optional PAM gate
  needs a UX/protocol answer for how a second credential reaches an
  already-input-gated session, with `spikes/pam-auth/RESULTS.md` as
  verified groundwork.
- The `RDPIE_BIND_ALL` opt-in (Task 7) is available to every later phase's
  own live-testing needs, not just this one's.
