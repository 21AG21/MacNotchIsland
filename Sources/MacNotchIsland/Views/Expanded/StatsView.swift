import SwiftUI

/// The Home panel's "Stats" tab: CPU, memory, network and battery health in one row of
/// the black panel, each cell a small grey label over a big white number. Sampling only
/// runs while this view is on screen.
struct StatsView: View {
    @ObservedObject private var stats = SystemStats.shared

    private static let valueFont = Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
    private static let smallValueFont = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cpuCell
            divider
            memoryCell
            divider
            networkCell
            divider
            batteryCell
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { SystemStats.shared.start() }
        .onDisappear { SystemStats.shared.stop() }
    }

    // MARK: - Cells

    private var cpuCell: some View {
        cell(label: "CPU") {
            Text(Self.percentText(stats.sample.cpuPercent))
                .font(Self.valueFont)
                .foregroundStyle(.white)
            CPUSparkline(values: stats.cpuHistory)
                .frame(height: 16)
                .padding(.top, 3)
                .padding(.trailing, 14)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU")
        .accessibilityValue("\(Int(stats.sample.cpuPercent.rounded())) percent")
    }

    private var memoryCell: some View {
        cell(label: "Memory") {
            Text(SystemStats.memoryText(used: stats.sample.memoryUsedBytes, total: stats.sample.memoryTotalBytes))
                .font(Self.valueFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory")
        .accessibilityValue(SystemStats.memoryText(used: stats.sample.memoryUsedBytes, total: stats.sample.memoryTotalBytes))
    }

    private var networkCell: some View {
        cell(label: "Network") {
            VStack(alignment: .leading, spacing: 2) {
                Text("↓ " + SystemStats.rateText(stats.sample.networkDownBytesPerSec))
                    .font(Self.smallValueFont)
                    .foregroundStyle(.white)
                Text("↑ " + SystemStats.rateText(stats.sample.networkUpBytesPerSec))
                    .font(Self.smallValueFont)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .lineLimit(1)
            .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network")
        .accessibilityValue("Download \(SystemStats.rateText(stats.sample.networkDownBytesPerSec)), upload \(SystemStats.rateText(stats.sample.networkUpBytesPerSec))")
    }

    private var batteryCell: some View {
        cell(label: "Battery") {
            Text(batteryValue)
                .font(Self.valueFont)
                .foregroundStyle(.white)
            if let detail = batteryDetail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(batteryAccessibilityValue)
    }

    /// "92 percent, 214 cycles · 31°", or "Not available" on a Mac with no battery.
    private var batteryAccessibilityValue: String {
        guard let health = stats.sample.batteryHealthPercent else { return "Not available" }
        var value = "\(Int(health.rounded())) percent"
        if let detail = batteryDetail { value += ", \(detail)" }
        return value
    }

    /// Battery health, or an em dash on a Mac that has no battery to ask.
    private var batteryValue: String {
        guard let health = stats.sample.batteryHealthPercent else { return "—" }
        return "\(Int(health.rounded()))%"
    }

    /// "214 cycles · 31°", dropping whichever half the battery did not report.
    private var batteryDetail: String? {
        var parts: [String] = []
        if let cycles = stats.sample.cycleCount { parts.append("\(cycles) cycles") }
        if let temperature = stats.sample.batteryTemperatureC { parts.append("\(Int(temperature.rounded()))°") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Furniture

    private func cell<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 52)
            .padding(.trailing, 12)
            .accessibilityHidden(true)
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

/// A flat line of the recent CPU readings. Scaled to the busiest reading in the window
/// (with a floor) so an idle Mac still shows a trace rather than a dead flat line.
private struct CPUSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1, proxy.size.width > 0, proxy.size.height > 0 else { return }
                let ceiling = max(20, values.max() ?? 0)
                let step = proxy.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let clamped = min(max(value, 0), 100)
                    let point = CGPoint(x: CGFloat(index) * step,
                                        y: proxy.size.height * (1 - CGFloat(clamped / ceiling)))
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(Color.white.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }
}
