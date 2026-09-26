import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The global shortcut row: the current combination, a button that records a new one, and a
/// button back to the shipping default. No chrome of its own — the Island pane drops it into
/// a `Form` section under the "Use a keyboard shortcut" toggle.
struct ShortcutRecorderView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var hotkey = HotKeyService.shared
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Shortcut") {
                HStack(spacing: 8) {
                    Text(isRecording ? "Press keys…" : comboText)
                        .font(.body)
                        .foregroundStyle(isRecording ? Color.secondary : Color.primary)
                    Button(isRecording ? "Cancel" : "Change") {
                        if isRecording { endRecording() } else { beginRecording() }
                    }
                    .help("Record a new shortcut.")
                    Button("Reset") { reset() }
                        .help("Go back to the shipping shortcut: ⌃⌥Space, or ⌃⌥I where macOS uses that.")
                }
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { endRecording() }
    }

    // MARK: Pieces

    private var comboText: String {
        HotKeyService.displayString(
            keyCode: HotKeyService.normalized(prefs.hotkeyKeyCode, fallback: HotKeyService.defaultKeyCode),
            carbonModifiers: HotKeyService.normalized(prefs.hotkeyModifiers, fallback: HotKeyService.defaultModifiers)
        )
    }

    /// The small grey line under the row: a nudge while recording, otherwise the conflict warning.
    private var note: String? {
        if let hint = hint { return hint }
        return Self.conflictNote(registrationFailed: hotkey.registrationFailed, takenBySystem: hotkey.takenBySystem,
                                 stepsWithheld: !HotKeyService.stepsAreSafe(modifiers: HotKeyService.currentModifiers))
    }

    /// What is said about a combination somebody else has. Two different somebodies: another
    /// app refuses the registration outright, while macOS lets it through and then answers the
    /// keys itself first — so the second was never said at all, on any Mac with two input
    /// sources and the shortcut as it shipped. Pure, so a test holds each to its sentence.
    ///
    /// `stepsWithheld` is a third: a combination with fewer than two of ⌃⌥⌘, stored before
    /// the recorder refused one, whose Tab and arrow steps are every app's and are left to them
    /// (`HotKeyService.stepsAreSafe`). It still opens and closes the island, and nothing else
    /// said the steps listed under it had gone.
    static func conflictNote(registrationFailed: Bool, takenBySystem: Bool, stepsWithheld: Bool = false) -> String? {
        if registrationFailed { return "Another app is already using this shortcut." }
        if takenBySystem {
            return "macOS uses this for one of its own shortcuts and answers it first — with two input sources, "
                + "switching between them. Choose another, or turn that one off in System Settings, under Keyboard Shortcuts."
        }
        if stepsWithheld {
            return "This opens and closes the island, but its steps are left off: apps use Tab and the arrows with it held. "
                + "Choose one with two of Control, Option and Command to step with them too."
        }
        return nil
    }

    // MARK: Recording

    /// The Settings window is key while this row is on screen, so a local monitor is enough —
    /// no Accessibility permission, and the keystrokes never leave the app.
    private func beginRecording() {
        guard !isRecording else { return }
        hint = nil
        isRecording = true
        HotKeyService.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            self.handle(event)
        }
    }

    private func endRecording() {
        isRecording = false
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeyService.shared.resume()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard self.isRecording else { return event }
        // Modifier presses on their own only build the combo up; swallow them so nothing else reacts.
        guard event.type == .keyDown else { return nil }
        if Int(event.keyCode) == kVK_Escape {
            self.hint = nil
            self.endRecording()
            return nil
        }
        let modifiers = HotKeyService.carbonModifiers(from: event.modifierFlags)
        if let refusal = Self.rejection(keyCode: Int(event.keyCode), modifiers: modifiers) {
            self.hint = refusal.message
            return nil
        }
        Preferences.shared.hotkeyKeyCode = Double(event.keyCode)
        Preferences.shared.hotkeyModifiers = Double(modifiers)
        self.hint = nil
        self.endRecording()
        return nil
    }

    /// Back to what this Mac ships with, which is ⌃⌥I where macOS has ⌃⌥Space: resetting to
    /// a combination the system answers first would reset to a shortcut that does nothing.
    private func reset() {
        endRecording()
        hint = nil
        let shipping = HotKeyService.shippingDefaultOnThisMac
        Preferences.shared.hotkeyKeyCode = Double(shipping.keyCode)
        Preferences.shared.hotkeyModifiers = Double(shipping.modifiers)
    }

    // MARK: The rule

    /// Why a combination that was pressed is not taken, and the line under the row that says so.
    ///
    /// A recorded combination is claimed from every app on the Mac, and `HotKeyService`
    /// registers whatever it is handed, so this row is the last place a bad one can be stopped.
    /// The only rule used to be "hold something down", which let ⇧A through — and Carbon then
    /// took the capital A from every application there is.
    enum Rejection: Equatable {
        /// Nothing held down: the island would take the bare key from everything.
        case bareKey
        /// Shift alone with anything but a function key. Every app uses that already — for a
        /// capital, the upper legend on a key, a longer selection — and it would be taken from
        /// all of them.
        case shiftAlone
        /// Tab or a sideways arrow, whatever is held with it. The island's own steps are
        /// registered on those keys with the recorded combination's modifiers, so any such
        /// combination is the shortcut and the step at once, and the second of the two to be
        /// registered loses in silence.
        case ownStep
        /// Fewer than two of Control, Option and Command. The steps ride on Tab and the arrows
        /// with the same modifiers, and with one of them — or Shift alone with a function key —
        /// those are editing keys in every app: ⌃K took ⌃Tab from every browser, ⌥Space the
        /// word jumps on ⌥← and ⌥→. See `HotKeyService.stepsAreSafe`.
        case tooFewModifiers

        var message: String {
            switch self {
            case .bareKey:
                return "Add two of Control, Option and Command."
            case .shiftAlone:
                return "Shift alone types a capital or extends a selection in every app. Add two of Control, Option and Command."
            case .ownStep:
                return "Tab, ← and → are the island's own steps, with whatever this shortcut holds. Choose another key."
            case .tooFewModifiers:
                return "Apps use Tab and the arrows with this held — ⌃Tab for tabs, ⌥→ to jump a word — and the island's "
                    + "steps would take them. Choose one with two of Control, Option and Command."
            }
        }
    }

    /// Whether a pressed combination may be the shortcut, and if not, why not. `modifiers`
    /// are the Carbon masks `HotKeyService.carbonModifiers(from:)` makes of an event's flags.
    static func rejection(keyCode: Int, modifiers: Int) -> Rejection? {
        if modifiers == 0 { return .bareKey }
        // Before the Shift rule: ⇧Tab is a step as much as ⌃⌥Tab is, and that is the truer
        // thing to say about it.
        if ownStepKeys.contains(keyCode) { return .ownStep }
        if modifiers == shiftKey, !functionKeys.contains(keyCode) { return .shiftAlone }
        // Last: every refusal above is the more particular thing to say about its combination.
        if !HotKeyService.stepsAreSafe(modifiers: modifiers) { return .tooFewModifiers }
        return nil
    }

    /// The keys the island's other shortcuts sit on. `HotKeyService.register()` puts the next
    /// section on Tab and `registerStepKeys()` the sideways steps on the arrows, each with
    /// `currentModifiers` — the modifiers of whatever was recorded here — which is why no set
    /// of modifiers makes these safe. Listed here rather than read from there because the
    /// service is not this view's to change; the pane's "Next section" and "Step sideways"
    /// rows show the same three keys.
    static let ownStepKeys: Set<Int> = [kVK_Tab, kVK_LeftArrow, kVK_RightArrow]

    /// F1 to F20: the keys that type nothing. Shift alone with one of them is no capital and
    /// no selection, so it is not `shiftAlone` — but it is still refused, for the steps it
    /// would put on ⇧Tab and ⇧← and ⇧→ (`tooFewModifiers`).
    static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}
