import AppKit
import SwiftUI

/// The Actions row: favourite apps first, then favourited Shortcuts, as round buttons.
/// Clicking an app opens it and closes the panel; clicking a shortcut runs it where it is.
struct QuickActionsRowView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared
    @ObservedObject private var apps = FavoriteApps.shared

    /// Eight buttons is what the row holds; apps come first because they are what people
    /// reach for most.
    static let capacity = 8

    var body: some View {
        Group {
            if runner.favorites.isEmpty && apps.apps.isEmpty {
                // One row, like the timer presets under it: a glyph, a line, the way in.
                HStack(spacing: 12) {
                    Image(systemName: "bolt")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 24, height: 40, alignment: .leading)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("No quick actions yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Your apps and Shortcuts, one click away.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 8)
                    PillButton(title: "Choose Actions…") {
                        // Straight to the pane that fills this row, rather than to whichever
                        // pane Settings happened to be left on.
                        UserDefaults.standard.set(SettingsSection.shortcuts.rawValue, forKey: "settingsSection")
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            } else {
                let favourites = apps.apps
                HStack(alignment: .top, spacing: 6) {
                    ForEach(favourites, id: \.path) { app in
                        AppButton(path: app.path, name: app.name)
                    }
                    ForEach(runner.favorites.prefix(max(0, Self.capacity - favourites.count)), id: \.self) { name in
                        QuickActionButton(name: name)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One favourite app: its own icon, its name, and a click that opens it. The disc hangs from
/// the leading edge of its name's column, so the first button in the row starts on the panel's
/// content column rather than 13 pt inside it.
private struct AppButton: View {
    let path: String
    let name: String
    @ObservedObject private var apps = FavoriteApps.shared
    @State private var hovering = false

    private static let diameter: CGFloat = 40

    var body: some View {
        Button(action: { apps.launch(path) }) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Circle().fill(Color.white.opacity(hovering ? 0.2 : 0.12))
                    if let icon = apps.icon(for: path) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "app")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: Self.diameter, height: Self.diameter)
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 66, alignment: .leading)
            }
        }
        .buttonStyle(IslandButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(IslandMotion.quick, value: hovering)
        .help("Open \(name)")
        .accessibilityLabel("Open \(name)")
    }
}

private struct QuickActionButton: View {
    let name: String
    @ObservedObject private var runner = ShortcutsRunner.shared
    @State private var hovering = false

    private static let diameter: CGFloat = 40

    var body: some View {
        Button(action: { runner.run(name) }) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    Circle().fill(Color.white.opacity(hovering ? 0.2 : 0.12))
                    Image(systemName: runner.symbol(for: name))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: Self.diameter, height: Self.diameter)
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 66, alignment: .leading)
            }
        }
        .buttonStyle(IslandButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(IslandMotion.quick, value: hovering)
        .help("Run \(name)")
        .accessibilityLabel("Run shortcut \(name)")
    }
}
