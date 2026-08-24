// spikes/locked-capture/main.swift
// Build: swiftc -o locked-capture main.swift -framework ScreenCaptureKit -framework CoreMedia
import ScreenCaptureKit
import CoreMedia
import Foundation

final class Probe: NSObject, SCStreamOutput {
    var frameCount = 0
    var lastLog = Date()

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // A frame with no image buffer is a "no change" heartbeat, not a real frame.
        guard CMSampleBufferGetImageBuffer(sb) != nil else { return }
        frameCount += 1
        if Date().timeIntervalSince(lastLog) >= 1.0 {
            let stamp = ISO8601DateFormatter().string(from: Date())
            print("[\(stamp)] frames in last interval: \(frameCount)")
            frameCount = 0
            lastLog = Date()
        }
    }
}

let probe = Probe()
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
guard let display = content.displays.first else { fatalError("no display") }

let filter = SCContentFilter(display: display, excludingWindows: [])
let config = SCStreamConfiguration()
config.width = display.width
config.height = display.height
config.minimumFrameInterval = CMTime(value: 1, timescale: 10)  // 10 fps is plenty to observe

let stream = SCStream(filter: filter, configuration: config, delegate: nil)
try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: .global())
try await stream.startCapture()
print("capturing — now lock the screen with Ctrl-Cmd-Q and watch the counts")
try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
try await stream.stopCapture()
