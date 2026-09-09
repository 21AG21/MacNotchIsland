import SwiftUI

struct BatteryExpandedView: View {
    let state: BatteryState
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel

    /// Only a real warning colours the numeral; every other state reads in plain white.
    private var percentTint: Color {
        (state.event == .low || state.event == .critical) ? Color.named("red") : Color.white
    }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(spacing: 14) {
                BatteryGlyph(percent: state.percent, charging: state.isCharging || state.isPluggedIn, tint: state.tint)
                    .frame(width: 44, height: 21)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if BatteryFormatting.showsConnectToPower(for: state) {
                        Text("Connect to power")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                // One line beside the numeral, sitting on its baseline. Watts, cycles and
                // health stay in the accessibility label rather than crowding the card.
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    if let time = BatteryFormatting.timeLine(for: state) {
                        Text(time)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Text("\(state.percent)%")
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(percentTint)
                }
            }
            .islandContentColumn()
            .padding(.bottom, insidePanel ? 0 : 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BatteryFormatting.accessibilityLabel(for: state))

            // The panel has room the 440 pt card does not, and on a laptop this is the card
            // people open on purpose: the level as a bar, and how the battery is ageing.
            if insidePanel {
                VStack(alignment: .leading, spacing: 6) {
                    ChargeBar(percent: state.percent, tint: state.tint)
                    if let detail = BatteryFormatting.detailLine(for: state) {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                .islandContentColumn()
                .padding(.top, 12)
                .accessibilityHidden(true)
            }
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }
}

/// How full the battery is, as a bar the width of the card: the shape of the number above it.
private struct ChargeBar: View {
    let percent: Int
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: max(3, proxy.size.width * min(1, max(0, Double(percent) / 100))))
            }
        }
        .frame(height: 6)
    }
}

/// The strings behind the battery panel's detail lines, kept pure so they can be unit-tested.
enum BatteryFormatting {
    /// 134 is "2 h 14 min", 45 is "45 min", 120 is "2 h", 0 is "Less than a minute".
    static func formatMinutes(_ minutes: Int) -> String {
        let total = max(0, minutes)
        guard total > 0 else { return "Less than a minute" }
        let hours = total / 60
        let rest = total % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "+34.2 W" or "\u{2212}8.1 W" (a true minus sign); "0.0 W" when nothing measurable is flowing.
    static func formatWattage(_ watts: Double) -> String {
        guard watts.isFinite else { return "0.0 W" }
        let magnitude = String(format: "%.1f", abs(watts))
        guard magnitude != "0.0" else { return "0.0 W" }
        return (watts < 0 ? "\u{2212}" : "+") + magnitude + " W"
    }

    /// "2 h 14 min remaining" on battery or "1 h 5 min to full" while charging. Nil while macOS
    /// is still estimating, and nil on power when nothing is charging.
    static func timeLine(for state: BatteryState) -> String? {
        guard let minutes = estimatedMinutes(for: state) else { return nil }
        let duration = formatMinutes(minutes)
        return state.isCharging ? "\(duration) to full" : "\(duration) remaining"
    }

    /// "+34.2 W · 312 cycles · 91% health", dropping whatever the battery did not report.
    static func detailLine(for state: BatteryState) -> String? {
        var parts: [String] = []
        if let watts = state.wattage, watts.isFinite, abs(watts) >= 0.05 {
            parts.append(formatWattage(watts))
        }
        if let cycles = state.cycleCount {
            parts.append(cycles == 1 ? "1 cycle" : "\(cycles) cycles")
        }
        if let health = state.healthPercent {
            parts.append("\(health)% health")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The low and very-low alerts fall back to "Connect to power" when there is no estimate to show.
    static func showsConnectToPower(for state: BatteryState) -> Bool {
        (state.event == .low || state.event == .critical) && estimatedMinutes(for: state) == nil
    }

    /// "2 hours 14 minutes", "1 hour", "45 minutes", "less than a minute", for VoiceOver.
    static func spokenMinutes(_ minutes: Int) -> String {
        let total = max(0, minutes)
        guard total > 0 else { return "less than a minute" }
        let hours = total / 60
        let rest = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if rest > 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return parts.joined(separator: " ")
    }

    /// "Battery 63 percent, 2 hours 14 minutes until fully charged, charging at 34 watts, 312 cycles, 91 percent health".
    static func accessibilityLabel(for state: BatteryState) -> String {
        var parts = ["Battery \(state.percent) percent"]
        if let minutes = estimatedMinutes(for: state) {
            let spoken = spokenMinutes(minutes)
            parts.append(state.isCharging ? "\(spoken) until fully charged" : "\(spoken) remaining")
        }
        if let watts = state.wattage, watts.isFinite, abs(watts) >= 0.5 {
            let rounded = Int(abs(watts).rounded())
            let unit = rounded == 1 ? "1 watt" : "\(rounded) watts"
            parts.append(watts > 0 ? "charging at \(unit)" : "using \(unit)")
        }
        if let cycles = state.cycleCount {
            parts.append(cycles == 1 ? "1 cycle" : "\(cycles) cycles")
        }
        if let health = state.healthPercent {
            parts.append("\(health) percent health")
        }
        if showsConnectToPower(for: state) {
            parts.append("connect to power")
        }
        return parts.joined(separator: ", ")
    }

    /// The estimate worth showing: nil on power unless the battery is actually charging.
    private static func estimatedMinutes(for state: BatteryState) -> Int? {
        guard let minutes = state.timeRemainingMinutes else { return nil }
        guard state.isCharging || !state.isPluggedIn else { return nil }
        return minutes
    }
}
