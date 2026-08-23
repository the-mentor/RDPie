//! Bounded, non-blocking hand-off from the capture thread to the RDP session.

/// A captured frame in BGRA8888.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub width: u16,
    pub height: u16,
    pub stride: usize,
    pub data: Vec<u8>,
}

/// What happened to a submitted frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitOutcome {
    Accepted,
    DroppedOldest,
    Closed,
}

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use tokio::sync::Notify;

struct Shared {
    queue: Mutex<Option<VecDeque<Frame>>>, // None once the stream is gone
    capacity: usize,
    notify: Notify,
}

/// Producer half. Cloneable, and `submit` never blocks or awaits.
#[derive(Clone)]
pub struct FrameSink {
    shared: Arc<Shared>,
}

/// Consumer half, driven by the RDP session.
pub struct FrameStream {
    shared: Arc<Shared>,
}

/// Create a bounded frame channel that discards the oldest frame when full.
pub fn channel(capacity: usize) -> (FrameSink, FrameStream) {
    assert!(capacity > 0, "frame channel capacity must be non-zero");
    let shared = Arc::new(Shared {
        queue: Mutex::new(Some(VecDeque::with_capacity(capacity))),
        capacity,
        notify: Notify::new(),
    });
    (FrameSink { shared: Arc::clone(&shared) }, FrameStream { shared })
}

impl FrameSink {
    /// Submit a frame. Returns immediately in all cases.
    pub fn submit(&self, frame: Frame) -> SubmitOutcome {
        let mut guard = self.shared.queue.lock().expect("frame queue poisoned");
        let Some(queue) = guard.as_mut() else {
            return SubmitOutcome::Closed;
        };
        let outcome = if queue.len() >= self.shared.capacity {
            queue.pop_front();
            SubmitOutcome::DroppedOldest
        } else {
            SubmitOutcome::Accepted
        };
        queue.push_back(frame);
        drop(guard);
        self.shared.notify.notify_one();
        outcome
    }
}

impl FrameStream {
    /// Await the next frame.
    ///
    /// # Cancel safety
    ///
    /// Cancel-safe: state lives in the shared queue, so a dropped future loses
    /// no frames. `RdpServerDisplayUpdates::next_update` requires this.
    pub async fn next(&mut self) -> Option<Frame> {
        loop {
            {
                let mut guard = self.shared.queue.lock().expect("frame queue poisoned");
                if let Some(queue) = guard.as_mut() {
                    if let Some(frame) = queue.pop_front() {
                        return Some(frame);
                    }
                } else {
                    return None;
                }
            }
            if Arc::strong_count(&self.shared) == 1 {
                return None; // every sink is gone and the queue is drained
            }
            self.shared.notify.notified().await;
        }
    }
}

impl Drop for FrameStream {
    fn drop(&mut self) {
        let mut guard = self.shared.queue.lock().expect("frame queue poisoned");
        *guard = None;
    }
}

impl Drop for FrameSink {
    fn drop(&mut self) {
        // `notify_one`, not `notify_waiters`. If the last sink drops in the
        // window between `next`'s strong-count check and its waiter being
        // registered, `notify_waiters` has no waiter to wake and stores no
        // permit, so `next` would hang. `notify_one` stores a permit and the
        // woken loop re-checks and ends the stream.
        //
        // Note this window is too narrow to test deterministically: the test
        // below sleeps until the waiter is certainly registered, so it passes
        // under both variants. The choice here is correct-by-construction,
        // not test-driven.
        self.shared.notify.notify_one();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(tag: u8) -> Frame {
        Frame { width: 2, height: 1, stride: 8, data: vec![tag; 8] }
    }

    #[tokio::test]
    async fn delivers_frames_in_order() {
        let (sink, mut stream) = channel(4);
        assert_eq!(sink.submit(frame(1)), SubmitOutcome::Accepted);
        assert_eq!(sink.submit(frame(2)), SubmitOutcome::Accepted);
        assert_eq!(stream.next().await.unwrap().data[0], 1);
        assert_eq!(stream.next().await.unwrap().data[0], 2);
    }

    #[tokio::test]
    async fn drops_oldest_when_full_and_never_blocks() {
        let (sink, mut stream) = channel(2);
        assert_eq!(sink.submit(frame(1)), SubmitOutcome::Accepted);
        assert_eq!(sink.submit(frame(2)), SubmitOutcome::Accepted);
        // Third submission must return immediately, discarding frame 1.
        assert_eq!(sink.submit(frame(3)), SubmitOutcome::DroppedOldest);
        assert_eq!(stream.next().await.unwrap().data[0], 2);
        assert_eq!(stream.next().await.unwrap().data[0], 3);
    }

    #[tokio::test]
    async fn stream_ends_when_sink_is_dropped() {
        let (sink, mut stream) = channel(2);
        drop(sink);
        assert!(stream.next().await.is_none());
    }

    #[test]
    fn submit_after_stream_dropped_reports_closed() {
        let (sink, stream) = channel(2);
        drop(stream);
        assert_eq!(sink.submit(frame(1)), SubmitOutcome::Closed);
    }

    #[tokio::test]
    async fn stream_ends_when_last_sink_drops_while_awaiting() {
        use core::time::Duration;

        let (sink, mut stream) = channel(2);
        let waiter = tokio::spawn(async move { stream.next().await });

        // Let the waiter reach `.notified().await` before dropping the sink.
        // This covers the ordinary "sink drops mid-await" path; it does not
        // discriminate between `notify_one` and `notify_waiters` (see the
        // comment on `Drop for FrameSink`).
        tokio::time::sleep(Duration::from_millis(50)).await;
        drop(sink);

        let outcome = tokio::time::timeout(Duration::from_secs(2), waiter).await;
        match outcome {
            Ok(Ok(None)) => {}
            Ok(Ok(Some(_))) => panic!("expected no frame"),
            Ok(Err(error)) => panic!("waiter task panicked: {error}"),
            Err(_) => panic!("next() hung after the last sink dropped"),
        }
    }
}
