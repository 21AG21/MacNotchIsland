import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

/// Global shortcut that summons the island without touching the trackpad. The combo lives in
/// preferences (⌃⌥Space out of the box) and is re-registered whenever the user records a new one.
/// Uses Carbon's RegisterEventHotKey, which works for background apps with no permissions.
final class HotKeyService: ObservableObject {
    /// One owner for the registration, so Settings can watch it while ServiceHub drives it.
    static let shared = HotKeyService()

    /// True when the last registration attempt was refused — almost always because another
    /// app already owns the combo. Settings surfaces this next to the recorder.
    @Published private(set) var registrationFailed = false

    /// ⌃⌥Space: the shipping default, and what the recorder's "Reset" button restores.
    static let defaultKeyCode = kVK_Space
    static let defaultModifiers = controlKey | optionKey

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()
    private static let signature: OSType = 0x4E4F5443 // "NOTC"

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyService.toggleIsland() }
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
        Publishers.CombineLatest(prefs.$hotkeyKeyCode, prefs.$hotkeyModifiers)
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
        let keyCode = UInt32(Self.currentKeyCode)
        let modifiers = UInt32(Self.currentModifiers)
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, ref != nil {
            hotKeyRef = ref
            registrationFailed = false
        } else {
            hotKeyRef = nil
            registrationFailed = true
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    static var currentKeyCode: Int {
        normalized(Preferences.shared.hotkeyKeyCode, fallback: defaultKeyCode)
    }

    static var currentModifiers: Int {
        normalized(Preferences.shared.hotkeyModifiers, fallback: defaultModifiers)
    }

    /// Preferences store these as Doubles; a stale or hand-edited defaults entry must never
    /// blow up an `Int()` conversion or hand Carbon a nonsense key code.
    static func normalized(_ value: Double, fallback: Int) -> Int {
        guard value.isFinite, value >= 0, value <= Double(UInt16.max) else { return fallback }
        return Int(value)
    }

    // MARK: - Action

    static func toggleIsland() {
        let center = ActivityCenter.shared
        if center.presentation.isExpanded {
            center.collapse()
        } else if let primary = center.primary, primary.content.hasExpandedView {
            center.forceExpanded(id: primary.id, for: 8)
        } else {
            center.showHome(for: 8)
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
