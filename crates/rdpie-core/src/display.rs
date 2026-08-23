//! Adapts RDPie's frame stream to `ironrdp-server`'s display traits.

use core::num::{NonZeroU16, NonZeroUsize};

use anyhow::{Context as _, Result};
use ironrdp_server::{
    BitmapUpdate, DesktopSize, DisplayUpdate, PixelFormat, RdpServerDisplay,
    RdpServerDisplayUpdates,
};

use crate::frame::{Frame, FrameStream};

/// Display handler backed by frames pushed from the platform capture layer.
pub struct RdpieDisplay {
    size: DesktopSize,
    stream: Option<FrameStream>,
}

impl RdpieDisplay {
    pub fn new(size: DesktopSize, stream: FrameStream) -> Self {
        Self { size, stream: Some(stream) }
    }
}

#[async_trait::async_trait]
impl RdpServerDisplay for RdpieDisplay {
    async fn size(&mut self) -> DesktopSize {
        self.size
    }

    async fn updates(&mut self) -> Result<Box<dyn RdpServerDisplayUpdates>> {
        let stream = self.stream.take().context("display updates already taken")?;
        Ok(Box::new(RdpieDisplayUpdates { stream }))
    }
}

/// Update receiver handed to the RDP session.
pub struct RdpieDisplayUpdates {
    stream: FrameStream,
}

fn to_bitmap(frame: Frame) -> Result<BitmapUpdate> {
    let width = NonZeroU16::new(frame.width).context("frame width was zero")?;
    let height = NonZeroU16::new(frame.height).context("frame height was zero")?;
    let stride = NonZeroUsize::new(frame.stride).context("frame stride was zero")?;
    let expected = stride.get() * usize::from(height.get());
    anyhow::ensure!(
        frame.data.len() >= expected,
        "frame buffer too small: {} bytes for {}x{} stride {}",
        frame.data.len(),
        width,
        height,
        stride
    );
    Ok(BitmapUpdate {
        x: 0,
        y: 0,
        width,
        height,
        format: PixelFormat::BgrA32,
        data: frame.data.into(),
        stride,
    })
}

#[async_trait::async_trait]
impl RdpServerDisplayUpdates for RdpieDisplayUpdates {
    /// # Cancel safety
    ///
    /// Cancel-safe, as the trait requires: `FrameStream::next` keeps its state
    /// in the shared queue, so a dropped future loses no frames.
    async fn next_update(&mut self) -> Result<Option<DisplayUpdate>> {
        match self.stream.next().await {
            Some(frame) => Ok(Some(DisplayUpdate::Bitmap(to_bitmap(frame)?))),
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use ironrdp_server::{DesktopSize, DisplayUpdate, RdpServerDisplay};

    use super::RdpieDisplay;
    use crate::frame::{Frame, channel};

    fn bgra_frame(width: u16, height: u16, tag: u8) -> Frame {
        let stride = usize::from(width) * 4;
        Frame { width, height, stride, data: vec![tag; stride * usize::from(height)] }
    }

    #[tokio::test]
    async fn reports_configured_size() {
        let (_sink, stream) = channel(2);
        let mut display = RdpieDisplay::new(DesktopSize { width: 1280, height: 720 }, stream);
        assert_eq!(display.size().await, DesktopSize { width: 1280, height: 720 });
    }

    #[tokio::test]
    async fn converts_frames_into_bitmap_updates() {
        let (sink, stream) = channel(2);
        let mut display = RdpieDisplay::new(DesktopSize { width: 2, height: 2 }, stream);
        sink.submit(bgra_frame(2, 2, 0xAB));

        let mut updates = display.updates().await.expect("updates");
        let update = updates.next_update().await.expect("no error").expect("an update");

        match update {
            DisplayUpdate::Bitmap(bitmap) => {
                assert_eq!(bitmap.x, 0);
                assert_eq!(bitmap.y, 0);
                assert_eq!(bitmap.width.get(), 2);
                assert_eq!(bitmap.height.get(), 2);
                assert_eq!(bitmap.stride.get(), 8);
                assert!(bitmap.data.iter().all(|b| *b == 0xAB));
            }
            other => panic!("expected a bitmap update, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn ends_cleanly_when_capture_stops() {
        let (sink, stream) = channel(2);
        let mut display = RdpieDisplay::new(DesktopSize { width: 2, height: 2 }, stream);
        let mut updates = display.updates().await.expect("updates");
        drop(sink);
        assert!(updates.next_update().await.expect("no error").is_none());
    }

    #[tokio::test]
    async fn rejects_a_frame_with_zero_dimensions() {
        let (sink, stream) = channel(2);
        let mut display = RdpieDisplay::new(DesktopSize { width: 2, height: 2 }, stream);
        sink.submit(Frame { width: 0, height: 2, stride: 8, data: vec![0; 16] });
        let mut updates = display.updates().await.expect("updates");
        // A malformed frame must not panic the session; it is surfaced as an error.
        assert!(updates.next_update().await.is_err());
    }
}
