// macos/Sources/rdpied/main.swift
import Foundation
import RdpieCapture

// Phase 1: configuration is environment-driven. The menu-bar app and Keychain
// storage arrive in Phase 7; hardcoding a credential here would be a security
// regression, so an explicit password is required.
guard let password = ProcessInfo.processInfo.environment["RDPIE_PASSWORD"], !password.isEmpty else {
    FileHandle.standardError.write(Data("RDPIE_PASSWORD must be set\n".utf8))
    exit(2)
}
let username = ProcessInfo.processInfo.environment["RDPIE_USERNAME"] ?? "rdpie"
let useSynthetic = ProcessInfo.processInfo.environment["RDPIE_SYNTHETIC"] == "1"
let certPath = ProcessInfo.processInfo.environment["RDPIE_CERT"] ?? "./cert.pem"
let keyPath = ProcessInfo.processInfo.environment["RDPIE_KEY"] ?? "./key.pem"
let bindAll = ProcessInfo.processInfo.environment["RDPIE_BIND_ALL"] == "1"

// Matches whatever the RDP client actually reports as its desktop size —
// this daemon doesn't negotiate resize (Phase 6), so a client whose real
// viewport doesn't match this fixed size may reject the session outright
// rather than tolerate the mismatch (observed with a mobile client's
// portrait resolution during Phase 3 live testing).
let width = ProcessInfo.processInfo.environment["RDPIE_WIDTH"].flatMap(Int.init) ?? 1280
let height = ProcessInfo.processInfo.environment["RDPIE_HEIGHT"].flatMap(Int.init) ?? 720

let source: CaptureSource = useSynthetic ? SyntheticCaptureSource() : ScreenCaptureKitSource()

if !useSynthetic && !ScreenCaptureKitSource.hasPermission() {
    FileHandle.standardError.write(
        Data("Screen Recording permission is required. Grant it in System Settings › Privacy & Security › Screen Recording, then run again.\n".utf8))
    exit(3)
}

if !InputInjector.hasAccessibilityPermission() {
    // Global Constraint: Accessibility only gates the optional input
    // capability, which is designed to degrade gracefully everywhere else
    // in this feature (see the mid-session revocation handling below) —
    // unlike Screen Recording above, it must not refuse to start.
    FileHandle.standardError.write(
        Data("Accessibility permission not granted — starting in view-only mode. Grant it in System Settings › Privacy & Security › Accessibility to enable input control.\n".utf8))
}

let bridge = RustBridge()
try bridge.start(port: 3389, width: width, height: height,
                 username: username, password: password,
                 certPath: certPath, keyPath: keyPath, bindAll: bindAll)

try source.start(configuration: CaptureConfiguration(
    width: width, height: height, framesPerSecond: 30))

signal(SIGINT) { _ in exit(0) }
if bindAll {
    print("rdpied listening on 0.0.0.0:3389 (RDPIE_BIND_ALL=1 — reachable from the network, not just this machine) — connect with an RDP client")
} else {
    print("rdpied listening on 127.0.0.1:3389 — connect with an RDP client")
}

// Created eagerly, not on the first frame after a client negotiates EGFX:
// `VTCompressionSession` setup takes long enough (~100ms on this hardware)
// that building it lazily, right when a client is already watching for
// video, lost the race against clients with a short patience for the first
// graphics data — confirmed live against a mobile RDP client that closed
// the EGFX channel ~45ms after negotiating, well before a lazily-created
// encoder could produce its first frame.
func freshH264Encoder() -> H264Encoder? {
    do {
        return try H264Encoder(width: width, height: height)
    } catch {
        FileHandle.standardError.write("H264Encoder creation failed: \(error)\n".data(using: .utf8)!)
        return nil
    }
}

var h264Encoder = freshH264Encoder()
var wasGfxActive = false
// Not necessarily true — Accessibility is no longer required to start (see
// the view-only-mode warning above) — but `hasAccessibilityPermission()` is
// polled fresh on the first loop iteration below before this is ever read,
// so the initial value only affects whether that first iteration logs a
// spurious "revoked" line; starting optimistic avoids that.
var wasAccessibilityGranted = true
let encoderClockStart = DispatchTime.now()

for await frame in source.frames {
    let accessibilityGranted = InputInjector.hasAccessibilityPermission()
    if wasAccessibilityGranted && !accessibilityGranted {
        // Global Constraint: downgrade to view-only, don't tear down the
        // connection. `InputInjector.handle` already drops every event on
        // its own when this happens — nothing here needs to touch
        // `source`/`bridge` — this line exists purely so a revocation is
        // visible in the log instead of silently going unnoticed.
        FileHandle.standardError.write(
            Data("Accessibility permission revoked — continuing in view-only mode.\n".utf8))
    }
    wasAccessibilityGranted = accessibilityGranted

    let gfxActive = bridge.isGfxActive()
    if wasGfxActive && !gfxActive {
        // The connection that was using `h264Encoder` just ended (EGFX
        // channel closed). Pre-warm a fresh one now, while no client is
        // waiting on it, so the next connection's first frame is a normal
        // encode instead of paying for session creation. A fresh encoder
        // is also required correctness-wise: a new client's decoder has no
        // state, and resuming the old session would emit a P-frame with no
        // reference it's ever seen — this encoder's first real `encode()`
        // call, whenever the next connection arrives, is guaranteed to be
        // its first ever, so it always starts with a keyframe carrying
        // SPS/PPS.
        h264Encoder = freshH264Encoder()
    }
    wasGfxActive = gfxActive

    if gfxActive {
        guard let encoder = h264Encoder else {
            // Pre-warming failed (startup or post-connection) — fall back
            // to the raw path for this frame rather than dropping the
            // session; view-only degradation beats a crash or a stall.
            bridge.submit(frame)
            continue
        }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - encoderClockStart.uptimeNanoseconds
        let timestampMs = UInt32(truncatingIfNeeded: elapsedNs / 1_000_000)

        do {
            if let encoded = try await encoder.encode(frame, timestampMs: timestampMs) {
                bridge.submitH264(encoded, regionWidth: frame.width, regionHeight: frame.height)
            }
        } catch {
            FileHandle.standardError.write("H.264 encode failed: \(error)\n".data(using: .utf8)!)
        }
    } else {
        bridge.submit(frame)
    }
}

source.stop()
bridge.stop()
