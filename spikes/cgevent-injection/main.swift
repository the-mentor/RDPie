// Probe: does CGEventPost actually inject synthetic keyboard/mouse events
// system-wide from a raw CLI binary, and what does the Accessibility grant
// flow look like for that binary's identity?
// Build: swiftc -o cgevent-probe main.swift -framework ApplicationServices
import ApplicationServices
import Foundation

print("AXIsProcessTrusted(): \(AXIsProcessTrusted())")

if !AXIsProcessTrusted() {
    // AXIsProcessTrustedWithOptions with the prompt key shows the system
    // "add to Accessibility" prompt/adds this binary to the list — but only
    // takes effect on next launch, same pattern as Screen Recording in
    // spikes/locked-capture.
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    print("AXIsProcessTrustedWithOptions(prompt: true): \(trusted)")
    print("Grant Accessibility access in System Settings, then re-run.")
    exit(1)
}

print("Trusted. Waiting 5s, then posting a synthetic 'A' keypress (scancode 0x00, kVK_ANSI_A) system-wide.")
print("Focus a text field (e.g. TextEdit or this terminal) to observe whether 'a' actually appears.")
try? await Task.sleep(nanoseconds: 5_000_000_000)

guard let source = CGEventSource(stateID: .hidSystemState) else {
    print("CGEventSource creation failed")
    exit(1)
}

// kVK_ANSI_A = 0x00
let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: true)
let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: false)

keyDown?.post(tap: .cghidEventTap)
keyUp?.post(tap: .cghidEventTap)

print("Posted keyDown+keyUp for 'A'. Check whether it appeared wherever focus was.")

// Also probe mouse move, since RDP mouse events need CGEventPost too.
// Verify programmatically by reading the cursor position back, rather than
// relying on a human spotting a small jump.
func currentCursorLocation() -> CGPoint? {
    CGEvent(source: nil)?.location
}

print("Cursor location before move: \(String(describing: currentCursorLocation()))")
print("Waiting 2s, then moving the mouse cursor to (600, 400).")
try? await Task.sleep(nanoseconds: 2_000_000_000)
let target = CGPoint(x: 600, y: 400)
let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)
moveEvent?.post(tap: .cghidEventTap)

try? await Task.sleep(nanoseconds: 200_000_000)
let after = currentCursorLocation()
print("Cursor location after move: \(String(describing: after))")
if let after, abs(after.x - target.x) < 2, abs(after.y - target.y) < 2 {
    print("MOUSE MOVE CONFIRMED: cursor position matches the posted target.")
} else {
    print("MOUSE MOVE NOT CONFIRMED: cursor position does not match the target.")
}
