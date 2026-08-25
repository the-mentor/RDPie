//! RDPie protocol core.
//!
//! Wraps `ironrdp-server` and exposes a C ABI for the Swift daemon. This crate
//! must never depend on an Apple framework: keeping it portable is what allows
//! the whole protocol layer to be tested on Linux CI.

/// Re-exported so downstream code and tests share one version of these types.
pub use ironrdp_server::{DesktopSize, DisplayUpdate};

#[cfg(test)]
mod tests {
    use super::DesktopSize;

    #[test]
    fn upstream_types_are_reachable() {
        let size = DesktopSize { width: 1920, height: 1080 };
        assert_eq!(size.width, 1920);
        assert_eq!(size.height, 1080);
    }
}

pub mod frame;

pub use frame::{Frame, FrameSink, FrameStream, SubmitOutcome};
pub mod display;

pub use display::{RdpieDisplay, RdpieDisplayUpdates};
pub mod server;

pub use server::{ServerConfig, run};
pub mod ffi;
pub mod gfx;

pub use gfx::{RdpieGfxFactory, RdpieGfxHandle, gfx_channel};
pub mod input;

pub use input::{RdpieInputCallback, RdpieInputEvent, RdpieInputEventKind, RdpieInputHandler};
pub mod clipboard;

pub use clipboard::{RdpieClipboardCallback, RdpieClipboardFactory, RdpieClipboardHandle, clipboard_channel};
