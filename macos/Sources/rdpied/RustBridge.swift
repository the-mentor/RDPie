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

    func stop() {
        guard let handle else { return }
        rdpie_server_stop(handle)
        self.handle = nil
    }
}
