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
print("Waiting 2s, then moving the mouse cursor to (100, 100).")
try? await Task.sleep(nanoseconds: 2_000_000_000)
let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 100, y: 100), mouseButton: .left)
moveEvent?.post(tap: .cghidEventTap)
print("Posted a mouse-move event to (100, 100). Check whether the cursor actually moved.")
