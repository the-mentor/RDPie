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

for await frame in source.frames {
    bridge.submit(frame)
}

source.stop()
bridge.stop()
