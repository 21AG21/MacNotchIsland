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
        character(for: keyCode, modifiers: 0)
    }

    /// The character a key code types with `modifiers` held — Carbon's masks, as a hot key is
    /// registered with — or nil when the layout cannot say. Asked with Shift for the number
    /// row, which types its figures only with Shift on a French or a Czech keyboard.
    ///
    /// Main thread only, as the Text Input Sources calls are, and recent macOS traps one made
    /// from any other; asked from another thread it says nothing, and whoever asked falls back
    /// to what the key says on an American keyboard.
    static func character(for keyCode: Int, modifiers: Int) -> String? {
        guard Thread.isMainThread, let data = layoutData() else { return nil }
        return translate(keyCode, modifiers: modifiers, in: data)
    }

    /// What each of `keyCodes` types with `modifiers` held, from one look at the layout rather
    /// than one per key. A key the layout has nothing for is left out.
    static func characters(for keyCodes: [Int], modifiers: Int = 0) -> [Int: String] {
        guard Thread.isMainThread, let data = layoutData() else { return [:] }
        var typed: [Int: String] = [:]
        for code in keyCodes {
            if let text = translate(code, modifiers: modifiers, in: data) { typed[code] = text }
        }
        return typed
    }

    private static func translate(_ keyCode: Int, modifiers: Int, in data: Data) -> String? {
        var deadKeyState: UInt32 = 0
        // Swift imports `UniCharCount` as a plain Int; naming the C typedef does not compile.
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        // `UCKeyTranslate` wants the modifier bits shifted down by eight: Shift, which is bit 9
        // of a Carbon mask, is bit 1 of what it reads.
        let state = UInt32((modifiers >> 8) & 0xFF)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self),
                                  UInt16(keyCode), UInt16(kUCKeyActionDown), state,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, buffer.count, &length, &buffer)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
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

    // MARK: - Input methods

    /// The kinds of input source that compose what is typed rather than typing it: Pinyin,
    /// Kotoeri, Korean 2-Set and the rest, and the modes inside them.
    static let inputMethodTypes: Set<String> = [
        kTISTypeKeyboardInputMode as String,
        kTISTypeKeyboardInputMethodWithoutModes as String,
        kTISTypeKeyboardInputMethodModeEnabled as String,
    ]

    /// Whether a find opened by a key press may start with the letter that key types, given
    /// the kind of input source in force (`kTISPropertyInputSourceType`).
    ///
    /// Under an input method a key is not a letter but the start of a composition: "k" on
    /// Pinyin is on its way to 可 or 看, and on Korean 2-Set the key marked K types ㅏ. The hot
    /// key takes the press before the input method sees it, and `character(for:)` can only
    /// answer from the Latin layout underneath, so the field opened with a bare "k" outside
    /// the composition, which then had to be deleted before anything could be typed. There
    /// the field opens empty and focused instead, and the letter is typed again into the
    /// input method. A plain layout, or a source that cannot be asked, keeps the letter.
    /// Pure, so the rule is tested without an input method switched on.
    static func prefillsFind(sourceType: String?) -> Bool {
        guard let sourceType else { return true }
        return !inputMethodTypes.contains(sourceType)
    }

    /// The same, for the input source in force. Main thread only.
    static var prefillsFindOnThisMac: Bool {
        prefillsFind(sourceType: currentSourceType())
    }

    /// The kind of the keyboard input source in force, or nil where it cannot be asked.
    private static func currentSourceType() -> String? {
        guard Thread.isMainThread,
              let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
