// macos/Tests/RdpieCaptureTests/ScancodeMapTests.swift
import XCTest
@testable import RdpieCapture

final class ScancodeMapTests: XCTestCase {

    func testPlainLetterA() {
        // Set 1 scancode 0x1E is the physical 'A' key -> kVK_ANSI_A (0x00).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x1E, extended: false), 0x00)
    }

    func testDigit1() {
        // Set 1 scancode 0x02 is the physical '1' key -> kVK_ANSI_1 (0x12).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x02, extended: false), 0x12)
    }

    func testExtendedLeftArrow() {
        // E0 0x4B is the Left Arrow -> kVK_LeftArrow (0x7B).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x4B, extended: true), 0x7B)
    }

    func testExtendedRightControl() {
        // E0 0x1D is Right Control -> kVK_RightControl (0x3E). Same base
        // scancode as non-extended 0x1D (Left Control, kVK_Control = 0x3B) —
        // this is the case most likely to get the `extended` flag backwards.
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x1D, extended: true), 0x3E)
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x1D, extended: false), 0x3B)
        XCTAssertNotEqual(
            ScancodeMap.lookup(scancode: 0x1D, extended: false),
            ScancodeMap.lookup(scancode: 0x1D, extended: true))
    }

    func testFunctionKeyF5() {
        // Set 1 scancode 0x3F is F5 -> kVK_F5 (0x60).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x3F, extended: false), 0x60)
    }

    func testUnmappedScancodeReturnsNil() {
        // 0x00 is never assigned in PC/AT Set 1 (scancodes start at 0x01) —
        // a genuinely reserved code, distinct from NumLock/ScrollLock/Insert
        // below, which are real Set 1 codes this table deliberately omits.
        XCTAssertNil(ScancodeMap.lookup(scancode: 0x00, extended: false))
    }

    func testDeliberatelyUnmappedKeysReturnNil() {
        // NumLock (0x45) and ScrollLock (0x46): no physical or virtual
        // equivalent on any modern Mac keyboard — mapping them to something
        // adjacent (e.g. kVK_ANSI_KeypadClear for NumLock) would silently
        // reinterpret a lock-key toggle as an unrelated keypress. Left
        // unmapped rather than guessed; the RDP `Synchronize` PDU that would
        // actually carry lock-key state is out of scope for this phase.
        XCTAssertNil(ScancodeMap.lookup(scancode: 0x45, extended: false))
        XCTAssertNil(ScancodeMap.lookup(scancode: 0x46, extended: false))
        // Insert (E0 0x52): the closest Apple Extended Keyboard correspondence
        // is kVK_Help (0x72), but that key opens macOS Help, a different
        // semantic action from an editor's insert-mode toggle — not a safe
        // guess to bake into a lookup table silently. Left unmapped.
        XCTAssertNil(ScancodeMap.lookup(scancode: 0x52, extended: true))
        // Apps/menu key (E0 0x5D): no macOS equivalent — there is no
        // "context menu" virtual key on any Mac keyboard layout. Left
        // unmapped rather than guessed.
        XCTAssertNil(ScancodeMap.lookup(scancode: 0x5D, extended: true))
    }

    func testLeftCommandKey() {
        // E0 0x5B is the Left Windows key -> kVK_Command (0x37).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x5B, extended: true), 0x37)
    }

    func testRightCommandKey() {
        // E0 0x5C is the Right Windows key -> kVK_RightCommand (0x36).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x5C, extended: true), 0x36)
    }

    func testISOExtraKey() {
        // Set 1 scancode 0x56 is the ISO extra key (between Left Shift and
        // Z on non-US layouts) -> kVK_ISO_Section (0x0A).
        XCTAssertEqual(ScancodeMap.lookup(scancode: 0x56, extended: false), 0x0A)
    }
}
