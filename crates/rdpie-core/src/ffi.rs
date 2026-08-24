//! C ABI consumed by the Swift daemon. This is the only module with `unsafe`.

use core::ffi::{CStr, c_char};

use crate::frame::{Frame, FrameSink, SubmitOutcome};

/// Opaque handle returned to Swift.
///
/// `RdpServer::run()`'s future is not `Send` — upstream holds an
/// `Rc<tokio::sync::Mutex<&mut RdpServer>>` across awaits — so it cannot be
/// handed to `Runtime::spawn`. Instead a dedicated thread owns the runtime and
/// drives the server with `block_on`, which carries no `Send` bound.
pub struct RdpieServer {
    pub(crate) sink: FrameSink,
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

    let server_config = crate::server::ServerConfig::loopback(
        config.port,
        crate::DesktopSize { width: config.width, height: config.height },
        username,
        password,
        cert.into(),
        key.into(),
    );

    let (sink, stream) = crate::frame::channel(3);
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
                    result = crate::server::run(server_config, stream) => {
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
        let mut server = RdpieServer { sink, shutdown: None, worker: None };
        let rc = unsafe {
            rdpie_server_submit_frame(&mut server as *mut _, 2, 2, 8, core::ptr::null(), 16)
        };
        assert_eq!(rc, -1);
    }

    #[test]
    fn submitting_a_short_buffer_is_an_error_not_a_crash() {
        let (sink, _stream) = crate::frame::channel(2);
        let mut server = RdpieServer { sink, shutdown: None, worker: None };
        let data = [0u8; 4]; // claims 2x2 stride 8 == 16 bytes, supplies 4
        let rc = unsafe {
            rdpie_server_submit_frame(&mut server as *mut _, 2, 2, 8, data.as_ptr(), data.len())
        };
        assert_eq!(rc, -1);
    }

    #[test]
    fn a_valid_frame_is_accepted() {
        let (sink, _stream) = crate::frame::channel(2);
        let mut server = RdpieServer { sink, shutdown: None, worker: None };
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
}
