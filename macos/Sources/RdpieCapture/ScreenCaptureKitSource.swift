// macos/Sources/RdpieCapture/ScreenCaptureKitSource.swift
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

/// Captures the main display via ScreenCaptureKit, converting each frame to
/// BGRA8888 for the Rust ABI.
public final class ScreenCaptureKitSource: NSObject, CaptureSource, SCStreamOutput, @unchecked Sendable {

    /// `spikes/locked-capture/RESULTS.md` observed frames continuing
    /// uninterrupted through a full lock/unlock cycle on a Mac mini (M1),
    /// macOS 26.5.1. That is the only hardware/OS combination tested.
    public var isAvailableWhileLocked: Bool { true }

    private var stream: SCStream?
    // Created eagerly, not lazily: see the same fix and its rationale in
    // SyntheticCaptureSource.swift. A lazy `frames` here would have the
    // identical hang if `stop()` runs before `frames` is ever read.
    public let frames: AsyncStream<CapturedFrame>
    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private let lock = NSLock()

    public override init() {
        (frames, continuation) = AsyncStream.makeStream()
        super.init()
    }

    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func start(configuration: CaptureConfiguration) throws {
        lock.lock()
        let running = stream != nil
        lock.unlock()
        guard !running else { throw CaptureError.alreadyRunning }
        guard Self.hasPermission() else { throw CaptureError.permissionDenied }

        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    throw CaptureError.noDisplayAvailable
                }

                let config = SCStreamConfiguration()
                config.width = configuration.width
                config.height = configuration.height
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(
                    value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
                config.showsCursor = true
                config.queueDepth = 3

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
                try await stream.startCapture()

                self.lock.lock()
                self.stream = stream
                self.lock.unlock()
            } catch {
                startError = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        if let startError { throw startError }
    }

    public func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        Task { try? await stream?.stopCapture() }
        continuation.finish()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else {
            return   // a frame with no image buffer is a no-change heartbeat
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let frame = CapturedFrame(
            width: width,
            height: height,
            stride: stride,
            data: Data(bytes: base, count: stride * height)
        )

        continuation.yield(frame)
    }
}
