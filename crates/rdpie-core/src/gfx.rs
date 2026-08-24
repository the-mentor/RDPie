//! Bridges RDPie's H.264 frames to the EGFX graphics pipeline (MS-RDPEGFX,
//! AVC420 only — AVC444 is out of scope for this phase; see the module docs
//! on `submit_avc420_frame` for why).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use ironrdp_egfx::pdu::{Avc420Region, CapabilitiesAdvertisePdu, CapabilitySet};
use ironrdp_egfx::server::{GraphicsPipelineHandler, GraphicsPipelineServer};
use ironrdp_server::{
    EgfxServerMessage, GfxDvcBridge, GfxServerFactory, GfxServerHandle, ServerEvent, ServerEventSender,
};
use tokio::sync::mpsc;

/// State shared between the `GfxServerFactory` (owned by the builder, one
/// instance per server) and every `GraphicsPipelineHandler` instance
/// (`ironrdp-server` builds one fresh handler per accepted connection, via
/// `GfxServerFactory::build_server_with_handle`) plus the `RdpieGfxHandle`
/// the FFI layer keeps.
struct GfxState {
    ready: AtomicBool,
    width: u16,
    height: u16,
    surface_id: Mutex<Option<u16>>,
    handle: Mutex<Option<GfxServerHandle>>,
    sender: Mutex<Option<mpsc::UnboundedSender<ServerEvent>>>,
}

/// Consumed once by `RdpServerBuilder::with_gfx_factory`.
pub struct RdpieGfxFactory {
    state: Arc<GfxState>,
}

/// Kept by the FFI layer to query readiness and push encoded frames.
pub struct RdpieGfxHandle {
    state: Arc<GfxState>,
}

/// Create a linked factory/handle pair for a desktop of the given size.
/// The size is fixed for the process lifetime: Phase 2 does not support
/// resizing the EGFX surface mid-session.
pub fn gfx_channel(width: u16, height: u16) -> (RdpieGfxFactory, RdpieGfxHandle) {
    let state = Arc::new(GfxState {
        ready: AtomicBool::new(false),
        width,
        height,
        surface_id: Mutex::new(None),
        handle: Mutex::new(None),
        sender: Mutex::new(None),
    });
    (RdpieGfxFactory { state: Arc::clone(&state) }, RdpieGfxHandle { state })
}

/// EGFX callback target. See the module-level deadlock note: this
/// deliberately does not touch `state.handle` from `on_ready`.
struct RdpieGfxHandler {
    state: Arc<GfxState>,
}

impl GraphicsPipelineHandler for RdpieGfxHandler {
    fn capabilities_advertise(&mut self, _pdu: &CapabilitiesAdvertisePdu) {
        // Informational only — negotiation itself already happened inside
        // `GraphicsPipelineServer` by the time this fires.
    }

    fn on_ready(&mut self, _negotiated: &CapabilitySet) {
        self.state.ready.store(true, Ordering::Release);
        tracing::info!("EGFX channel ready; client accepts AVC420 video");
    }
}

impl ServerEventSender for RdpieGfxFactory {
    fn set_sender(&mut self, sender: mpsc::UnboundedSender<ServerEvent>) {
        *self.state.sender.lock().expect("gfx sender mutex poisoned") = Some(sender);
    }
}

impl GfxServerFactory for RdpieGfxFactory {
    fn build_gfx_handler(&self) -> Box<dyn GraphicsPipelineHandler> {
        Box::new(RdpieGfxHandler { state: Arc::clone(&self.state) })
    }

    fn build_server_with_handle(&self) -> Option<(GfxDvcBridge, GfxServerHandle)> {
        // A new connection (first client, or a reconnect) starts negotiation
        // over: forget whatever the previous connection had ready.
        self.state.ready.store(false, Ordering::Release);
        *self.state.surface_id.lock().expect("gfx surface mutex poisoned") = None;

        let handler = self.build_gfx_handler();
        let server: GfxServerHandle = Arc::new(Mutex::new(GraphicsPipelineServer::new(handler)));
        let bridge = GfxDvcBridge::new(Arc::clone(&server));

        *self.state.handle.lock().expect("gfx handle mutex poisoned") = Some(Arc::clone(&server));

        Some((bridge, server))
    }
}

impl RdpieGfxHandle {
    /// Whether the connected client has finished EGFX capability
    /// negotiation. `false` before any client connects, and reset to
    /// `false` at the start of each new connection.
    pub fn is_ready(&self) -> bool {
        self.state.ready.load(Ordering::Acquire)
    }

    /// Push one AVC420-encoded frame to the client.
    ///
    /// Creates and maps the single full-desktop surface on first successful
    /// call. AVC444 is out of scope for this phase — see spec follow-up.
    ///
    /// Returns `false` — never panics — if: the channel has not finished
    /// negotiation, no connection is currently live, the surface could not
    /// be created or mapped, the encoder rejected the frame (backpressure,
    /// codec not supported by this client, or an unknown surface), or the
    /// resulting PDUs could not be encoded or handed to the connection's
    /// event loop (the loop may have already shut down).
    pub fn submit_avc420_frame(&self, h264_data: &[u8], regions: &[Avc420Region], timestamp_ms: u32) -> bool {
        if !self.is_ready() {
            return false;
        }

        let Some(sender) = self.state.sender.lock().expect("gfx sender mutex poisoned").clone() else {
            return false;
        };

        let handle = {
            let guard = self.state.handle.lock().expect("gfx handle mutex poisoned");
            let Some(handle) = guard.as_ref() else {
                return false;
            };
            Arc::clone(handle)
        };

        let (channel_id, dvc_messages) = {
            let mut server = handle.lock().expect("GfxServerHandle mutex poisoned");

            let mut surface_guard = self.state.surface_id.lock().expect("gfx surface mutex poisoned");
            let surface_id = match *surface_guard {
                Some(id) => id,
                None => {
                    let Some(id) = server.create_surface(self.state.width, self.state.height) else {
                        return false;
                    };
                    if !server.map_surface_to_output(id, 0, 0) {
                        return false;
                    }
                    *surface_guard = Some(id);
                    id
                }
            };
            drop(surface_guard);

            if server.send_avc420_frame(surface_id, h264_data, regions, timestamp_ms).is_none() {
                return false;
            }

            let Some(channel_id) = server.channel_id() else {
                // Should not happen once `is_ready()` is true (the DVC start()
                // callback that sets this fires before capability negotiation
                // completes), but a client-driven protocol edge case is not a
                // reason to panic.
                return false;
            };

            (channel_id, server.drain_output())
        };

        let svc_messages = match ironrdp_dvc::encode_dvc_messages(
            channel_id,
            dvc_messages,
            ironrdp_svc::ChannelFlags::SHOW_PROTOCOL,
        ) {
            Ok(messages) => messages,
            Err(error) => {
                tracing::error!(%error, "encoding EGFX DVC messages");
                return false;
            }
        };

        sender
            .send(ServerEvent::Egfx(EgfxServerMessage::SendMessages { messages: svc_messages }))
            .is_ok()
    }
}

#[cfg(test)]
mod tests {
    use ironrdp_egfx::pdu::CapabilitiesV8Flags;

    use super::*;

    #[test]
    fn ready_flag_starts_false_and_flips_true_after_on_ready() {
        let (factory, gfx) = gfx_channel(1920, 1080);
        assert!(!gfx.is_ready());

        let mut handler = factory.build_gfx_handler();
        handler.on_ready(&CapabilitySet::V8 { flags: CapabilitiesV8Flags::empty() });

        assert!(gfx.is_ready());
    }

    #[test]
    fn submit_before_on_ready_is_rejected_not_a_crash() {
        let (_factory, gfx) = gfx_channel(1920, 1080);
        assert!(!gfx.submit_avc420_frame(&[], &[], 0));
    }

    #[test]
    fn submit_after_on_ready_but_before_a_sender_is_set_is_rejected_not_a_crash() {
        let (factory, gfx) = gfx_channel(1920, 1080);
        let mut handler = factory.build_gfx_handler();
        handler.on_ready(&CapabilitySet::V8 { flags: CapabilitiesV8Flags::empty() });
        assert!(gfx.is_ready());

        // `ServerEventSender::set_sender` is only ever called by
        // `RdpServer::new()`; there is no live server here, so there is
        // nowhere to route the encoded PDUs even though negotiation looks
        // complete from the handle's point of view.
        assert!(!gfx.submit_avc420_frame(&[], &[], 0));
    }
}
