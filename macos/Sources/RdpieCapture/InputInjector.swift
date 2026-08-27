import Foundation
import ApplicationServices // AXIsProcessTrusted + CGEvent; re-exports CoreGraphics,
                            // matching spikes/cgevent-injection/main.swift's import list
import CRdpieCore

/// Turns one `RdpieInputEvent` from the Rust core into a real, system-wide
/// `CGEvent`. The only file in this target that touches `CGEvent`/
/// `ApplicationServices` — see the plan's File Structure rationale.
///
/// One `InputInjector` is owned by `RustBridge` (Task 6) for the life of
/// the process. Calls into a given instance are strictly serialized by
/// upstream's own `Arc<tokio::sync::Mutex<handler>>` around the AINPUT
/// dynamic channel handler (not necessarily from one fixed thread — the
/// handler is invoked via `task::spawn_blocking`, i.e. a tokio
/// blocking-pool thread that can vary call to call) — so there is never
/// more than one in-flight call into a given instance, and
/// `droppedEventCount` needs no synchronization for that reason.
public final class InputInjector {

    /// Counts every event this injector dropped instead of posting —
    /// Accessibility not granted, an unmapped scancode, or `CGEvent`
    /// construction itself returning `nil`. Mirrors `RustBridge
    /// .droppedFrames`: a plain counter is enough to notice drops are
    /// happening at all; per-drop diagnostics already go to stderr below.
    public private(set) var droppedEventCount = 0

    private let source = CGEventSource(stateID: .hidSystemState)

    /// The RDP desktop's configured size (`macos/Sources/rdpied/main.swift`'s
    /// `width`/`height`) — `MouseMove` coordinates arrive in this space and
    /// must be scaled into the main display's point space before becoming a
    /// `CGPoint`. See `scaledCursorPosition`.
    private let desktopWidth: Int
    private let desktopHeight: Int

    private let hasAccessibility: () -> Bool
    private let post: (CGEvent?) -> Void

    /// The mouse button currently held, if any -- set on a `*Pressed` event,
    /// cleared on the matching `*Released` event. `MouseMove` consults this
    /// to post a `*Dragged` `CGEventType` instead of a plain `.mouseMoved`:
    /// macOS drag gestures (text selection, window dragging, canvas tools)
    /// key off the event's *type* being one of the Dragged variants, not off
    /// a button separately being down, so a held-button move posted as
    /// `.mouseMoved` is invisible to them as a drag.
    private var heldButton: CGMouseButton?

    /// - Parameters:
    ///   - width/height: the configured RDP desktop size, in the same space
    ///     `RdpieInputEvent.x`/`.y` arrive in. Defaults match `main.swift`'s
    ///     hardcoded 1280x720 so `RustBridge.swift`'s existing no-argument
    ///     `InputInjector()` call site keeps working unchanged; real usage
    ///     should pass the actual configured size (see `RustBridge.start`).
    ///   - hasAccessibility: injectable Accessibility gate, so tests can get
    ///     past it without a live trusted process. Defaults to the real
    ///     `AXIsProcessTrusted()`-backed check.
    ///   - post: injectable event sink, so tests can observe what would
    ///     have been posted without actually injecting live input. Defaults
    ///     to the real `CGEvent.post(tap: .cghidEventTap)`.
    public init(width: Int = 1280, height: Int = 720,
                hasAccessibility: @escaping () -> Bool = { InputInjector.hasAccessibilityPermission() },
                post: @escaping (CGEvent?) -> Void = { $0?.post(tap: .cghidEventTap) }) {
        self.desktopWidth = width
        self.desktopHeight = height
        self.hasAccessibility = hasAccessibility
        self.post = post
    }

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
        guard hasAccessibility() else {
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
            let position = scaledCursorPosition(event)
            if let heldButton {
                dispatch(CGEvent(mouseEventSource: source, mouseType: Self.dragEventType(for: heldButton),
                                  mouseCursorPosition: position, mouseButton: heldButton))
            } else {
                dispatch(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: position, mouseButton: .left))
            }
        case MouseLeftPressed:
            heldButton = .left
            dispatch(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                              mouseCursorPosition: currentCursorLocation(), mouseButton: .left))
        case MouseLeftReleased:
            heldButton = nil
            dispatch(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                              mouseCursorPosition: currentCursorLocation(), mouseButton: .left))
        case MouseRightPressed:
            heldButton = .right
            dispatch(CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                              mouseCursorPosition: currentCursorLocation(), mouseButton: .right))
        case MouseRightReleased:
            heldButton = nil
            dispatch(CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                              mouseCursorPosition: currentCursorLocation(), mouseButton: .right))
        case MouseMiddlePressed:
            heldButton = .center
            dispatch(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                              mouseCursorPosition: currentCursorLocation(), mouseButton: .center))
        case MouseMiddleReleased:
            heldButton = nil
            dispatch(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                              mouseCursorPosition: currentCursorLocation(), mouseButton: .center))
        case MouseButton4Pressed:
            heldButton = Self.button4
            dispatch(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                              mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button4))
        case MouseButton4Released:
            heldButton = nil
            dispatch(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                              mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button4))
        case MouseButton5Pressed:
            heldButton = Self.button5
            dispatch(CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                              mouseCursorPosition: currentCursorLocation(), mouseButton: Self.button5))
        case MouseButton5Released:
            heldButton = nil
            dispatch(CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
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
            dispatch(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
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
                Data("InputInjector: unrecognized RdpieInputEventKind — dropping\n".utf8))
            droppedEventCount += 1
        }
    }

    private static let button4 = CGMouseButton(rawValue: 3)!
    private static let button5 = CGMouseButton(rawValue: 4)!

    /// `CGMouseButton` only names `.left`/`.right`/`.center` -- button4/5
    /// fall through to `.otherMouseDragged` alongside the middle button,
    /// same as their non-drag `.otherMouseDown`/`Up` handling above.
    private static func dragEventType(for button: CGMouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        default: return .otherMouseDragged
        }
    }

    private func postKey(_ event: RdpieInputEvent, keyDown: Bool) {
        guard let keyCode = ScancodeMap.lookup(scancode: event.scancode, extended: event.extended) else {
            FileHandle.standardError.write(
                Data("InputInjector: no CGKeyCode for scancode 0x\(String(event.scancode, radix: 16)) (extended: \(event.extended)) — dropping\n".utf8))
            droppedEventCount += 1
            return
        }
        dispatch(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown))
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

    /// Scales an `RdpieInputEvent`'s `x`/`y` (in the configured RDP desktop's
    /// coordinate space — see `desktopWidth`/`desktopHeight`) into the main
    /// display's global point space, which is what `CGEvent`'s
    /// `mouseCursorPosition` actually expects. Single-display only, matching
    /// this whole phase's scope — no multi-monitor mapping.
    ///
    /// Y already increases downward in both RDP and macOS's global display
    /// space, so no flip is needed, only a scale.
    private func scaledCursorPosition(_ event: RdpieInputEvent) -> CGPoint {
        Self.scale(x: event.x, y: event.y,
                    desktopWidth: desktopWidth, desktopHeight: desktopHeight,
                    displayBounds: CGDisplayBounds(CGMainDisplayID()))
    }

    /// Pure scaling math, factored out of `scaledCursorPosition` so it's
    /// testable without a live `CGDisplayBounds(CGMainDisplayID())` call —
    /// tests pass a stand-in `displayBounds` instead.
    static func scale(x: UInt16, y: UInt16, desktopWidth: Int, desktopHeight: Int,
                       displayBounds: CGRect) -> CGPoint {
        let scaledX = CGFloat(x) * (displayBounds.width / CGFloat(desktopWidth))
        let scaledY = CGFloat(y) * (displayBounds.height / CGFloat(desktopHeight))
        return CGPoint(x: scaledX, y: scaledY)
    }

    private func dispatch(_ event: CGEvent?) {
        guard let event else {
            droppedEventCount += 1
            return
        }
        post(event)
    }
}
