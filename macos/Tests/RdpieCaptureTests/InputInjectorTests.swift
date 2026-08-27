import XCTest
import ApplicationServices // CGEvent/CGEventType/CGPoint/CGRect — same import InputInjector.swift uses
import Carbon.HIToolbox // kVK_* modifier key code constants only
import CRdpieCore
@testable import RdpieCapture

final class InputInjectorTests: XCTestCase {

    // Every kind the fixed FFI contract defines. Listed explicitly (not
    // derived by reflection) so this test breaks, loudly, if a case is ever
    // added here without a matching one in `InputInjector.handle`.
    private let allKinds: [RdpieInputEventKind] = [
        KeyPressed,
        KeyReleased,
        MouseMove,
        MouseLeftPressed,
        MouseLeftReleased,
        MouseRightPressed,
        MouseRightReleased,
        MouseMiddlePressed,
        MouseMiddleReleased,
        MouseButton4Pressed,
        MouseButton4Released,
        MouseButton5Pressed,
        MouseButton5Released,
        MouseVerticalScroll,
        ReleaseAllModifiers,
    ]

    private func sampleEvent(kind: RdpieInputEventKind) -> RdpieInputEvent {
        // Field values only need to be well-formed enough not to trap
        // (a mapped scancode, in-range coordinates) — this suite never
        // reaches the point of inspecting the posted event's content.
        RdpieInputEvent(kind: kind, scancode: 0x1E /* kVK_ANSI_A */,
                         extended: false, x: 100, y: 100, scroll_delta: 120)
    }

    func testHasAccessibilityPermissionReturnsWithoutCrashing() {
        // Never trusted in a CI/sandboxed test runner — this only proves
        // the call is safe to make and returns a Bool, not any particular
        // value. Do not assert `== false` here: an interactively-run local
        // test suite on an already-trusted terminal would fail spuriously.
        _ = InputInjector.hasAccessibilityPermission()
    }

    func testHandleDropsEveryKindWhenAccessibilityNotGranted() throws {
        try XCTSkipIf(
            InputInjector.hasAccessibilityPermission(),
            "This runner is Accessibility-trusted; the drop path can't be "
                + "exercised here. Live CGEventPost verification is a later task.")

        let injector = InputInjector()
        XCTAssertEqual(injector.droppedEventCount, 0)

        for (index, kind) in allKinds.enumerated() {
            injector.handle(sampleEvent(kind: kind))
            XCTAssertEqual(
                injector.droppedEventCount, index + 1,
                "kind at index \(index) should have been dropped exactly once")
        }
    }

    /// Deterministic counterpart to the test above, using the injected
    /// `hasAccessibility` seam instead of relying on the runner's real
    /// trust state — exercises the same drop path unconditionally, on any
    /// runner.
    func testHandleDropsEveryKindWhenAccessibilityGateReturnsFalse() {
        let injector = InputInjector(hasAccessibility: { false })
        XCTAssertEqual(injector.droppedEventCount, 0)

        for (index, kind) in allKinds.enumerated() {
            injector.handle(sampleEvent(kind: kind))
            XCTAssertEqual(
                injector.droppedEventCount, index + 1,
                "kind at index \(index) should have been dropped exactly once")
        }
    }

    // MARK: - Coordinate scaling (RDP desktop space -> display point space)

    func testScaleMapsDesktopCoordinatesIntoDisplayPointSpace() {
        // A 2560x1080 display is exactly 2x a 1280x720 desktop on X and
        // 1.5x on Y — deliberately non-uniform so a bug that swaps the two
        // axes' scale factors would be caught.
        let displayBounds = CGRect(x: 0, y: 0, width: 2560, height: 1080)
        let point = InputInjector.scale(
            x: 640, y: 360, desktopWidth: 1280, desktopHeight: 720, displayBounds: displayBounds)
        XCTAssertEqual(point.x, 1280, accuracy: 0.001)
        XCTAssertEqual(point.y, 540, accuracy: 0.001)
    }

    func testScaleIsIdentityWhenDesktopMatchesDisplay() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let point = InputInjector.scale(
            x: 100, y: 200, desktopWidth: 1280, desktopHeight: 720, displayBounds: displayBounds)
        XCTAssertEqual(point.x, 100, accuracy: 0.001)
        XCTAssertEqual(point.y, 200, accuracy: 0.001)
    }

    // MARK: - Dispatch routing (Accessibility faked granted via injected seam)

    private func recordingInjector() -> (InputInjector, () -> [CGEvent]) {
        var posted: [CGEvent] = []
        let injector = InputInjector(hasAccessibility: { true }, post: { event in
            if let event { posted.append(event) }
        })
        return (injector, { posted })
    }

    func testMouseMoveDispatchesAMouseMovedEvent() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: MouseMove, scancode: 0, extended: false, x: 100, y: 100, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.mouseMoved])
        XCTAssertEqual(injector.droppedEventCount, 0)
    }

    func testMouseMoveWhileLeftButtonHeldDispatchesALeftMouseDraggedEvent() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: MouseLeftPressed, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 0))
        injector.handle(RdpieInputEvent(kind: MouseMove, scancode: 0, extended: false, x: 100, y: 100, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.leftMouseDown, .leftMouseDragged])
    }

    func testMouseMoveAfterLeftButtonReleasedGoesBackToPlainMouseMoved() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: MouseLeftPressed, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 0))
        injector.handle(RdpieInputEvent(kind: MouseLeftReleased, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 0))
        injector.handle(RdpieInputEvent(kind: MouseMove, scancode: 0, extended: false, x: 100, y: 100, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.leftMouseDown, .leftMouseUp, .mouseMoved])
    }

    func testMouseMoveWhileRightButtonHeldDispatchesARightMouseDraggedEvent() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: MouseRightPressed, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 0))
        injector.handle(RdpieInputEvent(kind: MouseMove, scancode: 0, extended: false, x: 100, y: 100, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.rightMouseDown, .rightMouseDragged])
    }

    func testMouseMoveWhileMiddleButtonHeldDispatchesAnOtherMouseDraggedEvent() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: MouseMiddlePressed, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 0))
        injector.handle(RdpieInputEvent(kind: MouseMove, scancode: 0, extended: false, x: 100, y: 100, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.otherMouseDown, .otherMouseDragged])
    }

    func testKeyPressedDispatchesAKeyDownEventForTheMappedScancode() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: KeyPressed, scancode: 0x1E /* kVK_ANSI_A */, extended: false, x: 0, y: 0, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.keyDown])
        XCTAssertEqual(posted().first?.getIntegerValueField(.keyboardEventKeycode), 0x00)
    }

    func testKeyReleasedDispatchesAKeyUpEvent() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: KeyReleased, scancode: 0x1E, extended: false, x: 0, y: 0, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.keyUp])
    }

    func testMouseRightPressedDispatchesARightMouseDownEvent() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: MouseRightPressed, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.rightMouseDown])
    }

    func testMouseMiddlePressedDispatchesAnOtherMouseDownEventWithButtonNumberTwo() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: MouseMiddlePressed, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.otherMouseDown])
        XCTAssertEqual(posted().first?.getIntegerValueField(.mouseEventButtonNumber), 2)
    }

    func testMouseButton4PressedUsesButtonNumberThree() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: MouseButton4Pressed, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 0))
        XCTAssertEqual(posted().map(\.type), [.otherMouseDown])
        XCTAssertEqual(posted().first?.getIntegerValueField(.mouseEventButtonNumber), 3)
    }

    func testReleaseAllModifiersDispatchesAKeyUpForEveryModifierKey() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: ReleaseAllModifiers, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 0))

        let events = posted()
        XCTAssertEqual(events.count, 8)
        // Modifier keys report as `.flagsChanged`, not `.keyUp`/`.keyDown`,
        // regardless of the `keyDown:` argument used to construct them --
        // confirmed against a live `CGEvent(keyboardEventSource:...)` call,
        // not assumed.
        XCTAssertTrue(events.allSatisfy { $0.type == .flagsChanged })
        let keyCodes = Set(events.map { $0.getIntegerValueField(.keyboardEventKeycode) })
        let expectedKeyCodes: Set<Int64> = [
            Int64(kVK_Control), Int64(kVK_RightControl),
            Int64(kVK_Shift), Int64(kVK_RightShift),
            Int64(kVK_Command), Int64(kVK_RightCommand),
            Int64(kVK_Option), Int64(kVK_RightOption),
        ]
        XCTAssertEqual(keyCodes, expectedKeyCodes)
    }

    func testMouseVerticalScrollDispatchesAScrollWheelEvent() {
        let (injector, posted) = recordingInjector()
        injector.handle(RdpieInputEvent(kind: MouseVerticalScroll, scancode: 0, extended: false, x: 0, y: 0, scroll_delta: 120))
        XCTAssertEqual(posted().map(\.type), [.scrollWheel])
    }

    // MARK: - Unmapped scancode drop path

    func testUnmappedScancodeIncrementsDroppedEventCountWithoutPosting() {
        let (injector, posted) = recordingInjector()
        // 0x45 is NumLock — deliberately unmapped, see ScancodeMapTests.
        injector.handle(RdpieInputEvent(kind: KeyPressed, scancode: 0x45, extended: false, x: 0, y: 0, scroll_delta: 0))
        XCTAssertEqual(injector.droppedEventCount, 1)
        XCTAssertTrue(posted().isEmpty)
    }
}
