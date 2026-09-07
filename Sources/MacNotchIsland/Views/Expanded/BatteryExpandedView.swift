import SwiftUI

struct BatteryExpandedView: View {
    let state: BatteryState
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(spacing: 16) {
                BatteryGlyph(percent: state.percent, charging: state.isCharging || state.isPluggedIn, tint: state.tint)
                    .frame(width: 52, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(state.tint)
                    Text("\(state.percent)%")
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                Spacer()
                if state.event == .low || state.event == .critical {
                    Text("Connect to power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
    }
}
