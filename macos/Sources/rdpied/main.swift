// macos/Sources/rdpied/main.swift
import AppKit
import CoreGraphics
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
// Escape hatch for clients that negotiate EGFX but hit trouble with the
// H.264 path (encode/decode bugs, unsupported client codec quirks) — forces
// every frame over the raw-bitmap fallback instead, at a real bandwidth and
// quality cost, without needing a client that lacks EGFX support at all.
let bitmapOnly = ProcessInfo.processInfo.environment["RDPIE_BITMAP_ONLY"] == "1"

// Defaults to the Mac's actual native screen resolution (in pixels, matching
// what ScreenCaptureKit will actually capture — not points, which would be
// wrong on a Retina display) rather than an arbitrary fixed literal: serving
// a size unrelated to the real screen stretched/blurred the image, since the
// RDP client scales whatever aspect ratio it's given to fit its own window.
// This daemon still doesn't negotiate resize with the client (Phase 6), so a
// client whose own viewport doesn't match this size may reject the session
// outright rather than tolerate the mismatch (observed with a mobile
// client's portrait resolution during Phase 3 live testing) — RDPIE_WIDTH/
// RDPIE_HEIGHT remain available to override for exactly that case.
//
// An override is bounded to the C ABI's `u16` width/height and kept off
// zero: a zero desktop size divides by zero in `InputInjector`'s mouse-
// coordinate scaling, and anything outside `UInt16`'s range traps the
// `RdpieConfig` conversion in `RustBridge.start` instead of failing with a
// clear message. The computed native-resolution default needs no such
// check — `CGDisplayPixelsWide`/`High` never return a value outside that
// range for a real display.
func desktopDimension(_ name: String, default fallback: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[name] else { return fallback }
    guard let value = Int(raw), (1...Int(UInt16.max)).contains(value) else {
        FileHandle.standardError.write(Data("\(name) must be between 1 and \(UInt16.max)\n".utf8))
        exit(2)
    }
    return value
}
let width = desktopDimension("RDPIE_WIDTH", default: Int(CGDisplayPixelsWide(CGMainDisplayID())))
let height = desktopDimension("RDPIE_HEIGHT", default: Int(CGDisplayPixelsHigh(CGMainDisplayID())))

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
// Set whenever `bridge.submitH264` fails to deliver a frame (EGFX
// backpressure, most commonly under heavy screen change) — the encoder's
// own reference chain stays internally consistent regardless, but the
// client's decoder now has a gap, so the next frame must be a full
// keyframe rather than a delta against a picture the client never saw.
var needsKeyframe = false
// Local pasteboard polling: AppKit has no clipboard-change notification,
// only a monotonically increasing changeCount to compare against. Reusing
// this loop (already running ~30x/sec while a client is connected) avoids
// a second timer for what is otherwise a single cheap integer comparison
// per iteration.
var lastPolledClipboardChangeCount = NSPasteboard.general.changeCount
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

    let pasteboard = NSPasteboard.general
    if pasteboard.changeCount != lastPolledClipboardChangeCount {
        lastPolledClipboardChangeCount = pasteboard.changeCount
        // Skip re-advertising a change this process itself just wrote —
        // see RustBridge.writeRemoteClipboardText's doc comment.
        if pasteboard.changeCount != bridge.lastKnownClipboardChangeCount, let text = pasteboard.string(forType: .string) {
            bridge.submitClipboardText(text)
        }
    }

    let gfxActive = bridge.isGfxActive() && !bitmapOnly
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
        needsKeyframe = false
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
            if let encoded = try await encoder.encode(frame, timestampMs: timestampMs, forceKeyframe: needsKeyframe) {
                let delivered = bridge.submitH264(encoded, regionWidth: frame.width, regionHeight: frame.height)
                needsKeyframe = !delivered
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
