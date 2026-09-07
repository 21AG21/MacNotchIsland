import SwiftUI

struct HUDExpandedView: View {
    let state: LevelHUD
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(spacing: 14) {
                Image(systemName: state.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28)
                    .contentTransition(.symbolEffect(.replace))
                LevelBar(level: state.isMuted ? 0 : state.level, tint: .white)
                    .frame(height: 8)
                Text(state.isMuted ? "Muted" : "\(Int((state.level * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
    }
}
