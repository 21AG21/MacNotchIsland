import SwiftUI

struct BluetoothExpandedView: View {
    let state: BluetoothState
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    /// One battery the device reports: "L 92%", "Case 64%", or a single unlabelled figure.
    private struct Reading: Identifiable {
        let label: String
        let percent: Int
        var id: String { label }
    }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                Image(systemName: state.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.isConnected ? "Connected" : "Disconnected")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                // One right-aligned line of figures rather than a row of donuts: the label is
                // small and quiet, the number carries the weight.
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    ForEach(readings) { reading in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if !reading.label.isEmpty {
                                Text(reading.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            Text("\(reading.percent)%")
                                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(valueTint(reading.percent))
                        }
                    }
                }
            }
            .padding(.horizontal, IslandInsets.horizontal)
            .padding(.bottom, insidePanel ? 0 : 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }

    /// Whichever batteries the device actually reports, left to right.
    private var readings: [Reading] {
        var out: [Reading] = []
        if let l = state.batteryLeft { out.append(Reading(label: "L", percent: l)) }
        if let r = state.batteryRight { out.append(Reading(label: "R", percent: r)) }
        if let c = state.batteryCase { out.append(Reading(label: "Case", percent: c)) }
        if state.batteryLeft == nil, state.batteryRight == nil, let s = state.batterySingle {
            out.append(Reading(label: "", percent: s))
        }
        return out
    }

    /// Only the emptiest battery goes red, and only once it is genuinely low.
    private func valueTint(_ percent: Int) -> Color {
        let lowest = readings.map({ $0.percent }).min()
        return (percent <= 20 && percent == lowest) ? Color.named("red") : Color.white
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
}
