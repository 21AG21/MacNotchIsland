import AppKit
import SwiftUI

/// Favourited Shortcuts as round glyph buttons across the Actions section. Clicking one runs
/// that shortcut immediately.
struct QuickActionsRowView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared

    var body: some View {
        Group {
            if runner.favorites.isEmpty {
                // One row, like the timer presets under it: a glyph, a line, the way in.
                HStack(spacing: 12) {
                    Image(systemName: "bolt")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("No quick actions yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Your Shortcuts, one click away.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 8)
                    PillButton(title: "Choose Shortcuts…") {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(runner.favorites.prefix(8), id: \.self) { name in
                        QuickActionButton(name: name)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuickActionButton: View {
    let name: String
    @ObservedObject private var runner = ShortcutsRunner.shared
    @State private var hovering = false

    private static let diameter: CGFloat = 40

    var body: some View {
        Button(action: { runner.run(name) }) {
            VStack(spacing: 5) {
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
                    .frame(width: 66)
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
