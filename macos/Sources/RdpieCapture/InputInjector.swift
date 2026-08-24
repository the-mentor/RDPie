import Foundation
import ApplicationServices // AXIsProcessTrusted + CGEvent; re-exports CoreGraphics,
                            // matching spikes/cgevent-injection/main.swift's import list
import CRdpieCore

/// Turns one `RdpieInputEvent` from the Rust core into a real, system-wide
/// `CGEvent`. The only file in this target that touches `CGEvent`/
/// `ApplicationServices` — see the plan's File Structure rationale.
///
/// One `InputInjector` is owned by `RustBridge` (Task 6) for the life of
/// the process and is called synchronously, serially, from the Rust core's
/// single dedicated per-connection thread (see this plan's Global
/// Constraints) — there is never more than one in-flight call into a given
/// instance, so `droppedEventCount` needs no synchronization.
public final class InputInjector {

    /// Counts every event this injector dropped instead of posting —
    /// Accessibility not granted, an unmapped scancode, or `CGEvent`
    /// construction itself returning `nil`. Mirrors `RustBridge
    /// .droppedFrames`: a plain counter is enough to notice drops are
    /// happening at all; per-drop diagnostics already go to stderr below.
    public private(set) var droppedEventCount = 0

    private let source = CGEventSource(stateID: .hidSystemState)

    public init() {}

    /// Confirmed by `spikes/cgevent-injection/RESULTS.md` to be exactly the
    /// gate `CGEventPost` needs, with no extra entitlement, from a plain
    /// (even unsigned) binary — this call mirrors that spike's usage
    /// verbatim.
    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// `AXIsProcessTrustedWithOptions(prompt: true)` — same spike. Only
    /// takes effect on next launch, the same one-shot-prompt pattern
    /// `ScreenCaptureKitSource`'s Screen Recording grant flow already uses.
    public static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Called from Task 6's `@convention(c)` callback with one already-
    /// copied event value (`event.pointee`, not the raw pointer) — the FFI
    /// contract's "valid only for the call's duration" note is Task 6's
    /// concern to satisfy before this method ever sees the value, so
    /// nothing here needs to reason about pointer lifetime.
    public func handle(_ event: RdpieInputEvent) {
        guard Self.hasAccessibilityPermission() else {
            // Global Constraint: clients before Accessibility is granted,
            // and Accessibility revoked mid-session, must not crash the
            // connection — drop the event, don't error the session.
            droppedEventCount += 1
            return
        }

        switch event.kind {
        case KeyPressed:
            postKey(event, keyDown: true)
        case KeyReleased:
            postKey(event, keyDown: false)
        case MouseMove:
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                          mouseCursorPosition: CGPoint(x: Int(event.x), y: Int(event.y)),
                          mouseButton: .left))
        case MouseLeftPressed:
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .left))
        case MouseLeftReleased:
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .left))
        case MouseRightPressed:
            post(CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .right))
        case MouseRightReleased:
            post(CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .right))
        case MouseMiddlePressed:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .center))
        case MouseMiddleReleased:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: .center))
        case MouseButton4Pressed:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button4))
        case MouseButton4Released:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button4))
        case MouseButton5Pressed:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button5))
        case MouseButton5Released:
            post(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                          mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button5))
        case MouseVerticalScroll:
            // `CGMouseButton` only declares 3 named cases (left/right/center
            // = 0/1/2) — there is no `CGEventType` case for a 4th/5th
            // button either, only the generic `.otherMouseDown`/`Up` used
            // above for the middle button too, disambiguated by which
            // `CGMouseButton` raw value is passed. Verified live during
            // this plan's drafting: `CGMouseButton(rawValue: 3)` and
            // `(rawValue: 4)` both compile and construct successfully
            // (this initializer never actually fails for an in-range
            // `UInt32`, despite being spelled as failable) — matches the
            // documented technique other CGEvent-based automation tools use
            // for buttons beyond the first three.
            //
            // ponytail: RDP's wheel delta (~+-120 per notch, Windows
            // WHEEL_DELTA-scaled) is passed through unchanged per the FFI
            // contract's "do not renormalize" note. `.pixel` units keep
            // that magnitude closer to sane than `.line` units would (which
            // reads the same 120 as 120 *lines* per notch — a much larger
            // distortion). Revisit the unit choice if live client testing
            // shows scroll feels wrong; the contract forbids rescaling the
            // value itself, not picking a different `CGScrollEventUnit`.
            post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                          wheel1: Int32(event.scroll_delta), wheel2: 0, wheel3: 0))
        default:
            // Reachable only if the Rust core ever adds a new
            // `RdpieInputEventKind` case without a matching branch above —
            // cbindgen emits this as a plain C enum, which Swift imports as
            // an open, non-frozen type, so the compiler requires this
            // branch even though every currently-defined case is handled
            // explicitly above. Not a silent catch-all: it logs and drops,
            // same as every other drop path in this method.
            FileHandle.standardError.write(
                "InputInjector: unrecognized RdpieInputEventKind — dropping\n"
                    .data(using: .utf8)!)
            droppedEventCount += 1
        }
    }

    private static let button4 = CGMouseButton(rawValue: 3)!
    private static let button5 = CGMouseButton(rawValue: 4)!

    private func postKey(_ event: RdpieInputEvent, keyDown: Bool) {
        guard let keyCode = ScancodeMap.lookup(scancode: event.scancode, extended: event.extended) else {
            FileHandle.standardError.write(
                "InputInjector: no CGKeyCode for scancode 0x\(String(event.scancode, radix: 16)) (extended: \(event.extended)) — dropping\n"
                    .data(using: .utf8)!)
            droppedEventCount += 1
            return
        }
        post(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown))
    }

    /// Button press/release events carry no coordinates on the wire (`x`/`y`
    /// are documented as meaningful for `MouseMove` only) — RDP always
    /// sends a `Move` to position the cursor before a click. Reading the
    /// live cursor position back is the same technique
    /// `spikes/cgevent-injection/main.swift` used to confirm a posted move
    /// landed; reusing it here avoids this class tracking cursor state of
    /// its own.
    private func currentCursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func post(_ event: CGEvent?) {
        guard let event else {
            droppedEventCount += 1
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
