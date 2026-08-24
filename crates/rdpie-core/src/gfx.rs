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

        // Proactively create and flush the surface now rather than waiting
        // for the first captured frame. Confirmed live: a mobile client
        // closed the EGFX channel and disconnected ~45ms after this point,
        // consistently, regardless of desktop size or how fast the encoder
        // could produce a frame — a fixed delay unrelated to frame content
        // points at the client expecting to see ResetGraphics/CreateSurface
        // shortly after negotiation, not whenever a frame happens to be
        // ready. Spawned as a task, not called directly: `on_ready` runs
        // while `GraphicsPipelineServer`'s own mutex is already held by the
        // caller (see the module-level deadlock note above) — calling
        // `ensure_surface` here directly would deadlock. A spawned task
        // runs on a fresh call stack once this function returns and the
        // lock is released.
        let state = Arc::clone(&self.state);
        tokio::task::spawn(async move {
            if !(RdpieGfxHandle { state }).ensure_surface() {
                tracing::debug!("proactive EGFX surface creation did not complete");
            }
        });
    }

    fn on_close(&mut self) {
        // Mid-session DVC channel close (client disconnect, or client-driven
        // channel teardown without a fresh connection). Reset the same state
        // `build_server_with_handle` resets for a new connection, so a
        // reconnect starts clean. Deliberately does not touch `state.handle`
        // — see the module-level deadlock note.
        self.state.ready.store(false, Ordering::Release);
        *self.state.surface_id.lock().expect("gfx surface mutex poisoned") = None;
        tracing::info!("EGFX channel closed");
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

    /// The desktop size this handle was created with (fixed for the process
    /// lifetime — see `gfx_channel`).
    pub fn size(&self) -> (u16, u16) {
        (self.state.width, self.state.height)
    }

    /// Creates and maps the single full-desktop surface if not already
    /// done, flushing the resulting ResetGraphics/CreateSurface/
    /// MapSurfaceToOutput PDUs to the client immediately. Idempotent: a
    /// no-op returning `true` if the surface already exists (whichever of
    /// the proactive `on_ready` task or a real frame submission gets here
    /// first wins; the loser sees the surface already set and skips
    /// straight past). AVC444 is out of scope for this phase — see spec
    /// follow-up.
    ///
    /// Returns `false` — never panics — if: no connection is currently
    /// live, the surface could not be created or mapped, or the resulting
    /// PDUs could not be encoded or handed to the connection's event loop
    /// (the loop may have already shut down).
    fn ensure_surface(&self) -> bool {
        let Some(sender) = self.state.sender.lock().expect("gfx sender mutex poisoned").clone() else {
            tracing::debug!("ensure_surface: no event sender registered yet");
            return false;
        };

        let handle = {
            let guard = self.state.handle.lock().expect("gfx handle mutex poisoned");
            let Some(handle) = guard.as_ref() else {
                tracing::debug!("ensure_surface: no GFX server handle yet");
                return false;
            };
            Arc::clone(handle)
        };

        let (channel_id, dvc_messages) = {
            let mut server = handle.lock().expect("GfxServerHandle mutex poisoned");

            let mut surface_guard = self.state.surface_id.lock().expect("gfx surface mutex poisoned");
            if surface_guard.is_some() {
                return true;
            }

            let Some(id) = server.create_surface(self.state.width, self.state.height) else {
                tracing::debug!("ensure_surface: create_surface failed");
                return false;
            };
            if !server.map_surface_to_output(id, 0, 0) {
                tracing::debug!("ensure_surface: map_surface_to_output failed");
                return false;
            }
            *surface_guard = Some(id);
            drop(surface_guard);

            let Some(channel_id) = server.channel_id() else {
                // Should not happen once `is_ready()` is true (the DVC start()
                // callback that sets this fires before capability negotiation
                // completes), but a client-driven protocol edge case is not a
                // reason to panic.
                tracing::debug!("ensure_surface: no channel_id after is_ready");
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
                tracing::error!(%error, "encoding EGFX surface-setup DVC messages");
                return false;
            }
        };

        let sent = sender
            .send(ServerEvent::Egfx(EgfxServerMessage::SendMessages { messages: svc_messages }))
            .is_ok();
        tracing::debug!(sent, "flushed proactive EGFX surface setup");
        sent
    }

    /// Push one AVC420-encoded frame to the client.
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

        // Usually already done by the proactive on_ready task by the time a
        // frame is ready; this is the lazy fallback for the rare case where
        // a frame becomes ready before that task has run.
        if self.state.surface_id.lock().expect("gfx surface mutex poisoned").is_none() && !self.ensure_surface() {
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

            let surface_id = self
                .state
                .surface_id
                .lock()
                .expect("gfx surface mutex poisoned")
                .expect("ensure_surface guarantees this is set on success");

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

        let sent = sender
            .send(ServerEvent::Egfx(EgfxServerMessage::SendMessages { messages: svc_messages }))
            .is_ok();

        tracing::debug!(
            bytes = h264_data.len(),
            surface_id = self.state.surface_id.lock().expect("gfx surface mutex poisoned").unwrap_or_default(),
            timestamp_ms,
            sent,
            "submitted AVC420 frame to EGFX event loop"
        );

        sent
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use ironrdp_dvc::DvcProcessor as _;
    use ironrdp_egfx::pdu::CapabilitiesV8Flags;

    use super::*;

    // `on_ready` spawns a task (see its doc comment for why), which panics
    // outside a running Tokio runtime — every test that calls `on_ready`
    // needs one, even if the test itself is otherwise synchronous.

    #[tokio::test]
    async fn ready_flag_starts_false_and_flips_true_after_on_ready() {
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

    #[tokio::test]
    async fn submit_after_on_ready_but_before_a_sender_is_set_is_rejected_not_a_crash() {
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

    #[tokio::test]
    async fn on_ready_proactively_creates_and_flushes_the_surface_without_a_frame() {
        use ironrdp_egfx::pdu::GfxPdu;
        use ironrdp_pdu::{Encode as _, WriteCursor};

        let (mut factory, gfx) = gfx_channel(640, 480);

        let (tx, mut rx) = mpsc::unbounded_channel();
        factory.set_sender(tx);

        let (_bridge, handle) = factory.build_server_with_handle().expect("factory always returns Some");

        // Calling `on_ready` directly on a standalone handler (as the other
        // tests in this module do) is not enough here: `create_surface`
        // gates on `GraphicsPipelineServer`'s own internal state machine
        // reaching `Ready`, which is only set by actually processing a
        // real `CapabilitiesAdvertise` PDU — so build and encode one, then
        // drive it through the real `process()` call. This also exercises
        // the real handler embedded in the server (shares this test's
        // `gfx` handle via the same `Arc<GfxState>`), which is what
        // actually calls `on_ready` and triggers the proactive spawn.
        let advertise = GfxPdu::CapabilitiesAdvertise(CapabilitiesAdvertisePdu::from_typed(&[
            CapabilitySet::V8 { flags: CapabilitiesV8Flags::empty() },
        ]));
        let mut bytes = vec![0u8; advertise.size()];
        advertise
            .encode(&mut WriteCursor::new(&mut bytes))
            .expect("encoding a synthetic CapabilitiesAdvertise PDU");

        {
            let mut server = handle.lock().expect("GfxServerHandle mutex poisoned");
            // Real negotiation sets `channel_id` via the DVC `start()`
            // callback before any PDU is processed.
            server.start(3).expect("start never fails");
            server.process(3, &bytes).expect("processing a synthetic CapabilitiesAdvertise PDU");
        }

        assert!(gfx.is_ready(), "processing CapabilitiesAdvertise should have called on_ready");

        // The proactive task runs on a spawned task, not synchronously
        // within on_ready (see its doc comment) — bounded wait so a broken
        // fix fails the test instead of hanging it.
        let event = tokio::time::timeout(Duration::from_secs(1), rx.recv())
            .await
            .expect("proactive surface creation should flush a message within 1s")
            .expect("channel should not close while the sender is held above");

        let ServerEvent::Egfx(EgfxServerMessage::SendMessages { messages }) = event else {
            panic!("expected a ServerEvent::Egfx(SendMessages), got {event:?}");
        };
        assert!(!messages.is_empty(), "expected non-empty ResetGraphics/CreateSurface PDU bytes");
    }
}
