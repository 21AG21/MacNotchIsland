import SwiftUI

struct BluetoothExpandedView: View {
    let state: BluetoothState
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(spacing: 16) {
                Image(systemName: state.symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(state.isConnected ? "Connected" : "Disconnected")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                HStack(spacing: 14) {
                    if let l = state.batteryLeft { ring(l, label: "L") }
                    if let r = state.batteryRight { ring(r, label: "R") }
                    if let c = state.batteryCase { ring(c, label: "Case") }
                    if state.batteryLeft == nil, state.batteryRight == nil, let s = state.batterySingle { ring(s, label: "") }
                }
            }
            .padding(.horizontal, IslandInsets.horizontal)
            .padding(.bottom, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    /// "AirPods Pro connected, left 92 percent, right 88 percent, case 64 percent", built from
    /// whichever batteries the device actually reports.
    private var accessibilitySummary: String {
        var parts = [state.isConnected ? "\(state.name) connected" : "\(state.name) disconnected"]
        if let l = state.batteryLeft { parts.append("left \(l) percent") }
        if let r = state.batteryRight { parts.append("right \(r) percent") }
        if let c = state.batteryCase { parts.append("case \(c) percent") }
        if state.batteryLeft == nil, state.batteryRight == nil, let s = state.batterySingle {
            parts.append("\(s) percent battery")
        }
        return parts.joined(separator: ", ")
    }

    private func ring(_ percent: Int, label: String) -> some View {
        VStack(spacing: 3) {
            ProgressRing(progress: Double(percent) / 100, lineWidth: 3, tint: percent <= 20 ? Color.named("red") : Color.named("green"))
                .frame(width: 30, height: 30)
                .overlay(
                    Text("\(percent)%")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                )
            if !label.isEmpty {
                Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
