import XCTest
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
}
