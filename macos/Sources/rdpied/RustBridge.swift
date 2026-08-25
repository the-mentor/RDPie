// macos/Sources/rdpied/RustBridge.swift
import AppKit
import Foundation
import CRdpieCore
import RdpieCapture

enum BridgeError: Error {
    case serverFailedToStart
}

/// The C ABI's `RdpieInputCallback` cannot capture Swift closure state — it
/// is a bare function pointer. Object identity is recovered from `context`
/// instead: `RustBridge.start` passes `Unmanaged.passUnretained(self)
/// .toOpaque()` as `input_context`, and this function reverses that to get
/// back the `RustBridge` instance whose `inputInjector` should handle the
/// event. `passUnretained`, not `passRetained`: `RustBridge` (owned by
/// `main.swift`'s top-level `bridge` binding) already outlives the Rust
/// server handle for the whole process lifetime, so there is no dangling-
/// pointer risk to guard against with an extra retain.
///
/// `event` is valid only for the duration of this call (per the FFI
/// contract) — `.pointee` copies the value out before handing it to
/// `InputInjector.handle`, which is free to outlive this call.
private func rdpieHandleInputEvent(_ context: UnsafeMutableRawPointer?, _ event: UnsafePointer<RdpieInputEvent>?) {
    guard let context, let event else { return }
    let bridge = Unmanaged<RustBridge>.fromOpaque(context).takeUnretainedValue()
    bridge.inputInjector.handle(event.pointee)
}

/// Same object-identity-via-context trick as `rdpieHandleInputEvent` — see
/// its doc comment for why `passUnretained` is correct here too.
///
/// `text`/`len` are valid only for the duration of this call (per the FFI
/// contract) — build the `String` before returning, don't retain the
/// pointer.
private func rdpieHandleClipboardText(_ context: UnsafeMutableRawPointer?, _ text: UnsafePointer<UInt8>?, _ len: UInt) {
    guard let context, let text else { return }
    let bridge = Unmanaged<RustBridge>.fromOpaque(context).takeUnretainedValue()
    let data = Data(bytes: text, count: Int(len))
    guard let string = String(data: data, encoding: .utf8) else { return }
    bridge.writeRemoteClipboardText(string)
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

    /// Owned for the life of this bridge so `rdpieHandleInputEvent` always
    /// has somewhere real to deliver events, from process startup — before
    /// any client has connected — through to `stop()`. Constructed with the
    /// real configured desktop size in `start`, below, once it's known;
    /// mouse coordinates need it to scale correctly onto the real display
    /// (see `InputInjector.scaledCursorPosition`).
    private(set) var inputInjector = InputInjector()

    /// Set right after `writeRemoteClipboardText` writes remote-sourced
    /// text to the pasteboard, to the `changeCount` that write produced.
    /// `main.swift`'s poll loop compares against this so it never mistakes
    /// our own write for a new local copy and bounces it straight back to
    /// the remote (an echo loop).
    private(set) var lastKnownClipboardChangeCount = NSPasteboard.general.changeCount

    fileprivate func writeRemoteClipboardText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastKnownClipboardChangeCount = pasteboard.changeCount
    }

    func start(port: UInt16, width: Int, height: Int,
               username: String, password: String,
               certPath: String, keyPath: String, bindAll: Bool = false) throws {
        inputInjector = InputInjector(width: width, height: height)
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
                            key_pem_path: key,
                            input_callback: rdpieHandleInputEvent,
                            input_context: Unmanaged.passUnretained(self).toOpaque(),
                            clipboard_callback: rdpieHandleClipboardText,
                            clipboard_context: Unmanaged.passUnretained(self).toOpaque(),
                            bind_all: bindAll
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

    /// Returns whether the frame actually reached the EGFX event loop —
    /// `false` means the client's H.264 decoder now has a reference-chain
    /// gap (see `H264Encoder.encode`'s `forceKeyframe` parameter).
    @discardableResult
    func submitH264(_ frame: EncodedH264Frame, regionWidth: Int, regionHeight: Int) -> Bool {
        guard let handle else { return false }
        // `rdpie_server_submit_h264_frame` returns 0 for success, -1 for
        // any failure (invalid input or the frame being dropped) — not a C
        // bool.
        return frame.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return rdpie_server_submit_h264_frame(
                handle,
                base, UInt(buffer.count),
                0, 0, UInt16(regionWidth - 1), UInt16(regionHeight - 1),
                Self.defaultQuantizationParameter,
                frame.timestampMs) == 0
        }
    }

    /// Called whenever `main.swift`'s poll loop notices the pasteboard
    /// changed. Advertises the new text to the client (delayed rendering
    /// — see `rdpie_server_submit_clipboard_text`'s doc comment); the
    /// actual bytes only cross the wire later, if the client pastes.
    func submitClipboardText(_ text: String) {
        guard let handle else { return }
        let data = Data(text.utf8)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            _ = rdpie_server_submit_clipboard_text(handle, base, UInt(buffer.count))
        }
    }

    func stop() {
        guard let handle else { return }
        rdpie_server_stop(handle)
        self.handle = nil
    }
}
