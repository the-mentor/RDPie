# Phase 5: Clipboard (CLIPRDR) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bidirectional plain-text clipboard sync between the connected RDP client and the Mac's `NSPasteboard`, via MS-RDPECLIP (CLIPRDR).

**Architecture:** A new `crates/rdpie-core/src/clipboard.rs` implements `ironrdp_cliprdr::backend::CliprdrBackend`, emitting `ClipboardMessage`s that `ironrdp-server`'s own event loop turns into real protocol traffic — no shared mutex-wrapped server handle to manage ourselves (CLIPRDR is a plain SVC, not a DVC like EGFX). The FFI layer adds one submit function (Mac → remote) and one callback (remote → Mac). Swift polls `NSPasteboard.general.changeCount` inside the existing capture loop — no new timer.

**Tech Stack:** `ironrdp-cliprdr` 0.7 (new direct dependency), `ironrdp-core` 0.2 (new direct dependency, needed for the `impl_as_any!` macro `CliprdrBackend` requires), Swift `NSPasteboard`.

**Spec:** `docs/superpowers/specs/2026-08-23-rdpie-design.md` §5.4 Clipboard.

**Deviations from §5.4, approved during brainstorming:**
- §5.4 says v1 supports "plain text (UTF-8/UTF-16), RTF, and PNG/TIFF images." This phase implements **plain text only** — RTF and images are deferred, not attempted.
- §5.4 says "large transfers use CLIPRDR's delayed-rendering mechanism rather than being pushed eagerly." This phase implements true delayed rendering for the Mac→remote direction (advertise now, send actual data only when the client pastes), but **eagerly fetches** on the remote→Mac direction (request the actual text as soon as the remote's clipboard changes, rather than waiting for a local paste). For plain text this costs a small, bounded amount of unnecessary data transfer in exchange for not needing `NSPasteboardItemDataProvider` promise-based lazy rendering on the Swift side.

## Global Constraints

- Clipboard sync has no server-side gate: CLIPRDR is a channel the RDP *client* chooses to open (e.g. mstsc's "Clipboard" checkbox under Local Resources) — RDPie supports it whenever offered, the same as EGFX only activating when a client negotiates it. No new permission flag, no Accessibility tie-in.
- `rdpie-core` must never depend on an Apple framework (see `lib.rs`'s module doc) — everything in `clipboard.rs` must build and test on Linux CI, same as `gfx.rs`/`input.rs`.
- Plain text only: no RTF, no images, no files, no clipboard locking. `CliprdrBackend`'s file/lock-related trait methods are implemented as no-ops (most already have `do nothing` default bodies in the trait itself; `on_lock`/`on_unlock`/`on_format_data_request`'s non-text branch are the only ones this plan implements as explicit no-ops).
- Follow the FFI callback pattern already established in `ffi.rs`/`input.rs`: any `Option<extern "C" fn(...)>` field on `RdpieConfig` is written with its signature inlined, never through a named type alias — going through an alias defeats `cbindgen`'s `Option<T>`-to-nullable-pointer collapsing (confirmed the hard way during Phase 3; see `RdpieConfig::input_callback`'s doc comment in `ffi.rs`).

---

### Task 1: Rust CLIPRDR backend

**Files:**
- Create: `crates/rdpie-core/src/clipboard.rs`
- Modify: `crates/rdpie-core/src/lib.rs` (add `pub mod clipboard;` and re-exports)
- Modify: `crates/rdpie-core/Cargo.toml` (add `ironrdp-cliprdr` and `ironrdp-core` dependencies)
- Modify: `Cargo.toml` (workspace root — add both new deps to `[patch.crates-io]`)

**Interfaces:**
- Consumes: nothing from other tasks (this task is self-contained and fully unit-testable without the FFI layer or Swift).
- Produces (for Task 2):
  - `pub type RdpieClipboardCallback = unsafe extern "C" fn(context: *mut core::ffi::c_void, text: *const u8, len: usize);` — invoked with UTF-8 bytes when the remote's clipboard text should be written to `NSPasteboard`. `text`/`len` are valid only for the duration of the call, exactly like `RdpieInputEvent`'s pointer in `input.rs`.
  - `pub fn clipboard_channel(callback: RdpieClipboardCallback, context: *mut core::ffi::c_void) -> (RdpieClipboardFactory, RdpieClipboardHandle)` — mirrors `gfx::gfx_channel`'s shape.
  - `pub struct RdpieClipboardHandle` with `pub fn submit_local_text(&self, text: String)` — call whenever the Mac's pasteboard changes; caches the text and advertises it to the client (delayed rendering — no data sent yet).
  - `pub struct RdpieClipboardFactory` implementing `ironrdp_server::CliprdrServerFactory`, ready to hand to `RdpServer::builder().with_cliprdr_factory(Some(Box::new(factory)))`.

- [ ] **Step 1: Add the new dependencies**

Add to `crates/rdpie-core/Cargo.toml`'s `[dependencies]` section (alongside the existing `ironrdp-egfx = "0.3"` line):

```toml
ironrdp-cliprdr = "0.7"
ironrdp-core = "0.2"
```

Add to the workspace root `Cargo.toml`'s `[patch.crates-io]` section (alongside the existing `ironrdp-egfx`/`ironrdp-dvc` lines):

```toml
ironrdp-cliprdr = { path = "third_party/ironrdp/crates/ironrdp-cliprdr" }
ironrdp-core = { path = "third_party/ironrdp/crates/ironrdp-core" }
```

Without the `[patch.crates-io]` entries, Cargo fetches a *different* instance of these crates from crates.io than the one `ironrdp-server`/`ironrdp-egfx` use internally via their own patched paths, causing a "multiple different versions of crate `ironrdp_core`" trait-coherence build error — this exact failure mode was hit and fixed the same way when `ironrdp-pdu` was added as a direct dependency in Phase 4 (see `crates/rdpie-core/Cargo.toml` and root `Cargo.toml`'s existing `ironrdp-pdu` entries for the precedent).

- [ ] **Step 2: Run a build to confirm the dependency wiring is correct before writing any code**

Run: `cargo build -p rdpie-core 2>&1 | tail -30`
Expected: builds successfully (nothing imports the new crates yet, so this only proves the dependency/patch wiring itself is correct).

- [ ] **Step 3: Write `crates/rdpie-core/src/clipboard.rs`**

```rust
//! Bridges RDPie to the CLIPRDR clipboard channel (MS-RDPECLIP), plain text
//! only. Unlike `gfx.rs`'s EGFX integration, CLIPRDR is a plain static
//! virtual channel in `ironrdp-server`, not a dynamic one: our job is only
//! to implement `CliprdrBackend` and emit `ClipboardMessage`s through the
//! registered `ServerEvent` sender — `ironrdp-server`'s own event loop
//! performs the actual protocol calls (`initiate_copy`, `submit_format_data`,
//! `initiate_paste`) and writes to the socket itself. There is no shared
//! mutex-wrapped server handle to manage here, and no reentrancy/deadlock
//! concern to design around.

use core::ffi::c_void;
use std::sync::{Arc, Mutex};

use ironrdp_cliprdr::backend::{ClipboardMessage, ClipboardMessageProxy as _, CliprdrBackend, CliprdrBackendFactory};
use ironrdp_cliprdr::pdu::{
    ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags, FormatDataRequest, FormatDataResponse,
    LockDataId,
};
use ironrdp_core::IntoOwned as _;
use ironrdp_server::{CliprdrServerFactory, ServerEvent, ServerEventSender};
use tokio::sync::mpsc;

/// `*mut c_void` is not `Send`, but `CliprdrBackendFactory`'s `Box<dyn
/// CliprdrBackend>` requires it (the trait's own `Send` bound). Safety: this
/// pointer is never dereferenced by Rust — it is only ever handed back,
/// unchanged, to the same Swift code that produced it. Identical
/// justification to `input.rs`'s `SendableContext`, duplicated here rather
/// than shared: it is three lines, and the two modules have no other reason
/// to depend on each other.
struct SendableContext(*mut c_void);
unsafe impl Send for SendableContext {}

/// Invoked with UTF-8 text when the remote's clipboard content should be
/// written to `NSPasteboard`. `text` is valid only for the duration of the
/// call — copy it out before returning, exactly like `RdpieInputEvent` in
/// `input.rs`.
///
/// # Safety
/// `context` must remain valid for as long as the server handle is alive.
pub type RdpieClipboardCallback = unsafe extern "C" fn(context: *mut c_void, text: *const u8, len: usize);

/// State shared between the `RdpieClipboardFactory` (owned by the builder,
/// one instance per server) and every `RdpieClipboardBackend` instance
/// (`ironrdp-server` builds one fresh backend per accepted connection, via
/// `CliprdrBackendFactory::build_cliprdr_backend`) plus the
/// `RdpieClipboardHandle` the FFI layer keeps.
struct ClipboardState {
    sender: Mutex<Option<mpsc::UnboundedSender<ServerEvent>>>,
    /// The Mac's most recently observed pasteboard text. `None` until the
    /// first local copy after startup. Read by `on_request_format_list`
    /// (initial sync) and `on_format_data_request` (an actual paste).
    local_text: Mutex<Option<String>>,
    callback: RdpieClipboardCallback,
    context: SendableContext,
}

impl ClipboardState {
    fn send(&self, message: ClipboardMessage) {
        let Some(sender) = self.sender.lock().expect("clipboard sender mutex poisoned").clone() else {
            tracing::debug!("clipboard: no event sender registered yet, dropping message");
            return;
        };
        let _ = sender.send(ServerEvent::Clipboard(message));
    }

    /// Advertises the cached local text's availability to the client —
    /// delayed rendering: only the format list goes out now, the actual
    /// text is sent later, only if `on_format_data_request` fires.
    fn advertise(&self) {
        self.send(ClipboardMessage::SendInitiateCopy(vec![ClipboardFormat::new(
            ClipboardFormatId::CF_UNICODETEXT,
        )]));
    }

    fn request_paste(&self, format: ClipboardFormatId) {
        self.send(ClipboardMessage::SendInitiatePaste(format));
    }

    fn respond_with_local_text(&self) {
        let text = self
            .local_text
            .lock()
            .expect("clipboard local_text mutex poisoned")
            .clone()
            .unwrap_or_default();
        self.send(ClipboardMessage::SendFormatData(
            FormatDataResponse::new_unicode_string(&text).into_owned(),
        ));
    }

    fn invoke_callback(&self, text: &str) {
        unsafe { (self.callback)(self.context.0, text.as_ptr(), text.len()) };
    }
}

/// Consumed once by `RdpServerBuilder::with_cliprdr_factory`.
pub struct RdpieClipboardFactory {
    state: Arc<ClipboardState>,
}

/// Kept by the FFI layer to push local clipboard changes.
pub struct RdpieClipboardHandle {
    state: Arc<ClipboardState>,
}

/// Create a linked factory/handle pair.
pub fn clipboard_channel(callback: RdpieClipboardCallback, context: *mut c_void) -> (RdpieClipboardFactory, RdpieClipboardHandle) {
    let state = Arc::new(ClipboardState {
        sender: Mutex::new(None),
        local_text: Mutex::new(None),
        callback,
        context: SendableContext(context),
    });
    (RdpieClipboardFactory { state: Arc::clone(&state) }, RdpieClipboardHandle { state })
}

impl RdpieClipboardHandle {
    /// Call whenever the Mac's pasteboard changes. Caches the text and
    /// advertises it to the connected client, if any — see `ClipboardState::advertise`.
    pub fn submit_local_text(&self, text: String) {
        *self.state.local_text.lock().expect("clipboard local_text mutex poisoned") = Some(text);
        self.state.advertise();
    }
}

impl ServerEventSender for RdpieClipboardFactory {
    fn set_sender(&mut self, sender: mpsc::UnboundedSender<ServerEvent>) {
        *self.state.sender.lock().expect("clipboard sender mutex poisoned") = Some(sender);
    }
}

impl CliprdrBackendFactory for RdpieClipboardFactory {
    fn build_cliprdr_backend(&self) -> Box<dyn CliprdrBackend> {
        Box::new(RdpieClipboardBackend { state: Arc::clone(&self.state) })
    }
}

impl CliprdrServerFactory for RdpieClipboardFactory {}

/// CLIPRDR callback target. One instance per connection (a fresh one is
/// built by `RdpieClipboardFactory::build_cliprdr_backend` each time the
/// channel is (re)initialized), sharing state with the FFI-facing handle
/// via `Arc<ClipboardState>`.
struct RdpieClipboardBackend {
    state: Arc<ClipboardState>,
}

ironrdp_core::impl_as_any!(RdpieClipboardBackend);

impl core::fmt::Debug for RdpieClipboardBackend {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("RdpieClipboardBackend").finish_non_exhaustive()
    }
}

impl CliprdrBackend for RdpieClipboardBackend {
    fn temporary_directory(&self) -> &str {
        // Never read for anything real: no file capability
        // (STREAM_FILECLIP_ENABLED) is declared below.
        ""
    }

    fn client_capabilities(&self) -> ClipboardGeneralCapabilityFlags {
        // No file transfer, no locking, no long format names -- plain text
        // needs none of these.
        ClipboardGeneralCapabilityFlags::empty()
    }

    fn on_ready(&mut self) {}

    fn on_request_format_list(&mut self) {
        if self.state.local_text.lock().expect("clipboard local_text mutex poisoned").is_some() {
            self.state.advertise();
        }
    }

    fn on_process_negotiated_capabilities(&mut self, _capabilities: ClipboardGeneralCapabilityFlags) {}

    fn on_remote_copy(&mut self, available_formats: &[ClipboardFormat]) {
        let Some(text_format) = available_formats.iter().find(|f| f.id() == ClipboardFormatId::CF_UNICODETEXT) else {
            return;
        };
        self.state.request_paste(text_format.id());
    }

    fn on_format_data_request(&mut self, request: FormatDataRequest) {
        if request.format != ClipboardFormatId::CF_UNICODETEXT {
            return;
        }
        self.state.respond_with_local_text();
    }

    fn on_format_data_response(&mut self, response: FormatDataResponse<'_>) {
        if response.is_error() {
            return;
        }
        if let Ok(text) = response.to_unicode_string() {
            self.state.invoke_callback(&text);
        }
    }

    fn on_lock(&mut self, _data_id: LockDataId) {}

    fn on_unlock(&mut self, _data_id: LockDataId) {}
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex as StdMutex;

    use ironrdp_cliprdr::backend::CliprdrBackendFactory as _;

    use super::*;

    /// Test double standing in for Swift's callback: records every string
    /// it receives.
    unsafe extern "C" fn record(context: *mut c_void, text: *const u8, len: usize) {
        let log = unsafe { &*(context as *const StdMutex<Vec<String>>) };
        let bytes = unsafe { core::slice::from_raw_parts(text, len) };
        let text = String::from_utf8_lossy(bytes).into_owned();
        log.lock().expect("test callback log mutex poisoned").push(text);
    }

    fn factory_with_log() -> (RdpieClipboardFactory, RdpieClipboardHandle, Arc<StdMutex<Vec<String>>>) {
        let log = Arc::new(StdMutex::new(Vec::new()));
        let context = Arc::as_ptr(&log) as *mut c_void;
        let (factory, handle) = clipboard_channel(record, context);
        (factory, handle, log)
    }

    /// Drains every `ServerEvent::Clipboard` currently queued, panicking on
    /// any other variant (none should ever appear in this module's tests).
    fn drain_clipboard_messages(rx: &mut mpsc::UnboundedReceiver<ServerEvent>) -> Vec<ClipboardMessage> {
        let mut messages = Vec::new();
        while let Ok(event) = rx.try_recv() {
            let ServerEvent::Clipboard(message) = event else {
                panic!("expected only ServerEvent::Clipboard, got {event:?}");
            };
            messages.push(message);
        }
        messages
    }

    #[test]
    fn submitting_local_text_before_a_sender_is_registered_does_not_panic() {
        let (_factory, handle, _log) = factory_with_log();
        handle.submit_local_text("hello".to_owned());
    }

    #[test]
    fn on_request_format_list_with_no_local_text_sends_nothing() {
        let (mut factory, _handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);
        let mut backend = factory.build_cliprdr_backend();

        backend.on_request_format_list();

        assert!(drain_clipboard_messages(&mut rx).is_empty());
    }

    #[test]
    fn submitting_local_text_advertises_unicode_text() {
        let (mut factory, handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);

        handle.submit_local_text("hello from the mac".to_owned());

        let messages = drain_clipboard_messages(&mut rx);
        assert_eq!(messages.len(), 1);
        let ClipboardMessage::SendInitiateCopy(formats) = &messages[0] else {
            panic!("expected SendInitiateCopy, got {:?}", messages[0]);
        };
        assert_eq!(formats.len(), 1);
        assert_eq!(formats[0].id(), ClipboardFormatId::CF_UNICODETEXT);
    }

    #[test]
    fn on_request_format_list_after_a_local_copy_re_advertises() {
        let (mut factory, handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);
        handle.submit_local_text("already copied".to_owned());
        drain_clipboard_messages(&mut rx); // discard the advertise from submit_local_text itself

        let mut backend = factory.build_cliprdr_backend();
        backend.on_request_format_list();

        let messages = drain_clipboard_messages(&mut rx);
        assert_eq!(messages.len(), 1);
        assert!(matches!(&messages[0], ClipboardMessage::SendInitiateCopy(_)));
    }

    #[test]
    fn format_data_request_for_unicode_text_responds_with_the_cached_text() {
        let (mut factory, handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);
        handle.submit_local_text("paste me".to_owned());
        drain_clipboard_messages(&mut rx);

        let mut backend = factory.build_cliprdr_backend();
        backend.on_format_data_request(FormatDataRequest { format: ClipboardFormatId::CF_UNICODETEXT });

        let messages = drain_clipboard_messages(&mut rx);
        assert_eq!(messages.len(), 1);
        let ClipboardMessage::SendFormatData(response) = &messages[0] else {
            panic!("expected SendFormatData, got {:?}", messages[0]);
        };
        assert!(!response.is_error());
        assert_eq!(response.to_unicode_string().expect("valid unicode text"), "paste me");
    }

    #[test]
    fn format_data_request_for_a_non_text_format_is_ignored() {
        let (mut factory, handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);
        handle.submit_local_text("text".to_owned());
        drain_clipboard_messages(&mut rx);

        let mut backend = factory.build_cliprdr_backend();
        // CF_BITMAP -- a real, well-known non-text format id -- is never
        // something this backend advertises, so a request for it is a
        // client protocol edge case, not something to answer.
        backend.on_format_data_request(FormatDataRequest { format: ClipboardFormatId(2) });

        assert!(drain_clipboard_messages(&mut rx).is_empty());
    }

    #[test]
    fn format_data_request_with_no_local_text_yet_responds_with_empty_text_not_a_crash() {
        let (mut factory, _handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);

        let mut backend = factory.build_cliprdr_backend();
        backend.on_format_data_request(FormatDataRequest { format: ClipboardFormatId::CF_UNICODETEXT });

        let messages = drain_clipboard_messages(&mut rx);
        assert_eq!(messages.len(), 1);
        let ClipboardMessage::SendFormatData(response) = &messages[0] else {
            panic!("expected SendFormatData, got {:?}", messages[0]);
        };
        assert_eq!(response.to_unicode_string().expect("valid unicode text"), "");
    }

    #[test]
    fn remote_copy_with_unicode_text_requests_a_paste() {
        let (mut factory, _handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);
        let mut backend = factory.build_cliprdr_backend();

        backend.on_remote_copy(&[ClipboardFormat::new(ClipboardFormatId::CF_UNICODETEXT)]);

        let messages = drain_clipboard_messages(&mut rx);
        assert_eq!(messages.len(), 1);
        let ClipboardMessage::SendInitiatePaste(format) = &messages[0] else {
            panic!("expected SendInitiatePaste, got {:?}", messages[0]);
        };
        assert_eq!(*format, ClipboardFormatId::CF_UNICODETEXT);
    }

    #[test]
    fn remote_copy_with_only_non_text_formats_requests_nothing() {
        let (mut factory, _handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);
        let mut backend = factory.build_cliprdr_backend();

        // CF_BITMAP only -- no text format offered.
        backend.on_remote_copy(&[ClipboardFormat::new(ClipboardFormatId(2))]);

        assert!(drain_clipboard_messages(&mut rx).is_empty());
    }

    #[test]
    fn format_data_response_with_unicode_text_invokes_the_callback() {
        let (factory, _handle, log) = factory_with_log();
        let mut backend = factory.build_cliprdr_backend();

        backend.on_format_data_response(FormatDataResponse::new_unicode_string("from the remote"));

        let received = log.lock().expect("test callback log mutex poisoned");
        assert_eq!(received.as_slice(), ["from the remote"]);
    }

    #[test]
    fn format_data_response_with_an_error_flag_does_not_invoke_the_callback() {
        let (factory, _handle, log) = factory_with_log();
        let mut backend = factory.build_cliprdr_backend();

        backend.on_format_data_response(FormatDataResponse::new_error());

        assert!(log.lock().expect("test callback log mutex poisoned").is_empty());
    }
}
```

- [ ] **Step 4: Wire the new module into `crates/rdpie-core/src/lib.rs`**

Add after the existing `pub mod input;` block:

```rust
pub mod clipboard;

pub use clipboard::{RdpieClipboardCallback, RdpieClipboardFactory, RdpieClipboardHandle, clipboard_channel};
```

- [ ] **Step 5: Run the tests**

Run: `cargo test -p rdpie-core clipboard:: -- --nocapture`
Expected: all 11 new tests pass.

- [ ] **Step 6: Run the full crate test suite to confirm nothing else broke**

Run: `cargo test -p rdpie-core`
Expected: all tests pass (the pre-existing suite plus the 11 new ones).

- [ ] **Step 7: Commit**

```bash
git add crates/rdpie-core/Cargo.toml Cargo.toml crates/rdpie-core/src/lib.rs crates/rdpie-core/src/clipboard.rs
git commit -m "feat: add a CLIPRDR backend for plain-text clipboard sync"
```

---

### Task 2: FFI and server wiring

**Files:**
- Modify: `crates/rdpie-core/src/ffi.rs`
- Modify: `crates/rdpie-core/src/server.rs`

**Interfaces:**
- Consumes: `crate::clipboard::{RdpieClipboardCallback, RdpieClipboardHandle, clipboard_channel}` and `RdpieClipboardFactory` from Task 1.
- Produces (for Task 3):
  - New `RdpieConfig` fields: `clipboard_callback: Option<unsafe extern "C" fn(context: *mut c_void, text: *const u8, len: usize)>`, `clipboard_context: *mut c_void`.
  - New FFI function: `rdpie_server_submit_clipboard_text(server: *mut RdpieServer, data: *const u8, len: usize) -> i32` — returns 0 on success, -1 on a null handle/pointer.

- [ ] **Step 1: Add a `clipboard` field to `RdpieServer` and thread `RdpieClipboardHandle` through `rdpie_server_start`**

In `crates/rdpie-core/src/ffi.rs`, modify the `RdpieServer` struct (around line 14):

```rust
pub struct RdpieServer {
    pub(crate) sink: FrameSink,
    pub(crate) gfx: crate::gfx::RdpieGfxHandle,
    pub(crate) clipboard: crate::clipboard::RdpieClipboardHandle,
    pub(crate) shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    pub(crate) worker: Option<std::thread::JoinHandle<()>>,
}
```

Add two new fields to `RdpieConfig` (after the existing `input_context` field, before `bind_all`):

```rust
    /// `None` means clipboard sync is disabled for this session — Swift
    /// only omits this when it has no way to reach `NSPasteboard` at all;
    /// unlike `input_callback`, there is no permission gate on macOS for
    /// plain clipboard read/write, so real usage always registers one.
    ///
    /// Written inline, not through `RdpieClipboardCallback` the named
    /// alias, for the same `cbindgen` `Option<T>`-collapsing reason
    /// documented on `input_callback` above.
    pub clipboard_callback: Option<unsafe extern "C" fn(context: *mut c_void, text: *const u8, len: usize)>,
    /// Opaque; passed back unchanged on every `clipboard_callback`
    /// invocation. Ignored when `clipboard_callback` is `None`.
    pub clipboard_context: *mut c_void,
```

- [ ] **Step 2: Build a no-op clipboard handle for the `None` case**

Above `rdpie_server_start`, add a small helper mirroring `input_handler_from_config`:

```rust
/// A no-op callback for when Swift registered none — `submit_local_text`
/// still needs somewhere to route the advertise-only side effect even in
/// this case, so the channel is always created; only the callback differs.
unsafe extern "C" fn discard_clipboard_text(_context: *mut c_void, _text: *const u8, _len: usize) {}
```

- [ ] **Step 3: Construct the clipboard channel and factory in `rdpie_server_start`, and wire it into the returned `RdpieServer`**

In `rdpie_server_start` (around the existing `let (gfx_factory, gfx) = crate::gfx::gfx_channel(...)` line), add:

```rust
    let (clipboard_callback, clipboard_context) = match config.clipboard_callback {
        Some(callback) => (callback, config.clipboard_context),
        None => (discard_clipboard_text as RdpieClipboardCallback, core::ptr::null_mut()),
    };
    let (clipboard_factory, clipboard) = crate::clipboard::clipboard_channel(clipboard_callback, clipboard_context);
```

(add `use crate::clipboard::RdpieClipboardCallback;` to the top-of-file imports)

Update the `crate::server::run(...)` call inside the spawned thread to pass `clipboard_factory` as a new argument (signature change lands in Step 5 below):

```rust
                    result = crate::server::run(server_config, stream, gfx_factory, clipboard_factory, input_handler) => {
```

Update the final `Box::into_raw(Box::new(RdpieServer { ... }))` construction to include the new field:

```rust
    Box::into_raw(Box::new(RdpieServer {
        sink,
        gfx,
        clipboard,
        shutdown: Some(shutdown_tx),
        worker: Some(worker),
    }))
```

- [ ] **Step 4: Add the new submit function**

After `rdpie_server_submit_h264_frame` (before `rdpie_server_stop`):

```rust
/// Submit the Mac's current pasteboard text after a local copy. Never
/// blocks. The text is only *advertised* to the client immediately
/// (delayed rendering) — the actual bytes are sent later, only if the
/// client pastes.
///
/// Returns 0 on success, -1 on a null handle/pointer or invalid UTF-8.
///
/// # Safety
///
/// `server` must be a handle from `rdpie_server_start` that has not been
/// stopped. `data` must point to at least `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rdpie_server_submit_clipboard_text(
    server: *mut RdpieServer,
    data: *const u8,
    len: usize,
) -> i32 {
    if server.is_null() || data.is_null() {
        return -1;
    }
    let server = unsafe { &*server };
    let bytes = unsafe { core::slice::from_raw_parts(data, len) };
    let Ok(text) = core::str::from_utf8(bytes) else {
        return -1;
    };
    server.clipboard.submit_local_text(text.to_owned());
    0
}
```

- [ ] **Step 5: Update `crate::server::run`'s signature to accept the clipboard factory**

In `crates/rdpie-core/src/server.rs`, update the `use` block to add:

```rust
use crate::clipboard::RdpieClipboardFactory;
```

Update `run`'s signature (currently `pub async fn run(config: ServerConfig, frames: FrameStream, gfx_factory: RdpieGfxFactory, input_handler: Option<RdpieInputHandler>) -> Result<()>`) to:

```rust
pub async fn run(
    config: ServerConfig,
    frames: FrameStream,
    gfx_factory: RdpieGfxFactory,
    clipboard_factory: RdpieClipboardFactory,
    input_handler: Option<RdpieInputHandler>,
) -> Result<()> {
```

Add `.with_cliprdr_factory(Some(Box::new(clipboard_factory)))` to the builder chain, next to the existing `.with_gfx_factory(...)` call:

```rust
    let mut server = builder
        .with_display_handler(display)
        .with_gfx_factory(Some(Box::new(gfx_factory)))
        .with_cliprdr_factory(Some(Box::new(clipboard_factory)))
        .build();
```

Extend `run`'s doc comment with a new paragraph:

```rust
/// Phase 5 adds `clipboard_factory`: always registered (unlike
/// `input_handler`, clipboard sync has no permission gate on macOS worth
/// modeling as an `Option` here) — `.with_cliprdr_factory(...)` makes the
/// server support CLIPRDR whenever the connecting client opens that
/// channel, exactly like EGFX only activates when a client negotiates it.
```

- [ ] **Step 6: Update `crates/rdpie-core/tests/connect.rs`'s call sites**

This integration test calls `rdpie_core::server::run` directly (not through the FFI), twice — once per test. Add `use rdpie_core::clipboard::clipboard_channel;` to the top-of-file imports, and a throwaway no-op callback right after `solid_frame`:

```rust
unsafe extern "C" fn noop_clipboard_callback(_context: *mut core::ffi::c_void, _text: *const u8, _len: usize) {}
```

In `server_stays_up_and_accepts_a_connection`, add a clipboard channel next to the existing `let (gfx_factory, gfx) = gfx_channel(640, 480);` line:

```rust
    let (clipboard_factory, _clipboard) = clipboard_channel(noop_clipboard_callback, core::ptr::null_mut());
```

and update the `run(...)` call to pass it:

```rust
                tokio::task::spawn_local(async move { run(config, stream, gfx_factory, clipboard_factory, None).await });
```

In `a_missing_tls_identity_is_reported_not_panicked`, add the same channel construction next to its own `let (gfx_factory, _gfx) = gfx_channel(640, 480);` line, and update its `run(...)` call the same way:

```rust
    let error = run(config, stream, gfx_factory, clipboard_factory, None)
        .await
        .expect_err("a missing identity must be an error");
```

- [ ] **Step 7: Update every other `RdpieConfig { ... }` struct literal in `ffi.rs`'s own tests**

Run: `grep -n "RdpieConfig {" crates/rdpie-core/src/ffi.rs`

Add `clipboard_callback: None, clipboard_context: core::ptr::null_mut(),` to each (the existing `null_input_callback_yields_no_handler`, `a_registered_callback_is_reachable_through_the_constructed_handler`, and `starting_with_a_null_input_callback_still_succeeds_view_only` tests).

Also update every `RdpieServer { sink, gfx, shutdown: None, worker: None }` test construction in `ffi.rs` to include a `clipboard` field, by adding a `let (_clipboard_factory, clipboard) = crate::clipboard::clipboard_channel(discard_clipboard_text, core::ptr::null_mut());` line before each and adding `clipboard` to the struct literal. This exact pattern appears in eight tests — `submitting_a_null_buffer_is_an_error_not_a_crash`, `submitting_a_short_buffer_is_an_error_not_a_crash`, `a_valid_frame_is_accepted`, `gfx_active_before_a_client_negotiates_is_false`, `submitting_a_null_h264_buffer_is_an_error_not_a_crash`, `submitting_an_empty_h264_buffer_is_an_error_not_a_crash`, `submitting_an_inverted_region_is_an_error_not_a_crash`, and `submitting_h264_before_the_client_negotiates_egfx_is_rejected_not_a_crash` — update all eight. For example, `submitting_a_null_buffer_is_an_error_not_a_crash` currently reads:

```rust
    fn submitting_a_null_buffer_is_an_error_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let mut server = RdpieServer { sink, gfx, shutdown: None, worker: None };
```

and becomes:

```rust
    fn submitting_a_null_buffer_is_an_error_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let (_clipboard_factory, clipboard) = crate::clipboard::clipboard_channel(discard_clipboard_text, core::ptr::null_mut());
        let mut server = RdpieServer { sink, gfx, clipboard, shutdown: None, worker: None };
```

Apply the same two-line change (insert the `clipboard_channel` construction, add `clipboard` to the struct literal) to the other seven tests listed above.

- [ ] **Step 8: Add a test for the new submit function**

In `ffi.rs`'s `#[cfg(test)] mod tests`, add:

```rust
    #[test]
    fn submitting_clipboard_text_to_a_null_server_is_an_error_not_a_crash() {
        let data = b"hello";
        let rc = unsafe { rdpie_server_submit_clipboard_text(core::ptr::null_mut(), data.as_ptr(), data.len()) };
        assert_eq!(rc, -1);
    }

    #[test]
    fn submitting_a_null_clipboard_buffer_is_an_error_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_gfx_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let (_clipboard_factory, clipboard) = crate::clipboard::clipboard_channel(discard_clipboard_text, core::ptr::null_mut());
        let mut server = RdpieServer { sink, gfx, clipboard, shutdown: None, worker: None };
        let rc = unsafe { rdpie_server_submit_clipboard_text(&mut server as *mut _, core::ptr::null(), 5) };
        assert_eq!(rc, -1);
    }

    #[test]
    fn valid_clipboard_text_is_accepted() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_gfx_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let (_clipboard_factory, clipboard) = crate::clipboard::clipboard_channel(discard_clipboard_text, core::ptr::null_mut());
        let mut server = RdpieServer { sink, gfx, clipboard, shutdown: None, worker: None };
        let data = b"copied text";
        let rc = unsafe { rdpie_server_submit_clipboard_text(&mut server as *mut _, data.as_ptr(), data.len()) };
        assert_eq!(rc, 0);
    }
```

- [ ] **Step 9: Regenerate the C header and run the full test suite**

Run: `just build`
Expected: clean build; `macos/Sources/CRdpieCore/include/rdpie_core.h` now declares `clipboard_callback`/`clipboard_context` fields on `RdpieConfig` and the new `rdpie_server_submit_clipboard_text` function, both with plain (non-wrapped) function-pointer/pointer types — confirm by reading the regenerated header.

Run: `cargo test -p rdpie-core`
Expected: all tests pass.

- [ ] **Step 10: Commit**

```bash
git add crates/rdpie-core/src/ffi.rs crates/rdpie-core/src/server.rs crates/rdpie-core/tests/connect.rs macos/Sources/CRdpieCore/include/rdpie_core.h
git commit -m "feat: wire the CLIPRDR backend into the FFI layer and server builder"
```

---

### Task 3: Swift side — NSPasteboard integration

**Files:**
- Modify: `macos/Sources/rdpied/RustBridge.swift`
- Modify: `macos/Sources/rdpied/main.swift`

**Interfaces:**
- Consumes: `rdpie_server_submit_clipboard_text` and `RdpieConfig.clipboard_callback`/`.clipboard_context` from Task 2's regenerated header.
- Produces: nothing further downstream — this is the last task before docs.

- [ ] **Step 1: Add the remote-copy callback and registration to `RustBridge.swift`**

Add near the top of the file, alongside the existing `rdpieHandleInputEvent` function:

```swift
/// Same object-identity-via-context trick as `rdpieHandleInputEvent` — see
/// its doc comment for why `passUnretained` is correct here too.
///
/// `text`/`len` are valid only for the duration of this call (per the FFI
/// contract) — build the `String` before returning, don't retain the
/// pointer.
private func rdpieHandleClipboardText(_ context: UnsafeMutableRawPointer?, _ text: UnsafePointer<UInt8>?, _ len: Int) {
    guard let context, let text else { return }
    let bridge = Unmanaged<RustBridge>.fromOpaque(context).takeUnretainedValue()
    let data = Data(bytes: text, count: len)
    guard let string = String(data: data, encoding: .utf8) else { return }
    bridge.writeRemoteClipboardText(string)
}
```

Add a new stored property and method to the `RustBridge` class, alongside `inputInjector`:

```swift
    /// Set right after `writeRemoteClipboardText` writes remote-sourced
    /// text to the pasteboard, to the `changeCount` that write produced.
    /// `main.swift`'s poll loop compares against this so it never mistakes
    /// our own write for a new local copy and bounces it straight back to
    /// the remote (an echo loop).
    private(set) var lastKnownClipboardChangeCount = NSPasteboard.general.changeCount

    private func writeRemoteClipboardText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastKnownClipboardChangeCount = pasteboard.changeCount
    }
```

(add `import AppKit` at the top of the file — `NSPasteboard` lives there, not in `Foundation`)

Update the `RdpieConfig(...)` construction inside `start(...)` to register the new callback:

```swift
                        var config = RdpieConfig(
                            port: port,
                            width: UInt16(width),
                            height: UInt16(height),
                            username: user,
                            password: pass,
                            cert_pem_path: cert,
                            key_pem_path: key,
                            input_callback: rdpieHandleInputEvent,
                            input_context: Unmanaged.passUnretained(self).toOpaque(),
                            clipboard_callback: rdpieHandleClipboardText,
                            clipboard_context: Unmanaged.passUnretained(self).toOpaque(),
                            bind_all: bindAll
                        )
```

- [ ] **Step 2: Add a submit method to `RustBridge`**

Alongside `submitH264`:

```swift
    /// Called whenever `main.swift`'s poll loop notices the pasteboard
    /// changed. Advertises the new text to the client (delayed rendering
    /// — see `rdpie_server_submit_clipboard_text`'s doc comment); the
    /// actual bytes only cross the wire later, if the client pastes.
    func submitClipboardText(_ text: String) {
        guard let handle else { return }
        let data = Data(text.utf8)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            _ = rdpie_server_submit_clipboard_text(handle, base, UInt(buffer.count))
        }
    }
```

- [ ] **Step 3: Poll `NSPasteboard` inside `main.swift`'s existing capture loop**

Add `import AppKit` to `main.swift`'s imports.

Add a new tracked variable alongside the existing `var wasGfxActive = false` / `var needsKeyframe = false`:

```swift
// Local pasteboard polling: AppKit has no clipboard-change notification,
// only a monotonically increasing changeCount to compare against. Reusing
// this loop (already running ~30x/sec while a client is connected) avoids
// a second timer for what is otherwise a single cheap integer comparison
// per iteration.
var lastPolledClipboardChangeCount = NSPasteboard.general.changeCount
```

Inside the `for await frame in source.frames { ... }` loop, add (right after the existing Accessibility-check block, before the `gfxActive` handling):

```swift
    let pasteboard = NSPasteboard.general
    if pasteboard.changeCount != lastPolledClipboardChangeCount {
        lastPolledClipboardChangeCount = pasteboard.changeCount
        // Skip re-advertising a change this process itself just wrote —
        // see RustBridge.writeRemoteClipboardText's doc comment.
        if pasteboard.changeCount != bridge.lastKnownClipboardChangeCount, let text = pasteboard.string(forType: .string) {
            bridge.submitClipboardText(text)
        }
    }
```

- [ ] **Step 4: Build and run the full test suite**

Run: `just build`
Expected: clean build.

Run: `cargo test -p rdpie-core && swift test --package-path macos`
Expected: all tests pass (this task adds no new automated tests of its own — `NSPasteboard`/AppKit integration isn't unit-testable without a live session, matching how `ScreenCaptureKitSource`'s own live-capture path has no unit test either; Task 1's Rust-side tests already cover the actual clipboard protocol logic in isolation).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/rdpied/RustBridge.swift macos/Sources/rdpied/main.swift
git commit -m "feat: sync the Mac's pasteboard with the RDP client's clipboard"
```

---

### Task 4: Documentation and live verification

**Files:**
- Create: `docs/running-phase-5.md`

**Interfaces:**
- Consumes: the fully working feature from Tasks 1-3.
- Produces: nothing — this is the last task in the plan.

- [ ] **Step 1: Write `docs/running-phase-5.md`**

```markdown
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

\`\`\`sh
just build
\`\`\`

## Run

\`\`\`sh
RDPIE_PASSWORD=<password> RDPIE_USERNAME=<username> just run
\`\`\`

## Verification checklist for a live pass

- [ ] Connect with a real RDP client that has clipboard redirection enabled
      (mstsc: Show Options → Local Resources → Clipboard, checked).
- [ ] Copy text on the Mac, paste it on the remote client. Confirm it
      arrives correctly.
- [ ] Copy text on the remote client, paste it on the Mac. Confirm it
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
```

- [ ] **Step 2: Commit**

```bash
git add docs/running-phase-5.md
git commit -m "docs: add Phase 5 (clipboard) verification checklist"
```

## Exit Criteria

- All automated tests pass: `cargo test -p rdpie-core` and `swift test --package-path macos`.
- `just build` produces a clean build with the regenerated header showing plain (non-wrapped) types for the new `RdpieConfig` fields and `rdpie_server_submit_clipboard_text`.
- Live verification checklist in `docs/running-phase-5.md` completed against at least one real RDP client.

## What Phase 6 Inherits

- A working CLIPRDR backend pattern (`clipboard.rs`) that Phase 6 (dynamic resize) does not need to touch — Display Control is a separate channel.
- No new server-side configuration surface beyond the two new `RdpieConfig` fields — clipboard sync needs no toggle, matching how future phases should default to "on whenever the client asks for it" unless a concrete reason emerges to gate something.
