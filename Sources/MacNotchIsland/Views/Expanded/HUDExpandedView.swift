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
                    // No bar where there is no level: an empty one says "turned all the way
                    // down", which is not what an output that sets its own level means.
                    if !state.isUnavailable {
                        LevelBar(level: state.isMuted ? 0 : state.level, tint: .white)
                            .frame(height: 4)
                    }
                    // The device, or — where there is no device to name, as on a display that
                    // will not be set — what to do about it. Something, either way: the row
                    // was otherwise a glyph, a gap and a dash.
                    if let line = state.device ?? (state.isUnavailable ? LevelHUD.unavailableHint(state) : nil) {
                        Text(line)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                // The bar is the only thing in this row that wants width, so without it the
                // card would shrink to its contents and re-centre — a different shape for one
                // state out of three.
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
                Text(LevelHUD.readout(state))
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

    /// "62 percent, AirPods Pro" — the output is worth saying out loud too.
    private static func spoken(_ state: LevelHUD) -> String {
        var parts = [state.isUnavailable ? "Not set here"
                     : (state.isMuted ? "Muted" : "\(Int((state.level * 100).rounded())) percent")]
        if let device = state.device { parts.append(device) }
        return parts.joined(separator: ", ")
    }
}
