import SwiftUI

struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            // Down at once, back on a spring: a press that eases in as slowly as it eases
            // out feels like the button answered a moment late.
            .animation(IslandMotion.press(down: configuration.isPressed), value: configuration.isPressed)
    }
}

/// Plain glyph button (transport controls).
struct GlyphButton: View {
    let symbol: String
    var size: CGFloat = 18
    var tint: Color = .white
    var weight: Font.Weight = .bold
    var label: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .frame(width: size + 18, height: size + 18)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel(label ?? Self.describe(symbol))
    }

    static func describe(_ symbol: String) -> String {
        switch symbol {
        case "play.fill": return "Play"
        case "pause.fill": return "Pause"
        case "forward.fill": return "Next track"
        case "backward.fill": return "Previous track"
        case "airplayaudio": return "Open player"
        case "xmark": return "Cancel"
        case "stop.fill": return "Stop"
        case "flag.fill": return "Lap"
        case "arrow.counterclockwise": return "Repeat"
        case "arrow.up.forward": return "Open"
        default: return symbol.replacingOccurrences(of: ".", with: " ")
        }
    }
}

/// Circular action button. Unfilled is the island's quiet control: a white-12% disc with the
/// glyph in the tint. Filled is the loud one (the call card's red button), and `glyph` sets the
/// colour drawn on top of that fill.
struct CircleActionButton: View {
    let symbol: String
    var tint: Color = .white
    var size: CGFloat = 40
    var filled: Bool = false
    /// Glyph colour on a filled circle; ignored while the circle is the quiet unfilled one.
    var glyph: Color = .black
    var label: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(filled ? tint : tint.opacity(0.12))
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(filled ? glyph : tint)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel(label ?? GlyphButton.describe(symbol))
    }
}

/// Whether controls here draw at the smaller size a section header uses.
///
/// A section header is one 22 pt line, and a full-size pill is 28 pt tall: dropped on that
/// line it was squeezed out of shape, and its white 12 pt label out-shouted the very title
/// it sits beside. `SectionHeader` turns this on for its trailing edge, so a header's
/// controls shrink to fit the line without every call site saying so.
private struct IslandCompactControlsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var islandCompactControls: Bool {
        get { self[IslandCompactControlsKey.self] }
        set { self[IslandCompactControlsKey.self] = newValue }
    }
}

/// Rounded text button ("Join", "Open", timer presets).
struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .white
    var prominent: Bool = false
    var action: () -> Void

    @Environment(\.islandCompactControls) private var compact

    /// 28 pt on its own, 21 pt on a header's line.
    private var metrics: (text: CGFloat, glyph: CGFloat, gap: CGFloat, h: CGFloat, v: CGFloat) {
        compact ? (11, 10, 4, 9, 4) : (12, 11, 5, 12, 7)
    }

    var body: some View {
        let m = metrics
        return Button(action: action) {
            HStack(spacing: m.gap) {
                if let symbol { Image(systemName: symbol).font(.system(size: m.glyph, weight: .bold)) }
                Text(title).font(.system(size: m.text, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.black : tint)
            .padding(.horizontal, m.h)
            .padding(.vertical, m.v)
            // On a header line every control is exactly the line's height, so a pill and the
            // clipboard's search field are two capsules of one size rather than two of nearly
            // one size.
            .frame(height: compact ? SectionMetrics.headerHeight : nil)
            .background(Capsule().fill(prominent ? tint : tint.opacity(0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(IslandButtonStyle())
    }
}
