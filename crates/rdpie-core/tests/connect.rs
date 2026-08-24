//! End-to-end: a server fed by synthetic frames accepts a TCP connection and
//! stays up. No display, no Mac, no Apple framework involved — this is the
//! test that proves the Linux CI story in spec section 7.

use std::net::TcpListener;
use std::path::PathBuf;
use std::time::Duration;

use ironrdp_server::DesktopSize;
use rdpie_core::frame::{Frame, channel};
use rdpie_core::server::{ServerConfig, run};

/// Write a throwaway self-signed identity into a temp dir.
///
/// Generated per-run rather than committed: no private key belongs in the
/// repository, not even a test one.
fn test_identity(dir: &std::path::Path) -> (PathBuf, PathBuf) {
    let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
        .expect("generating a self-signed certificate");
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");
    std::fs::write(&cert_path, cert.cert.pem()).expect("writing cert.pem");
    std::fs::write(&key_path, cert.signing_key.serialize_pem()).expect("writing key.pem");
    (cert_path, key_path)
}

/// Ask the OS for a free port, then release it.
///
/// Mildly racy, but far cheaper than threading a bound-address channel back
/// out of the server for a test-only need.
fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("binding an ephemeral port")
        .local_addr()
        .expect("reading the ephemeral port")
        .port()
}

fn solid_frame(width: u16, height: u16, value: u8) -> Frame {
    let stride = usize::from(width) * 4;
    Frame { width, height, stride, data: vec![value; stride * usize::from(height)] }
}

#[tokio::test]
async fn server_stays_up_and_accepts_a_connection() {
    let dir = tempfile::tempdir().expect("temp dir");
    let (cert, key) = test_identity(dir.path());
    let (sink, stream) = channel(3);
    let port = free_port();

    let config = ServerConfig::loopback(
        port,
        DesktopSize { width: 640, height: 480 },
        "rdpie".to_owned(),
        "hunter2".to_owned(),
        cert,
        key,
    );

    // `run`'s future is not `Send` (upstream holds an Rc across awaits), so it
    // cannot go to `tokio::spawn`. A LocalSet keeps it pinned to this thread —
    // the same constraint the FFI works around with a dedicated thread.
    let local = tokio::task::LocalSet::new();
    local
        .run_until(async move {
            let server = tokio::task::spawn_local(async move { run(config, stream).await });

            // Feed frames so the session has something to send once connected.
            let feeder = tokio::task::spawn_local(async move {
                for i in 0..60u8 {
                    if sink.submit(solid_frame(640, 480, i)) == rdpie_core::SubmitOutcome::Closed {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(16)).await;
                }
            });

            // Give the listener a moment to bind.
            tokio::time::sleep(Duration::from_millis(500)).await;
            assert!(!server.is_finished(), "the server exited during startup");

            tokio::net::TcpStream::connect(("127.0.0.1", port))
                .await
                .expect("the RDP listener should accept a TCP connection");

            server.abort();
            feeder.abort();
        })
        .await;
}

#[tokio::test]
async fn a_missing_tls_identity_is_reported_not_panicked() {
    let (_sink, stream) = channel(2);
    let config = ServerConfig::loopback(
        free_port(),
        DesktopSize { width: 640, height: 480 },
        "rdpie".to_owned(),
        "hunter2".to_owned(),
        PathBuf::from("/nonexistent/cert.pem"),
        PathBuf::from("/nonexistent/key.pem"),
    );

    let error = run(config, stream).await.expect_err("a missing identity must be an error");
    assert!(
        error.to_string().contains("TLS identity"),
        "unexpected error message: {error}"
    );
}
