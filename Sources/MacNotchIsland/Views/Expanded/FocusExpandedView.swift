import SwiftUI

struct FocusExpandedView: View {
    let state: FocusState
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    private var tint: Color { Color.named(state.tint) }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(state.isOn ? 0.18 : 0.10))
                    Image(systemName: state.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(state.isOn ? tint : Color.white.opacity(0.55))
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.isOn ? "On" : "Off")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .islandContentColumn()
            .padding(.bottom, insidePanel ? 0 : 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.isOn ? "\(state.name) on" : "\(state.name) off")
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }
}
