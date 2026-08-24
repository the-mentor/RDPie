// macos/Sources/RdpieCapture/CaptureSource.swift
import Foundation

public struct CaptureConfiguration: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int

    public init(width: Int, height: Int, framesPerSecond: Int) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }
}

/// One captured frame in BGRA8888, matching what the Rust ABI expects.
public struct CapturedFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let data: Data

    public init(width: Int, height: Int, stride: Int, data: Data) {
        self.width = width
        self.height = height
        self.stride = stride
        self.data = data
    }
}

public enum CaptureError: Error {
    case noDisplayAvailable
    case permissionDenied
    case alreadyRunning
}

/// The seam required by spec §4.4. The locked-screen strategy may change
/// behind this protocol without affecting anything above it.
public protocol CaptureSource: AnyObject {
    var isAvailableWhileLocked: Bool { get }
    func start(configuration: CaptureConfiguration) throws
    func stop()
    var frames: AsyncStream<CapturedFrame> { get }
}
