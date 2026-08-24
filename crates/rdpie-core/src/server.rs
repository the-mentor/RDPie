//! Assembles an `ironrdp-server` instance from RDPie's configuration.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context as _, Result};
use ironrdp_server::{
    Credentials, DesktopSize, ExactMatchCredentialValidator, RdpServer, TlsIdentityCtx,
};

use crate::display::RdpieDisplay;
use crate::frame::FrameStream;
use crate::gfx::RdpieGfxFactory;
use crate::input::RdpieInputHandler;

/// Everything the daemon needs to start a listener.
#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub bind: SocketAddr,
    pub size: DesktopSize,
    pub username: String,
    pub password: String,
    pub cert_pem: PathBuf,
    pub key_pem: PathBuf,
}

impl ServerConfig {
    /// Bind to loopback. Spec section 8.5 makes this the only safe default;
    /// widening the listener is a deliberate act, not a convenience.
    pub fn loopback(
        port: u16,
        size: DesktopSize,
        username: String,
        password: String,
        cert_pem: PathBuf,
        key_pem: PathBuf,
    ) -> Self {
        Self {
            bind: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port),
            size,
            username,
            password,
            cert_pem,
            key_pem,
        }
    }

    pub fn credentials(&self) -> Credentials {
        Credentials {
            username: self.username.clone(),
            password: self.password.clone(),
            domain: None,
        }
    }
}

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

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr};
    use std::path::PathBuf;

    use ironrdp_server::DesktopSize;

    use super::ServerConfig;

    fn config() -> ServerConfig {
        ServerConfig::loopback(
            3389,
            DesktopSize { width: 1280, height: 720 },
            "rdpie".to_owned(),
            "hunter2".to_owned(),
            PathBuf::from("/tmp/cert.pem"),
            PathBuf::from("/tmp/key.pem"),
        )
    }

    #[test]
    fn loopback_config_binds_to_localhost_only() {
        // Spec section 8.5: exposing 3389 beyond loopback must be an explicit opt-in.
        assert_eq!(config().bind.ip(), IpAddr::V4(Ipv4Addr::LOCALHOST));
        assert_eq!(config().bind.port(), 3389);
    }

    #[test]
    fn credentials_round_trip_into_upstream_type() {
        let creds = config().credentials();
        assert_eq!(creds.username, "rdpie");
        assert_eq!(creds.password, "hunter2");
    }
}
