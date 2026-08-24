// macos/Sources/RdpieCapture/SyntheticCaptureSource.swift
import Foundation

/// A deterministic capture source that needs no display and no TCC grant.
/// Every test above the capture layer runs against this.
public final class SyntheticCaptureSource: CaptureSource, @unchecked Sendable {
    public var isAvailableWhileLocked: Bool { true }

    // Created eagerly, not lazily: a lazily-created stream races `stop()`
    // being called before `frames` is ever read, which finishes a
    // not-yet-existent continuation and leaves the stream `frames` later
    // creates with no one left to finish it — an unrecoverable hang for
    // any consumer that reads `frames` after `stop()`.
    public let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private var timer: DispatchSourceTimer?
    private var tick: UInt8 = 0
    private let lock = NSLock()

    public init() {
        (frames, continuation) = AsyncStream.makeStream()
    }

    public func start(configuration: CaptureConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { throw CaptureError.alreadyRunning }

        let stride = configuration.width * 4
        let byteCount = stride * configuration.height
        let interval = 1.0 / Double(max(configuration.framesPerSecond, 1))

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let value = self.tick
            self.tick = self.tick &+ 1
            self.lock.unlock()

            self.continuation.yield(CapturedFrame(
                width: configuration.width,
                height: configuration.height,
                stride: stride,
                data: Data(repeating: value, count: byteCount)
            ))
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()

        timer?.cancel()
        continuation.finish()
    }
}
