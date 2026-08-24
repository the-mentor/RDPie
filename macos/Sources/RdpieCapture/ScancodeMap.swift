import CoreGraphics    // CGKeyCode typealias only (CGRemoteOperation.h)
import Carbon.HIToolbox // kVK_* constants only — no CGEvent API in this header

/// One PC/AT Set 1 scancode, keyed the same way `RdpieInputEvent` carries
/// it on the wire: a base scancode plus the RDP extended-key (`E0`-prefix)
/// flag. Several keys (Left/Right Control, the arrow keys vs. the numeric
/// keypad, KeypadEnter vs. Return) share a base scancode and are only
/// distinguished by this flag — it must be part of the lookup key, not an
/// afterthought.
public struct ScancodeKey: Hashable {
    public let scancode: UInt8
    public let extended: Bool

    public init(scancode: UInt8, extended: Bool) {
        self.scancode = scancode
        self.extended = extended
    }
}

/// RDP's PC/AT Set 1 keyboard scancode -> macOS `CGKeyCode` virtual
/// keycode. Pure data, no `CGEvent`/`ApplicationServices` dependency — see
/// the plan's File Structure rationale (mirrors `H264NALConverter.swift`
/// staying free of `VideoToolbox`).
///
/// The Set 1 half of this table is the standard, widely-documented PC/AT
/// scancode layout. The macOS half was read directly from
/// `Carbon.framework`'s `HIToolbox.framework/Headers/Events.h` (see Task 4
/// Step 1's grep) — not from memory. Keys with no confident macOS
/// equivalent (NumLock, ScrollLock, Insert, the Apps/menu key — see
/// `ScancodeMapTests.testDeliberatelyUnmappedKeysReturnNil`) are left out of
/// the table entirely; `lookup` returns `nil` for them, and the caller
/// (Task 5's `InputInjector`) drops the event rather than injecting a
/// guessed key.
public enum ScancodeMap {

    public static func lookup(scancode: UInt8, extended: Bool) -> CGKeyCode? {
        table[ScancodeKey(scancode: scancode, extended: extended)]
    }

    private static let table: [ScancodeKey: CGKeyCode] = [
        // Row 1: Escape, digits, Minus/Equals, Backspace
        ScancodeKey(scancode: 0x01, extended: false): CGKeyCode(kVK_Escape),
        ScancodeKey(scancode: 0x02, extended: false): CGKeyCode(kVK_ANSI_1),
        ScancodeKey(scancode: 0x03, extended: false): CGKeyCode(kVK_ANSI_2),
        ScancodeKey(scancode: 0x04, extended: false): CGKeyCode(kVK_ANSI_3),
        ScancodeKey(scancode: 0x05, extended: false): CGKeyCode(kVK_ANSI_4),
        ScancodeKey(scancode: 0x06, extended: false): CGKeyCode(kVK_ANSI_5),
        ScancodeKey(scancode: 0x07, extended: false): CGKeyCode(kVK_ANSI_6),
        ScancodeKey(scancode: 0x08, extended: false): CGKeyCode(kVK_ANSI_7),
        ScancodeKey(scancode: 0x09, extended: false): CGKeyCode(kVK_ANSI_8),
        ScancodeKey(scancode: 0x0A, extended: false): CGKeyCode(kVK_ANSI_9),
        ScancodeKey(scancode: 0x0B, extended: false): CGKeyCode(kVK_ANSI_0),
        ScancodeKey(scancode: 0x0C, extended: false): CGKeyCode(kVK_ANSI_Minus),
        ScancodeKey(scancode: 0x0D, extended: false): CGKeyCode(kVK_ANSI_Equal),
        ScancodeKey(scancode: 0x0E, extended: false): CGKeyCode(kVK_Delete), // Backspace

        // Row 2: Tab, Q-P row, brackets, Enter
        ScancodeKey(scancode: 0x0F, extended: false): CGKeyCode(kVK_Tab),
        ScancodeKey(scancode: 0x10, extended: false): CGKeyCode(kVK_ANSI_Q),
        ScancodeKey(scancode: 0x11, extended: false): CGKeyCode(kVK_ANSI_W),
        ScancodeKey(scancode: 0x12, extended: false): CGKeyCode(kVK_ANSI_E),
        ScancodeKey(scancode: 0x13, extended: false): CGKeyCode(kVK_ANSI_R),
        ScancodeKey(scancode: 0x14, extended: false): CGKeyCode(kVK_ANSI_T),
        ScancodeKey(scancode: 0x15, extended: false): CGKeyCode(kVK_ANSI_Y),
        ScancodeKey(scancode: 0x16, extended: false): CGKeyCode(kVK_ANSI_U),
        ScancodeKey(scancode: 0x17, extended: false): CGKeyCode(kVK_ANSI_I),
        ScancodeKey(scancode: 0x18, extended: false): CGKeyCode(kVK_ANSI_O),
        ScancodeKey(scancode: 0x19, extended: false): CGKeyCode(kVK_ANSI_P),
        ScancodeKey(scancode: 0x1A, extended: false): CGKeyCode(kVK_ANSI_LeftBracket),
        ScancodeKey(scancode: 0x1B, extended: false): CGKeyCode(kVK_ANSI_RightBracket),
        ScancodeKey(scancode: 0x1C, extended: false): CGKeyCode(kVK_Return),

        // Row 3: Left Control, A-L row, quotes/grave, Left Shift
        ScancodeKey(scancode: 0x1D, extended: false): CGKeyCode(kVK_Control), // Left Control
        ScancodeKey(scancode: 0x1E, extended: false): CGKeyCode(kVK_ANSI_A),
        ScancodeKey(scancode: 0x1F, extended: false): CGKeyCode(kVK_ANSI_S),
        ScancodeKey(scancode: 0x20, extended: false): CGKeyCode(kVK_ANSI_D),
        ScancodeKey(scancode: 0x21, extended: false): CGKeyCode(kVK_ANSI_F),
        ScancodeKey(scancode: 0x22, extended: false): CGKeyCode(kVK_ANSI_G),
        ScancodeKey(scancode: 0x23, extended: false): CGKeyCode(kVK_ANSI_H),
        ScancodeKey(scancode: 0x24, extended: false): CGKeyCode(kVK_ANSI_J),
        ScancodeKey(scancode: 0x25, extended: false): CGKeyCode(kVK_ANSI_K),
        ScancodeKey(scancode: 0x26, extended: false): CGKeyCode(kVK_ANSI_L),
        ScancodeKey(scancode: 0x27, extended: false): CGKeyCode(kVK_ANSI_Semicolon),
        ScancodeKey(scancode: 0x28, extended: false): CGKeyCode(kVK_ANSI_Quote),
        ScancodeKey(scancode: 0x29, extended: false): CGKeyCode(kVK_ANSI_Grave),
        ScancodeKey(scancode: 0x2A, extended: false): CGKeyCode(kVK_Shift), // Left Shift

        // Row 4: Backslash, Z-M row, punctuation, Right Shift
        ScancodeKey(scancode: 0x2B, extended: false): CGKeyCode(kVK_ANSI_Backslash),
        ScancodeKey(scancode: 0x2C, extended: false): CGKeyCode(kVK_ANSI_Z),
        ScancodeKey(scancode: 0x2D, extended: false): CGKeyCode(kVK_ANSI_X),
        ScancodeKey(scancode: 0x2E, extended: false): CGKeyCode(kVK_ANSI_C),
        ScancodeKey(scancode: 0x2F, extended: false): CGKeyCode(kVK_ANSI_V),
        ScancodeKey(scancode: 0x30, extended: false): CGKeyCode(kVK_ANSI_B),
        ScancodeKey(scancode: 0x31, extended: false): CGKeyCode(kVK_ANSI_N),
        ScancodeKey(scancode: 0x32, extended: false): CGKeyCode(kVK_ANSI_M),
        ScancodeKey(scancode: 0x33, extended: false): CGKeyCode(kVK_ANSI_Comma),
        ScancodeKey(scancode: 0x34, extended: false): CGKeyCode(kVK_ANSI_Period),
        ScancodeKey(scancode: 0x35, extended: false): CGKeyCode(kVK_ANSI_Slash),
        ScancodeKey(scancode: 0x36, extended: false): CGKeyCode(kVK_RightShift),

        // Bottom row: keypad multiply, Alt, Space, CapsLock
        ScancodeKey(scancode: 0x37, extended: false): CGKeyCode(kVK_ANSI_KeypadMultiply),
        ScancodeKey(scancode: 0x38, extended: false): CGKeyCode(kVK_Option), // Left Alt
        ScancodeKey(scancode: 0x39, extended: false): CGKeyCode(kVK_Space),
        ScancodeKey(scancode: 0x3A, extended: false): CGKeyCode(kVK_CapsLock),

        // F1-F10
        ScancodeKey(scancode: 0x3B, extended: false): CGKeyCode(kVK_F1),
        ScancodeKey(scancode: 0x3C, extended: false): CGKeyCode(kVK_F2),
        ScancodeKey(scancode: 0x3D, extended: false): CGKeyCode(kVK_F3),
        ScancodeKey(scancode: 0x3E, extended: false): CGKeyCode(kVK_F4),
        ScancodeKey(scancode: 0x3F, extended: false): CGKeyCode(kVK_F5),
        ScancodeKey(scancode: 0x40, extended: false): CGKeyCode(kVK_F6),
        ScancodeKey(scancode: 0x41, extended: false): CGKeyCode(kVK_F7),
        ScancodeKey(scancode: 0x42, extended: false): CGKeyCode(kVK_F8),
        ScancodeKey(scancode: 0x43, extended: false): CGKeyCode(kVK_F9),
        ScancodeKey(scancode: 0x44, extended: false): CGKeyCode(kVK_F10),

        // 0x45 NumLock, 0x46 ScrollLock: deliberately absent — see
        // ScancodeMapTests.testDeliberatelyUnmappedKeysReturnNil.

        // Numeric keypad
        ScancodeKey(scancode: 0x47, extended: false): CGKeyCode(kVK_ANSI_Keypad7),
        ScancodeKey(scancode: 0x48, extended: false): CGKeyCode(kVK_ANSI_Keypad8),
        ScancodeKey(scancode: 0x49, extended: false): CGKeyCode(kVK_ANSI_Keypad9),
        ScancodeKey(scancode: 0x4A, extended: false): CGKeyCode(kVK_ANSI_KeypadMinus),
        ScancodeKey(scancode: 0x4B, extended: false): CGKeyCode(kVK_ANSI_Keypad4),
        ScancodeKey(scancode: 0x4C, extended: false): CGKeyCode(kVK_ANSI_Keypad5),
        ScancodeKey(scancode: 0x4D, extended: false): CGKeyCode(kVK_ANSI_Keypad6),
        ScancodeKey(scancode: 0x4E, extended: false): CGKeyCode(kVK_ANSI_KeypadPlus),
        ScancodeKey(scancode: 0x4F, extended: false): CGKeyCode(kVK_ANSI_Keypad1),
        ScancodeKey(scancode: 0x50, extended: false): CGKeyCode(kVK_ANSI_Keypad2),
        ScancodeKey(scancode: 0x51, extended: false): CGKeyCode(kVK_ANSI_Keypad3),
        ScancodeKey(scancode: 0x52, extended: false): CGKeyCode(kVK_ANSI_Keypad0),
        ScancodeKey(scancode: 0x53, extended: false): CGKeyCode(kVK_ANSI_KeypadDecimal),

        // F11, F12
        ScancodeKey(scancode: 0x57, extended: false): CGKeyCode(kVK_F11),
        ScancodeKey(scancode: 0x58, extended: false): CGKeyCode(kVK_F12),

        // Extended (E0-prefixed) keys
        ScancodeKey(scancode: 0x1C, extended: true): CGKeyCode(kVK_ANSI_KeypadEnter),
        ScancodeKey(scancode: 0x1D, extended: true): CGKeyCode(kVK_RightControl),
        ScancodeKey(scancode: 0x35, extended: true): CGKeyCode(kVK_ANSI_KeypadDivide),
        ScancodeKey(scancode: 0x38, extended: true): CGKeyCode(kVK_RightOption), // Right Alt
        ScancodeKey(scancode: 0x47, extended: true): CGKeyCode(kVK_Home),
        ScancodeKey(scancode: 0x48, extended: true): CGKeyCode(kVK_UpArrow),
        ScancodeKey(scancode: 0x49, extended: true): CGKeyCode(kVK_PageUp),
        ScancodeKey(scancode: 0x4B, extended: true): CGKeyCode(kVK_LeftArrow),
        ScancodeKey(scancode: 0x4D, extended: true): CGKeyCode(kVK_RightArrow),
        ScancodeKey(scancode: 0x4F, extended: true): CGKeyCode(kVK_End),
        ScancodeKey(scancode: 0x50, extended: true): CGKeyCode(kVK_DownArrow),
        ScancodeKey(scancode: 0x51, extended: true): CGKeyCode(kVK_PageDown),
        // E0 0x52 Insert: deliberately absent — see
        // ScancodeMapTests.testDeliberatelyUnmappedKeysReturnNil.
        ScancodeKey(scancode: 0x53, extended: true): CGKeyCode(kVK_ForwardDelete),

        // Command/Windows keys and the ISO extra key.
        ScancodeKey(scancode: 0x5B, extended: true): CGKeyCode(kVK_Command), // Left Command/Windows
        ScancodeKey(scancode: 0x5C, extended: true): CGKeyCode(kVK_RightCommand), // Right Command/Windows
        ScancodeKey(scancode: 0x56, extended: false): CGKeyCode(kVK_ISO_Section), // ISO extra key

        // E0 0x5D Apps/menu key: deliberately absent — see
        // ScancodeMapTests.testDeliberatelyUnmappedKeysReturnNil.
    ]
}
