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

use ironrdp_cliprdr::backend::{ClipboardMessage, CliprdrBackend, CliprdrBackendFactory};
use ironrdp_cliprdr::pdu::{
    ClipboardFormat, ClipboardFormatId, ClipboardGeneralCapabilityFlags, FileContentsRequest, FileContentsResponse,
    FormatDataRequest, FormatDataResponse, LockDataId,
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
unsafe impl Sync for SendableContext {}

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

    // `on_request_format_list` fires when the CLIENT role receives a Monitor
    // Ready PDU -- we're the server, and it's the server that sends Monitor
    // Ready, so that hook never fires here. The server-side equivalent is
    // `on_ready`, invoked once the client's own Format List PDU has been
    // processed during channel initialization (see ironrdp-cliprdr's
    // `handle_format_list`). Route both to the same advertise-if-cached
    // logic: `on_request_format_list` is still a required trait method and
    // stays harmless if a client ever exercises it directly.
    fn on_ready(&mut self) {
        self.on_request_format_list();
    }

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
            // MS-RDPECLIP 3.1.5.2.3 requires a Format Data Response for
            // every request, even a failing one -- a conforming client only
            // ever asks for CF_UNICODETEXT (the only format we advertise),
            // but a client that asks for anything else must not be left
            // waiting on a response that never comes.
            self.state.send(ClipboardMessage::SendFormatData(FormatDataResponse::new_error()));
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

    fn on_file_contents_request(&mut self, _request: FileContentsRequest) {}

    fn on_file_contents_response(&mut self, _response: FileContentsResponse<'_>) {}
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex as StdMutex;

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
    fn on_ready_with_no_local_text_sends_nothing() {
        let (mut factory, _handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);
        let mut backend = factory.build_cliprdr_backend();

        backend.on_ready();

        assert!(drain_clipboard_messages(&mut rx).is_empty());
    }

    #[test]
    fn on_ready_after_a_local_copy_advertises() {
        // This is the server-side initial-sync hook: `on_request_format_list`
        // only fires for the client role (see its doc comment on the trait
        // impl above), so `on_ready` is what must pick up a pre-connection
        // copy and offer it once the channel finishes initializing.
        let (mut factory, handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);
        handle.submit_local_text("copied before the client connected".to_owned());
        drain_clipboard_messages(&mut rx); // discard the advertise from submit_local_text itself

        let mut backend = factory.build_cliprdr_backend();
        backend.on_ready();

        let messages = drain_clipboard_messages(&mut rx);
        assert_eq!(messages.len(), 1);
        assert!(matches!(&messages[0], ClipboardMessage::SendInitiateCopy(_)));
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
    fn format_data_request_for_a_non_text_format_gets_an_error_response() {
        let (mut factory, handle, _log) = factory_with_log();
        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);
        handle.submit_local_text("text".to_owned());
        drain_clipboard_messages(&mut rx);

        let mut backend = factory.build_cliprdr_backend();
        // CF_BITMAP -- a real, well-known non-text format id -- is never
        // something this backend advertises, so a request for it is a
        // client protocol edge case -- but MS-RDPECLIP still requires a
        // response, or the client's paste hangs waiting for one.
        backend.on_format_data_request(FormatDataRequest { format: ClipboardFormatId(2) });

        let messages = drain_clipboard_messages(&mut rx);
        assert_eq!(messages.len(), 1);
        let ClipboardMessage::SendFormatData(response) = &messages[0] else {
            panic!("expected SendFormatData, got {:?}", messages[0]);
        };
        assert!(response.is_error());
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
