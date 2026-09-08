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
                LevelBar(level: state.isMuted ? 0 : state.level, tint: .white)
                    .frame(height: 4)
                    .accessibilityHidden(true)
                Text(state.isMuted ? "Muted" : "\(Int((state.level * 100).rounded()))%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, IslandInsets.horizontal)
            .padding(.bottom, insidePanel ? 0 : 16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.kind == .volume ? "Volume" : "Brightness")
            .accessibilityValue(state.isMuted ? "Muted" : "\(Int((state.level * 100).rounded())) percent")
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }
}
