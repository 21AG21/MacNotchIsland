import SwiftUI

struct FocusExpandedView: View {
    let state: FocusState
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.named(state.tint).opacity(state.isOn ? 0.25 : 0.12))
                    Image(systemName: state.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(state.isOn ? Color.named(state.tint) : .white.opacity(0.6))
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(state.isOn ? "On" : "Off").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
            .accessibilityElement(children: .combine)
        }
    }
}
