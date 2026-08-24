// macos/Sources/rdpied/RustBridge.swift
import Foundation
import CRdpieCore
import RdpieCapture

enum BridgeError: Error {
    case serverFailedToStart
}

/// Owns the Rust server handle and pushes frames into it.
///
/// cbindgen emits `typedef struct RdpieServer RdpieServer;` — an opaque
/// forward declaration — so Swift imports every `RdpieServer *` as
/// `OpaquePointer?`, not `UnsafeMutablePointer<RdpieServer>?`. Pass `handle`
/// straight through to the C functions; no `assumingMemoryBound` cast needed
/// or possible.
final class RustBridge {
    private var handle: OpaquePointer?
    private(set) var droppedFrames = 0

    func start(port: UInt16, width: Int, height: Int,
               username: String, password: String,
               certPath: String, keyPath: String) throws {
        try username.withCString { user in
            try password.withCString { pass in
                try certPath.withCString { cert in
                    try keyPath.withCString { key in
                        var config = RdpieConfig(
                            port: port,
                            width: UInt16(width),
                            height: UInt16(height),
                            username: user,
                            password: pass,
                            cert_pem_path: cert,
                            key_pem_path: key
                        )
                        guard let handle = rdpie_server_start(&config) else {
                            throw BridgeError.serverFailedToStart
                        }
                        self.handle = handle
                    }
                }
            }
        }
    }

    func submit(_ frame: CapturedFrame) {
        guard let handle else { return }
        frame.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let rc = rdpie_server_submit_frame(
                handle,
                UInt16(frame.width), UInt16(frame.height),
                UInt(frame.stride), base, UInt(buffer.count))
            if rc == 1 { droppedFrames += 1 }
        }
    }

    /// True once an EGFX/AVC420-capable client has negotiated the Graphics
    /// Pipeline Extension. Checked once per captured frame by main.swift's
    /// loop — negotiation happens once, early in a connection, and this
    /// does not flip back mid-session, so per-frame polling is cheap and
    /// sufficient; no caching needed.
    func isGfxActive() -> Bool {
        guard let handle else { return false }
        return rdpie_server_gfx_active(handle)
    }

    /// The RDPEGFX AVC420 metadata's quantization-parameter field is
    /// informational (a deblocking-filter hint to the client) rather than a
    /// knob this encoder drives — VTCompressionSession's real-time rate
    /// control picks QP internally per frame and does not expose it back.
    /// ponytail: hardcoded mid-range QP; wire up a real per-frame value if
    /// quality tuning becomes an actual requirement.
    private static let defaultQuantizationParameter: UInt8 = 26

    func submitH264(_ frame: EncodedH264Frame, regionWidth: Int, regionHeight: Int) {
        guard let handle else { return }
        frame.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            _ = rdpie_server_submit_h264_frame(
                handle,
                base, UInt(buffer.count),
                0, 0, UInt16(regionWidth - 1), UInt16(regionHeight - 1),
                Self.defaultQuantizationParameter,
                frame.timestampMs)
        }
    }

    func stop() {
        guard let handle else { return }
        rdpie_server_stop(handle)
        self.handle = nil
    }
}
