import SwiftUI

/// Horizontal row of favourited Shortcuts as round glyph buttons, meant to sit in the
/// Home panel (roughly 500 x 60). Tapping a button runs that shortcut immediately.
struct QuickActionsRowView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared

    var body: some View {
        HStack(spacing: 10) {
            if runner.favorites.isEmpty {
                Text("Pick shortcuts in Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(runner.favorites, id: \.self) { name in
                    QuickActionButton(name: name)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 500, height: 60, alignment: .leading)
    }
}

private struct QuickActionButton: View {
    let name: String
    @ObservedObject private var runner = ShortcutsRunner.shared
    @State private var hovering = false

    private static let diameter: CGFloat = 32

    var body: some View {
        Button(action: { runner.run(name) }) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.14))
                    Image(systemName: runner.symbol(for: name))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: Self.diameter, height: Self.diameter)
                Text(name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 50)
            }
            .offset(y: hovering ? -2 : 0)
        }
        .buttonStyle(IslandButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(IslandMotion.quick, value: hovering)
        .accessibilityLabel("Run shortcut \(name)")
    }
}
