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
    /// Forces every modifier key (Control, Shift, Command, Option, both
    /// sides) up on the Mac, regardless of what this handler thinks their
    /// state is. Emitted on `KeyboardEvent::Synchronize` -- the client's
    /// signal that keyboard focus returned to the RDP session, which is
    /// also the only moment a held-but-never-released modifier (the client
    /// OS ate the key-up because focus left the RDP window while it was
    /// down) can be noticed and corrected. Posting a key-up for a modifier
    /// that was never actually down is a no-op, so this is safe to fire on
    /// every resync rather than only when something is actually stuck.
    ReleaseAllModifiers = 14,
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
            // Synchronize carries lock-key state (NumLock/CapsLock/
            // ScrollLock), which stays out of scope for Phase 3 -- but the
            // event itself is also the client's "focus returned" signal,
            // which this handler repurposes to clear any modifier stuck
            // down by an unbalanced press/release pair. See
            // RdpieInputEventKind::ReleaseAllModifiers.
            KeyboardEvent::Synchronize(_) => RdpieInputEvent {
                kind: RdpieInputEventKind::ReleaseAllModifiers,
                scancode: 0,
                extended: false,
                x: 0,
                y: 0,
                scroll_delta: 0,
            },
            // Out of scope for Phase 3 — see the plan's Scope section. Logged,
            // not silently dropped: a wildcard here would also swallow any
            // future variant upstream adds without anyone noticing.
            KeyboardEvent::UnicodePressed(_) | KeyboardEvent::UnicodeReleased(_) => {
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

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

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

    #[test]
    fn a_synchronize_event_translates_to_release_all_modifiers() {
        let (mut handler, log) = handler_with_log();
        handler.keyboard(KeyboardEvent::Synchronize(
            ironrdp_pdu::input::fast_path::SynchronizeFlags::empty(),
        ));

        let events = log.lock().expect("test event log mutex poisoned");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, RdpieInputEventKind::ReleaseAllModifiers);
    }
}
