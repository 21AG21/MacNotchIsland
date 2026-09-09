import SwiftUI

struct HUDExpandedView: View {
    let state: LevelHUD
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.18))
                    Image(systemName: state.symbolName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    LevelBar(level: state.isMuted ? 0 : state.level, tint: .white)
                        .frame(height: 4)
                    if let device = state.device {
                        Text(device)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .accessibilityHidden(true)
                Text(Self.readout(state))
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(IslandMotion.digits, value: state.level)
                    .lineLimit(1)
                    .frame(width: 62, alignment: .trailing)
            }
            .islandContentColumn()
            .padding(.bottom, insidePanel ? 0 : 16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.kind == .volume ? "Volume" : "Brightness")
            .accessibilityValue(Self.spoken(state))
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }

    /// The number, or what stands in for it when there is no number to give.
    private static func readout(_ state: LevelHUD) -> String {
        if state.isUnavailable { return "\u{2014}" }
        return state.isMuted ? "Muted" : "\(Int((state.level * 100).rounded()))%"
    }

    /// "62 percent, AirPods Pro" — the output is worth saying out loud too.
    private static func spoken(_ state: LevelHUD) -> String {
        var parts = [state.isUnavailable ? "Not set here"
                     : (state.isMuted ? "Muted" : "\(Int((state.level * 100).rounded())) percent")]
        if let device = state.device { parts.append(device) }
        return parts.joined(separator: ", ")
    }
}
