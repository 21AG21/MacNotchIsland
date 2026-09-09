import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

/// Global shortcuts that drive the island without touching the trackpad. The main combo lives
/// in preferences (⌃⌥Space out of the box) and toggles the island; the same modifiers with Tab
/// step forward through every view, with Shift+Tab backward; Escape closes whatever is open,
/// and the modifiers with the arrow keys step sideways; those are only registered while
/// something is open. Uses Carbon's RegisterEventHotKey, which works for
/// background apps with no permissions.
final class HotKeyService: ObservableObject {
    /// One owner for the registration, so Settings can watch it while ServiceHub drives it.
    static let shared = HotKeyService()

    /// True when the last registration attempt was refused — almost always because another
    /// app already owns the combo. Settings surfaces this next to the recorder.
    @Published private(set) var registrationFailed = false

    /// ⌃⌥Space: the shipping default, and what the recorder's "Reset" button restores.
    static let defaultKeyCode = kVK_Space
    static let defaultModifiers = controlKey | optionKey

    private enum Slot: UInt32 {
        case toggle = 1, next = 2, previous = 3, escape = 4, left = 5, right = 6
        /// Claimed only while the panel is pinned open on a section nobody types into.
        case panelLeft = 7, panelRight = 8, volumeUp = 9, volumeDown = 10, playPause = 11
        case slot1 = 21, slot2 = 22, slot3 = 23, slot4 = 24, slot5 = 25
        case slot6 = 26, slot7 = 27, slot8 = 28, slot9 = 29
        /// The twenty-six letter keys, in alphabetical order, claimed alongside the rest so
        /// that typing on a section which is a list of things starts a find in it.
        case letterA = 31, letterB = 32, letterC = 33, letterD = 34, letterE = 35, letterF = 36
        case letterG = 37, letterH = 38, letterI = 39, letterJ = 40, letterK = 41, letterL = 42
        case letterM = 43, letterN = 44, letterO = 45, letterP = 46, letterQ = 47, letterR = 48
        case letterS = 49, letterT = 50, letterU = 51, letterV = 52, letterW = 53, letterX = 54
        case letterY = 55, letterZ = 56

        /// The switcher slot a digit key stands for, counting from zero.
        var switcherIndex: Int? {
            guard (21...29).contains(rawValue) else { return nil }
            return Int(rawValue) - 21
        }

        /// The virtual key code this slot was registered for, when it is one of the letters.
        var letterKeyCode: Int? {
            guard (31...56).contains(rawValue) else { return nil }
            return HotKeyService.letterKeyCodes[Int(rawValue) - 31]
        }
    }

    /// Every slot the panel claims while it is open, so they are released together.
    private static let panelSlots: [Slot] =
        [.panelLeft, .panelRight, .volumeUp, .volumeDown, .playPause]
        + (0..<9).compactMap { Slot(rawValue: UInt32(21 + $0)) }
        + (0..<26).compactMap { Slot(rawValue: UInt32(31 + $0)) }

    /// The ANSI digits 1 to 9, in that order. Their virtual key codes are not consecutive,
    /// which is why they are written out rather than counted.
    private static let digitKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// A to Z, in that order. Virtual key codes are positions rather than letters, so what
    /// these twenty-six are is "the keys that carry the alphabet"; which letter each of them
    /// types on the layout in force is `KeyLayout`'s question, asked when one is pressed.
    static let letterKeyCodes = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
                                 kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
                                 kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
                                 kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
                                 kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
                                 kVK_ANSI_Z]

    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var escapeArmed = false
    private var panelKeysArmed = false
    /// Whether the alphabet is claimed too, which depends on the section as well as the panel.
    private var letterKeysArmed = false
    private var cancellables = Set<AnyCancellable>()
    private static let signature: OSType = 0x4E4F5443 // "NOTC"

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            // Only our own, well-formed hot keys are acted on; anything else is logged and dropped.
            guard read == noErr, hotKeyID.signature == HotKeyService.signature, let slot = Slot(rawValue: hotKeyID.id) else {
                IslandLog.keys.error("hot key event ignored: status \(read, privacy: .public) id \(hotKeyID.id, privacy: .public)")
                return noErr
            }
            DispatchQueue.main.async { HotKeyService.handle(slot) }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard status == noErr else {
            handlerRef = nil
            return
        }
        register()
        observePreferences()
    }

    func stop() {
        cancellables.removeAll()
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        registrationFailed = false
    }

    // MARK: - Registration

    /// Re-registers whenever the recorded combo changes. Debounced so that writing the key code
    /// and the modifiers one after the other costs a single registration.
    private func observePreferences() {
        guard cancellables.isEmpty else { return }
        let prefs = Preferences.shared
        // The switch as well as the combination: with the panel's own keys on, this service
        // keeps running after the shortcut is switched off, so something has to take the
        // shortcut back.
        Publishers.CombineLatest3(prefs.$hotkeyKeyCode, prefs.$hotkeyModifiers, prefs.$hotkeyEnabled)
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.register() }
            .store(in: &cancellables)
    }

    /// Recording a replacement: the live combo must not fire while the user presses keys.
    func suspend() { unregister() }

    func resume() {
        guard handlerRef != nil else { return }
        register()
    }

    private func register() {
        guard handlerRef != nil else { return }
        unregister()
        if Preferences.shared.hotkeyEnabled {
            let modifiers = Self.currentModifiers
            registrationFailed = !register(.toggle, keyCode: Self.currentKeyCode, modifiers: modifiers)
            // Tab with the same modifiers cycles views; adding Shift reverses. When the main
            // combo already holds Shift the two coincide, and only the forward step registers.
            register(.next, keyCode: kVK_Tab, modifiers: modifiers)
            if modifiers & shiftKey == 0 { register(.previous, keyCode: kVK_Tab, modifiers: modifiers | shiftKey) }
        } else {
            // Nothing was asked of the system, so nothing was refused.
            registrationFailed = false
        }
        if escapeArmed { registerWhileOpen() }
        if panelKeysArmed { registerPanelKeys() }
    }

    /// Escape, and the main combo's modifiers with the arrow keys, are claimed only while the
    /// island has something open: the arrows step between sections the way a swipe does.
    private func registerWhileOpen() {
        // Escape belongs to whatever is open, not to the shortcut that may have opened it.
        register(.escape, keyCode: kVK_Escape, modifiers: 0)
        guard Preferences.shared.hotkeyEnabled else { return }
        let modifiers = Self.currentModifiers
        // Both are registered whatever the other does; `&&` would skip the second.
        let left = register(.left, keyCode: kVK_LeftArrow, modifiers: modifiers)
        let right = register(.right, keyCode: kVK_RightArrow, modifiers: modifiers)
        let arrows = left && right
        // Another app owning the combo costs the arrows, not the shortcut itself, so this is
        // logged rather than shown beside the recorder.
        if !arrows { IslandLog.keys.notice("arrow keys unavailable: another app owns the combo") }
    }

    private func unregisterWhileOpen() {
        unregister(.escape)
        unregister(.left)
        unregister(.right)
    }

    /// The keys the panel answers on its own, with nothing held down: the arrows step between
    /// views the way a sideways swipe does, the digits go straight to a slot of the switcher,
    /// Space plays and pauses, and the vertical arrows move the volume — the keyboard's
    /// version of a scroll. Claimed only while the panel is pinned open, and dropped the
    /// instant it lands on a section that is typed into.
    private func registerPanelKeys() {
        register(.panelLeft, keyCode: kVK_LeftArrow, modifiers: 0)
        register(.panelRight, keyCode: kVK_RightArrow, modifiers: 0)
        register(.volumeUp, keyCode: kVK_UpArrow, modifiers: 0)
        register(.volumeDown, keyCode: kVK_DownArrow, modifiers: 0)
        register(.playPause, keyCode: kVK_Space, modifiers: 0)
        for (index, code) in Self.digitKeyCodes.enumerated() {
            guard let slot = Slot(rawValue: UInt32(21 + index)) else { continue }
            register(slot, keyCode: code, modifiers: 0)
        }
        // The alphabet, but only where there is a list to look through: on Now Playing or
        // Stats a letter is nobody's to take, so it is left alone.
        guard letterKeysArmed else { return }
        for (index, code) in Self.letterKeyCodes.enumerated() {
            guard let slot = Slot(rawValue: UInt32(31 + index)) else { continue }
            register(slot, keyCode: code, modifiers: 0)
        }
    }

    private func unregisterPanelKeys() {
        for slot in Self.panelSlots { unregister(slot) }
    }

    @discardableResult
    private func register(_ slot: Slot, keyCode: Int, modifiers: Int) -> Bool {
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs[slot] = ref
        return true
    }

    private func unregister() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    private func unregister(_ slot: Slot) {
        if let ref = hotKeyRefs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) }
    }

    /// Escape is claimed only while the island has something open, so it never interferes
    /// with other apps the rest of the time.
    func setEscapeArmed(_ armed: Bool) {
        guard armed != escapeArmed else { return }
        escapeArmed = armed
        guard handlerRef != nil else { return }
        if armed { registerWhileOpen() } else { unregisterWhileOpen() }
    }

    /// Armed while the panel is pinned open on a section nobody types into. See
    /// `ActivityCenter.ownsPanelKeys`, which decides it. `letters` is the narrower question of
    /// whether this section is a list worth searching, and it changes as the panel steps from
    /// one section to the next while the rest of the keys stay claimed — so both are settled
    /// here, and a change to either re-registers the set.
    func setPanelKeysArmed(_ armed: Bool, letters: Bool = false) {
        let wantsLetters = armed && letters
        guard armed != panelKeysArmed || wantsLetters != letterKeysArmed else { return }
        panelKeysArmed = armed
        letterKeysArmed = wantsLetters
        guard handlerRef != nil else { return }
        unregisterPanelKeys()
        if armed { registerPanelKeys() }
    }

    static var currentKeyCode: Int {
        normalized(Preferences.shared.hotkeyKeyCode, fallback: defaultKeyCode)
    }

    static var currentModifiers: Int {
        let stored = normalized(Preferences.shared.hotkeyModifiers, fallback: defaultModifiers)
        // Without a modifier the island would claim Tab and the arrow keys system-wide. The
        // recorder refuses such a combo; a hand-edited defaults entry is refused here.
        return stored == 0 ? defaultModifiers : stored
    }

    /// Preferences store these as Doubles; a stale or hand-edited defaults entry must never
    /// blow up an `Int()` conversion or hand Carbon a nonsense key code.
    static func normalized(_ value: Double, fallback: Int) -> Int {
        guard value.isFinite, value >= 0, value <= Double(UInt16.max) else { return fallback }
        return Int(value)
    }

    // MARK: - Actions

    private static func handle(_ slot: Slot) {
        let center = ActivityCenter.shared
        let sinceInteraction = Date().timeIntervalSince(center.lastInteraction)
        IslandLog.keys.notice("hot key \(slot.rawValue, privacy: .public) after \(sinceInteraction, privacy: .public)s")
        switch slot {
        case .toggle: center.toggle()
        case .next: center.cycleView(forward: true)
        case .previous: center.cycleView(forward: false)
        case .left: _ = center.step(forward: false, wrap: false)
        case .right: _ = center.step(forward: true, wrap: false)
        case .escape:
            // Escape is registered the instant something opens; nothing in the tail of that
            // click may pass for a key press.
            guard sinceInteraction > 0.3 else { return }
            // One step back at a time: a find in progress is what Escape leaves first, the
            // way it does in every window on the Mac that has a search field.
            if center.endFind() { return }
            center.collapse(reason: "escape")
        case .panelLeft: _ = center.step(forward: false, wrap: false)
        case .panelRight: _ = center.step(forward: true, wrap: false)
        case .volumeUp: GestureRouter.shared.nudgeVolume(up: true)
        case .volumeDown: GestureRouter.shared.nudgeVolume(up: false)
        case .playPause:
            // On the shelf, Space is Quick Look — where every Mac has taught people to expect
            // it. Anywhere else it plays and pauses.
            if center.isShowingShelf, !ShelfStore.shared.items.isEmpty {
                ShelfQuickLook.shared.show(ShelfStore.shared.urls)
            } else {
                NowPlayingService.shared.togglePlayPause()
            }
        // The digits and the letters, which are the only slots left.
        default:
            if let index = slot.switcherIndex {
                center.selectSlot(index)
            } else if let code = slot.letterKeyCode, let character = KeyLayout.character(for: code) {
                center.beginFind(with: character)
            }
        }
    }

    // MARK: - Display

    /// "⌃⌥Space", "⇧⌘K", "F5" — modifiers in Apple's canonical order, then the key name.
    static func displayString(keyCode: Int, carbonModifiers: Int) -> String {
        var text = ""
        if (carbonModifiers & controlKey) != 0 { text += "⌃" }
        if (carbonModifiers & optionKey) != 0 { text += "⌥" }
        if (carbonModifiers & shiftKey) != 0 { text += "⇧" }
        if (carbonModifiers & cmdKey) != 0 { text += "⌘" }
        return text + keyName(for: keyCode)
    }

    /// Maps a Carbon virtual key code to a printable name (ANSI layout).
    static func keyName(for keyCode: Int) -> String {
        if let name = keyNames[keyCode] { return name }
        let hex = String(keyCode, radix: 16, uppercase: true)
        return "Key 0x" + (hex.count < 2 ? "0" + hex : hex)
    }

    /// The AppKit modifier flags of a recorded event, as the Carbon masks RegisterEventHotKey wants.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.command) { mask |= cmdKey }
        return mask
    }

    /// Virtual key codes are layout-independent positions; these are the ANSI legends.
    private static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
