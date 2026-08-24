//! C ABI consumed by the Swift daemon. This is the only module with `unsafe`.

use core::ffi::{CStr, c_char, c_void};

use crate::frame::{Frame, FrameSink, SubmitOutcome};
use crate::input::{RdpieInputEvent, RdpieInputHandler};

/// Opaque handle returned to Swift.
///
/// `RdpServer::run()`'s future is not `Send` — upstream holds an
/// `Rc<tokio::sync::Mutex<&mut RdpServer>>` across awaits — so it cannot be
/// handed to `Runtime::spawn`. Instead a dedicated thread owns the runtime and
/// drives the server with `block_on`, which carries no `Send` bound.
pub struct RdpieServer {
    pub(crate) sink: FrameSink,
    pub(crate) gfx: crate::gfx::RdpieGfxHandle,
    pub(crate) shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    pub(crate) worker: Option<std::thread::JoinHandle<()>>,
}

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
    /// See `ServerConfig::new`. `false` unless the caller has deliberately
    /// opted in — matches spec section 8.5's loopback-by-default mandate.
    pub bind_all: bool,
}

/// Builds the input handler `rdpie_server_start` threads into
/// `crate::server::run`, or `None` when Swift registered no callback (a
/// view-only session — `crate::server::run` falls back to
/// `.with_no_input()` in that case, same as every prior phase).
fn input_handler_from_config(config: &RdpieConfig) -> Option<RdpieInputHandler> {
    config.input_callback.map(|callback| RdpieInputHandler::new(callback, config.input_context))
}

/// # Safety
///
/// `ptr` must be null or a valid NUL-terminated C string.
unsafe fn owned_string(ptr: *const c_char, field: &str) -> Option<String> {
    if ptr.is_null() {
        tracing::error!(field, "null string in RdpieConfig");
        return None;
    }
    match unsafe { CStr::from_ptr(ptr) }.to_str() {
        Ok(s) => Some(s.to_owned()),
        Err(_) => {
            tracing::error!(field, "non-UTF-8 string in RdpieConfig");
            None
        }
    }
}

/// Start the RDP listener on a dedicated runtime.
///
/// Returns a handle, or null if configuration was invalid. The caller owns the
/// handle and must release it with `rdpie_server_stop`.
///
/// # Safety
///
/// `config` must point to a valid `RdpieConfig` whose string fields are either
/// null or valid NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rdpie_server_start(config: *const RdpieConfig) -> *mut RdpieServer {
    // Best-effort: nothing in this crate ever installed a subscriber, so
    // every `tracing::error!`/`info!` call up to this point went nowhere.
    // Ignore the error since a second `rdpie_server_start` call after a
    // `rdpie_server_stop` must not panic on re-init.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .try_init();

    if config.is_null() {
        return core::ptr::null_mut();
    }
    let config = unsafe { &*config };

    let (Some(username), Some(password), Some(cert), Some(key)) = (
        unsafe { owned_string(config.username, "username") },
        unsafe { owned_string(config.password, "password") },
        unsafe { owned_string(config.cert_pem_path, "cert_pem_path") },
        unsafe { owned_string(config.key_pem_path, "key_pem_path") },
    ) else {
        return core::ptr::null_mut();
    };

    let server_config = crate::server::ServerConfig::new(
        config.port,
        config.bind_all,
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

    let worker = match worker {
        Ok(handle) => handle,
        Err(error) => {
            tracing::error!(%error, "could not spawn the server thread");
            return core::ptr::null_mut();
        }
    };

    Box::into_raw(Box::new(RdpieServer {
        sink,
        gfx,
        shutdown: Some(shutdown_tx),
        worker: Some(worker),
    }))
}

/// Submit one BGRA8888 frame. Never blocks.
///
/// Returns 0 accepted, 1 accepted after dropping the oldest queued frame,
/// -1 on a closed session or invalid arguments.
///
/// # Safety
///
/// `server` must be a handle from `rdpie_server_start` that has not been
/// stopped. `data` must point to at least `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rdpie_server_submit_frame(
    server: *mut RdpieServer,
    width: u16,
    height: u16,
    stride: usize,
    data: *const u8,
    len: usize,
) -> i32 {
    if server.is_null() || data.is_null() || width == 0 || height == 0 || stride == 0 {
        return -1;
    }
    let Some(required) = stride.checked_mul(usize::from(height)) else {
        return -1;
    };
    if len < required {
        return -1;
    }
    let server = unsafe { &*server };
    let bytes = unsafe { core::slice::from_raw_parts(data, required) }.to_vec();
    match server.sink.submit(Frame { width, height, stride, data: bytes }) {
        SubmitOutcome::Accepted => 0,
        SubmitOutcome::DroppedOldest => 1,
        SubmitOutcome::Closed => -1,
    }
}

/// Whether the connected client has finished EGFX/AVC420 capability
/// negotiation. Swift should submit H.264 via
/// `rdpie_server_submit_h264_frame` once this returns `true`, and fall back
/// to raw BGRA via `rdpie_server_submit_frame` otherwise — the two paths
/// coexist; this never disables the raw path.
///
/// Returns `false` for a null handle.
///
/// # Safety
///
/// `server` must be a handle from `rdpie_server_start` that has not been
/// stopped, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rdpie_server_gfx_active(server: *const RdpieServer) -> bool {
    if server.is_null() {
        return false;
    }
    let server = unsafe { &*server };
    server.gfx.is_ready()
}

/// Submit one AVC420-encoded H.264 frame covering a single full-frame
/// region (`region_left`/`region_top`/`region_right`/`region_bottom` are
/// inclusive edges, matching MS-RDPEGFX). `data` must already be Annex-B
/// formatted (start-code-prefixed NAL units) — VideoToolbox's AVCC output
/// needs converting to Annex-B before calling this, which happens on the
/// Swift side, not here.
///
/// Returns 0 on success, -1 on invalid arguments or a rejected frame
/// (channel not negotiated yet, backpressure, or an encoding failure).
/// Multi-region submission is not supported in this phase.
///
/// # Safety
///
/// `server` must be a handle from `rdpie_server_start` that has not been
/// stopped. `data` must point to at least `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rdpie_server_submit_h264_frame(
    server: *mut RdpieServer,
    data: *const u8,
    len: usize,
    region_left: u16,
    region_top: u16,
    region_right: u16,
    region_bottom: u16,
    quantization_parameter: u8,
    timestamp_ms: u32,
) -> i32 {
    if server.is_null() || data.is_null() || len == 0 {
        return -1;
    }
    if region_right < region_left || region_bottom < region_top || quantization_parameter > 51 {
        return -1;
    }
    let server = unsafe { &*server };
    let (width, height) = server.gfx.size();
    // Inclusive edges: a region reaching all the way to the far edge equals
    // width/height, so `>=` is out of bounds. See commit 705b8d4.
    if region_right >= width || region_bottom >= height {
        return -1;
    }
    let bytes = unsafe { core::slice::from_raw_parts(data, len) };
    let region = ironrdp_egfx::pdu::Avc420Region::new(
        region_left,
        region_top,
        region_right,
        region_bottom,
        quantization_parameter,
        100, // quality: not exposed over FFI in this phase; 100 matches Avc420Region::full_frame's default
    );
    if server.gfx.submit_avc420_frame(bytes, core::slice::from_ref(&region), timestamp_ms) {
        0
    } else {
        -1
    }
}

/// Stop the server and release the handle. Safe to call with null.
///
/// # Safety
///
/// `server` must be a handle from `rdpie_server_start`, and must not be used
/// again afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rdpie_server_stop(server: *mut RdpieServer) {
    if server.is_null() {
        return;
    }
    let mut server = unsafe { Box::from_raw(server) };
    // Signal first so the worker's `select!` wakes, then wait for it to unwind.
    if let Some(shutdown) = server.shutdown.take() {
        let _ = shutdown.send(());
    }
    if let Some(worker) = server.worker.take()
        && worker.join().is_err()
    {
        tracing::error!("the RDPie server thread panicked");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn submitting_to_a_null_server_is_an_error_not_a_crash() {
        let data = [0u8; 16];
        let rc = unsafe {
            rdpie_server_submit_frame(core::ptr::null_mut(), 2, 2, 8, data.as_ptr(), data.len())
        };
        assert_eq!(rc, -1);
    }

    #[test]
    fn submitting_a_null_buffer_is_an_error_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let mut server = RdpieServer { sink, gfx, shutdown: None, worker: None };
        let rc = unsafe {
            rdpie_server_submit_frame(&mut server as *mut _, 2, 2, 8, core::ptr::null(), 16)
        };
        assert_eq!(rc, -1);
    }

    #[test]
    fn submitting_a_short_buffer_is_an_error_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let mut server = RdpieServer { sink, gfx, shutdown: None, worker: None };
        let data = [0u8; 4]; // claims 2x2 stride 8 == 16 bytes, supplies 4
        let rc = unsafe {
            rdpie_server_submit_frame(&mut server as *mut _, 2, 2, 8, data.as_ptr(), data.len())
        };
        assert_eq!(rc, -1);
    }

    #[test]
    fn a_valid_frame_is_accepted() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let mut server = RdpieServer { sink, gfx, shutdown: None, worker: None };
        let data = [0u8; 16];
        let rc = unsafe {
            rdpie_server_submit_frame(&mut server as *mut _, 2, 2, 8, data.as_ptr(), data.len())
        };
        assert_eq!(rc, 0);
    }

    #[test]
    fn stopping_a_null_server_is_a_no_op() {
        unsafe { rdpie_server_stop(core::ptr::null_mut()) };
    }

    #[test]
    fn gfx_active_on_a_null_server_is_false_not_a_crash() {
        assert!(!unsafe { rdpie_server_gfx_active(core::ptr::null()) });
    }

    #[test]
    fn gfx_active_before_a_client_negotiates_is_false() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let server = RdpieServer { sink, gfx, shutdown: None, worker: None };
        assert!(!unsafe { rdpie_server_gfx_active(&server as *const _) });
    }

    #[test]
    fn submitting_h264_to_a_null_server_is_an_error_not_a_crash() {
        let data = [0u8; 4];
        let rc = unsafe {
            rdpie_server_submit_h264_frame(
                core::ptr::null_mut(), data.as_ptr(), data.len(), 0, 0, 1, 1, 26, 0,
            )
        };
        assert_eq!(rc, -1);
    }

    #[test]
    fn submitting_a_null_h264_buffer_is_an_error_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let mut server = RdpieServer { sink, gfx, shutdown: None, worker: None };
        let rc = unsafe {
            rdpie_server_submit_h264_frame(
                &mut server as *mut _, core::ptr::null(), 4, 0, 0, 1, 1, 26, 0,
            )
        };
        assert_eq!(rc, -1);
    }

    #[test]
    fn submitting_an_empty_h264_buffer_is_an_error_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let mut server = RdpieServer { sink, gfx, shutdown: None, worker: None };
        let data = [0u8; 1];
        let rc = unsafe {
            rdpie_server_submit_h264_frame(
                &mut server as *mut _, data.as_ptr(), 0, 0, 0, 1, 1, 26, 0,
            )
        };
        assert_eq!(rc, -1);
    }

    #[test]
    fn submitting_an_inverted_region_is_an_error_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let mut server = RdpieServer { sink, gfx, shutdown: None, worker: None };
        let data = [0u8; 4];
        // right < left is nonsensical and must be rejected before it reaches the encoder.
        let rc = unsafe {
            rdpie_server_submit_h264_frame(
                &mut server as *mut _, data.as_ptr(), data.len(), 5, 0, 1, 1, 26, 0,
            )
        };
        assert_eq!(rc, -1);
    }

    #[test]
    fn submitting_h264_before_the_client_negotiates_egfx_is_rejected_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let (_factory, gfx) = crate::gfx::gfx_channel(2, 2);
        let mut server = RdpieServer { sink, gfx, shutdown: None, worker: None };
        let data = [0u8; 4];
        let rc = unsafe {
            rdpie_server_submit_h264_frame(
                &mut server as *mut _, data.as_ptr(), data.len(), 0, 0, 1, 1, 26, 0,
            )
        };
        assert_eq!(rc, -1); // RdpieGfxHandle::submit_avc420_frame returns false: not ready yet
    }

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
            bind_all: false,
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
            bind_all: false,
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
            bind_all: false,
        };

        let server = unsafe { rdpie_server_start(&config as *const RdpieConfig) };
        assert!(!server.is_null(), "a null input_callback must still start a view-only server, not fail");
        unsafe { rdpie_server_stop(server) };
    }
}
