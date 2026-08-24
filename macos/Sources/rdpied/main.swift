// macos/Sources/rdpied/main.swift
import Foundation
import RdpieCapture

// Phase 1: configuration is environment-driven. The menu-bar app and Keychain
// storage arrive in Phase 7; hardcoding a credential here would be a security
// regression, so an explicit password is required.
guard let password = ProcessInfo.processInfo.environment["RDPIE_PASSWORD"], !password.isEmpty else {
    FileHandle.standardError.write("RDPIE_PASSWORD must be set\n".data(using: .utf8)!)
    exit(2)
}
let username = ProcessInfo.processInfo.environment["RDPIE_USERNAME"] ?? "rdpie"
let useSynthetic = ProcessInfo.processInfo.environment["RDPIE_SYNTHETIC"] == "1"
let certPath = ProcessInfo.processInfo.environment["RDPIE_CERT"] ?? "./cert.pem"
let keyPath = ProcessInfo.processInfo.environment["RDPIE_KEY"] ?? "./key.pem"

let width = 1280, height = 720

let source: CaptureSource = useSynthetic ? SyntheticCaptureSource() : ScreenCaptureKitSource()

if !useSynthetic && !ScreenCaptureKitSource.hasPermission() {
    FileHandle.standardError.write(
        "Screen Recording permission is required. Grant it in System Settings › Privacy & Security › Screen Recording, then run again.\n"
            .data(using: .utf8)!)
    exit(3)
}

let bridge = RustBridge()
try bridge.start(port: 3389, width: width, height: height,
                 username: username, password: password,
                 certPath: certPath, keyPath: keyPath)

try source.start(configuration: CaptureConfiguration(
    width: width, height: height, framesPerSecond: 30))

signal(SIGINT) { _ in exit(0) }
print("rdpied listening on 127.0.0.1:3389 — connect with an RDP client")

var h264Encoder: H264Encoder?
var wasGfxActive = false
let encoderClockStart = DispatchTime.now()

for await frame in source.frames {
    let gfxActive = bridge.isGfxActive()
    if gfxActive && !wasGfxActive {
        // A fresh EGFX channel (first connection, or a reconnect) means the
        // client's decoder has no state. Discard the encoder so the next
        // frame lazily creates a new `VTCompressionSession`, whose first
        // output is always a keyframe carrying SPS/PPS — resuming the old
        // session would emit a P-frame the new client can't decode.
        h264Encoder = nil
    }
    wasGfxActive = gfxActive

    if gfxActive {
        let encoder: H264Encoder
        if let existing = h264Encoder {
            encoder = existing
        } else {
            do {
                encoder = try H264Encoder(width: width, height: height)
                h264Encoder = encoder
            } catch {
                FileHandle.standardError.write("H264Encoder creation failed: \(error)\n".data(using: .utf8)!)
                bridge.submit(frame)
                continue
            }
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
