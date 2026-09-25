import SwiftUI

/// The listening modes as a row of equal pills: glyphs, the one the pair is in filled white.
/// Each pill takes its click in the whole of itself, never less than `IslandHit.minimum` tall.
struct ListeningModePicker: View {
    @ObservedObject var control: AirPodsControl
    /// How wide each pill is. See `ListeningModeMetrics.pillWidth(count:in:)`.
    let pillWidth: CGFloat

    var body: some View {
        HStack(spacing: ListeningModeMetrics.gap) {
            ForEach(control.modes) { mode in
                let on = mode == control.current
                Button(action: { control.set(mode) }) {
                    ZStack {
                        Capsule().fill(Color.white.opacity(on ? 0.9 : 0.10))
                        Image(systemName: mode.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
                    }
                    .frame(width: pillWidth, height: ListeningModeMetrics.height)
                    .contentShape(Capsule())
                }
                .buttonStyle(IslandButtonStyle())
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Noise control")
    }
}

/// What the pills measure, so the rows that hold them can be checked to fit.
enum ListeningModeMetrics {
    /// The row: the least a target may be, and no more, so it costs a list as little as it can.
    static let height: CGFloat = IslandHit.minimum
    static let gap: CGFloat = 2
    /// A pill on the Bluetooth card, which has the room to give every pill a glyph's worth of air.
    static let cardPill: CGFloat = 44

    /// Equal pills sharing `width` with a gap between each, rounded down to whole points.
    static func pillWidth(count: Int, in width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return ((width - gap * CGFloat(count - 1)) / CGFloat(count)).rounded(.down)
    }

    /// How wide `count` pills of `pill` are, gaps and all.
    static func rowWidth(count: Int, pill: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * pill + CGFloat(count - 1) * gap
    }
}
