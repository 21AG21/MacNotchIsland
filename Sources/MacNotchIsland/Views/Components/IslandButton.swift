import SwiftUI

struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(IslandMotion.quick, value: configuration.isPressed)
    }
}

/// Plain glyph button (transport controls).
struct GlyphButton: View {
    let symbol: String
    var size: CGFloat = 18
    var tint: Color = .white
    var action: () -> Void

    var body: some View {
        Button(action: { Haptics.soft(); action() }) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size + 18, height: size + 18)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IslandButtonStyle())
    }
}

/// Filled circular button (timer pause / cancel, join call…).
struct CircleActionButton: View {
    let symbol: String
    var tint: Color = .white
    var size: CGFloat = 44
    var filled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: { Haptics.soft(); action() }) {
            ZStack {
                Circle().fill(filled ? tint : tint.opacity(0.22))
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(filled ? Color.black : tint)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
    }
}

/// Rounded text button ("Join", "Open", timer presets).
struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .white
    var prominent: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: { Haptics.soft(); action() }) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.black : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(prominent ? tint : tint.opacity(0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(IslandButtonStyle())
    }
}
