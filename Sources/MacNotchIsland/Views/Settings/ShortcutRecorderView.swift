import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Settings row for the global shortcut: the current combo, a "Change" button that records a
/// new one, and a "Reset" button back to ⌃⌥Space. No window chrome of its own — SettingsView
/// embeds it under the "Keyboard shortcut" toggle.
struct ShortcutRecorderView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var hotkey = HotKeyService.shared
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcut").font(.system(size: 15))
                    if let note = note {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                combo
                Button(isRecording ? "Cancel" : "Change") {
                    if isRecording { endRecording() } else { beginRecording() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                Button("Reset") { reset() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 9)
            Divider().opacity(0.5)
        }
        .onDisappear { endRecording() }
    }

    // MARK: Pieces

    @ViewBuilder
    private var combo: some View {
        if isRecording {
            Text("Press keys…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Text(comboText)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private var comboText: String {
        HotKeyService.displayString(
            keyCode: HotKeyService.normalized(prefs.hotkeyKeyCode, fallback: HotKeyService.defaultKeyCode),
            carbonModifiers: HotKeyService.normalized(prefs.hotkeyModifiers, fallback: HotKeyService.defaultModifiers)
        )
    }

    /// The small grey line under the label: a nudge while recording, otherwise the conflict warning.
    private var note: String? {
        if let hint = hint { return hint }
        if hotkey.registrationFailed { return "Shortcut taken by another app" }
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
            self.hint = "Add ⌃, ⌥, ⇧ or ⌘"
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
