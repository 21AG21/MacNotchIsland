import AppKit
import SwiftUI

/// What the rail's Focus disc opens: Off and this Mac's Focus modes, the one that is on filled
/// in its own colour, the way Control Centre's Focus module draws it. A click on a row sets that
/// Focus through the person's "Set Focus" shortcut (`FocusSetter`); until there is one, the rows
/// still say which Focus is on, and a line under them says how to make it.
///
/// Built the way `DisplayModuleView` is, from the system's own controls in the system's colours,
/// since a popover is its own window; and, like it, reading the shared objects directly rather
/// than through the environment, which a popover's window does not always carry across.
struct FocusModuleView: View {
    @ObservedObject private var status = FocusStatus.shared
    @ObservedObject private var runner = ShortcutsRunner.shared
    /// Read as the popover opens. The list changes when somebody makes a Focus in System
    /// Settings, which is not something done with this open.
    @State private var modes: [FocusMode] = []
    /// The Shortcuts app's list has been read since the popover opened, or was already in hand.
    /// Until then a missing "Set Focus" may only be a list that has not come back yet, and the
    /// setup line waits rather than telling somebody who made the shortcut to go and make it.
    @State private var listed = false

    var body: some View {
        let shortcut = FocusSetter.shortcut(in: runner.available)
        let picker = FocusPickerRows(modes: modes, active: status.active?.identifier, hasShortcut: shortcut != nil)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Focus")
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(picker.rows) { row in
                    FocusModeRow(row: row, enabled: !picker.needsShortcut) {
                        guard let input = row.input, let shortcut else { return }
                        FocusSetter.set(input, shortcut: shortcut)
                    }
                }
            }
            if picker.needsShortcut && listed {
                note(FocusPickerRows.setupNote, button: "Open Shortcuts") {
                    if let url = FocusSetter.shortcutsApp { NSWorkspace.shared.open(url) }
                }
            }
            if picker.modesUnread {
                note(FocusPickerRows.unreadNote, button: "Open Full Disk Access") {
                    SystemSettingsPane.fullDiskAccess.open()
                }
            }
            Divider()
            // Where the disc itself used to go, and where a right-click on it still goes.
            Button("Focus Settings\u{2026}") {
                if let url = RailControl.focusSettings { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: DisplayModuleView.width, alignment: .leading)
        .onAppear {
            modes = FocusMonitor.readModes()
            listed = !runner.available.isEmpty
            // Asked again every time: the shortcut is made in another app, and this is the
            // moment somebody who has just made it comes back to use it.
            runner.refresh()
        }
        .onReceive(runner.$available.dropFirst()) { _ in listed = true }
    }

    /// A line of explanation and the one button that deals with it.
    private func note(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .controlSize(.small)
        }
    }
}

/// One row of the Focus popover: the mode's glyph on a disc, filled in the mode's colour while
/// it is on, and its name.
private struct FocusModeRow: View {
    let row: FocusPickerRows.Row
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(row.isActive ? Color.named(row.tint) : Color.primary.opacity(0.1))
                    Image(systemName: row.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(row.isActive ? Color.white : Color.primary)
                }
                .frame(width: 26, height: 26)
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if row.isActive {
                    Text("On")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(row.help)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityValue(row.spokenValue)
        .accessibilityHint(row.spokenHint ?? "")
        .accessibilityAddTraits(row.isActive ? [.isButton, .isSelected] : .isButton)
    }
}
