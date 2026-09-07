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
                        .help("Go back to the shipping shortcut.")
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
        if hotkey.registrationFailed { return "Another app is already using this shortcut." }
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
        guard modifiers != 0 else {
            self.hint = "Add Control, Option, Shift or Command."
            return nil
        }
        Preferences.shared.hotkeyKeyCode = Double(event.keyCode)
        Preferences.shared.hotkeyModifiers = Double(modifiers)
        self.hint = nil
        self.endRecording()
        return nil
    }

    private func reset() {
        endRecording()
        hint = nil
        Preferences.shared.hotkeyKeyCode = Double(HotKeyService.defaultKeyCode)
        Preferences.shared.hotkeyModifiers = Double(HotKeyService.defaultModifiers)
    }
}
