import Carbon
import Foundation

/// What a key actually types on this Mac.
///
/// A Carbon hot key is delivered as a virtual key code, which is a position on the keyboard
/// rather than a letter: key 12 is Q on a US layout, A on a French one and ' on a Dvorak one.
/// The island claims the letter keys while the panel is open so that typing starts a find, and
/// the character that opens the find has to be the one the person actually pressed — otherwise
/// the first letter of every search is wrong for half the world.
///
/// `UCKeyTranslate` answers that question against the layout that is switched on right now.
enum KeyLayout {
    /// The character a key code types with nothing held down, or nil when the current input
    /// source cannot say — a Chinese or Japanese input method has no plain layout of its own,
    /// so the ASCII-capable layout underneath it is asked instead.
    static func character(for keyCode: Int) -> String? {
        guard let data = layoutData() else { return nil }
        var deadKeyState: UInt32 = 0
        var length: UniCharCount = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self),
                                  UInt16(keyCode), UInt16(kUCKeyActionDown), 0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, UniCharCount(characters.count), &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: Int(length))
    }

    /// The `uchr` table of the keyboard layout in force, falling back to the ASCII-capable one
    /// behind an input method that has none.
    private static func layoutData() -> Data? {
        if let data = layoutData(of: TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()) { return data }
        return layoutData(of: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    private static func layoutData(of source: TISInputSource?) -> Data? {
        guard let source,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }
}
