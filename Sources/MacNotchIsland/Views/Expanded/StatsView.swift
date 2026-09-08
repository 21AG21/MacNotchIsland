import SwiftUI

/// The panel's Stats section: processor, memory, disk, network and battery health across one
/// row, each cell a small grey label over a big white number with its own trace or bar under
/// it. Sampling only runs while this view is on screen.
struct StatsView: View {
    @ObservedObject private var stats = SystemStats.shared

    private static let valueFont = Font.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit()
    private static let smallValueFont = Font.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cpuCell
            divider
            memoryCell
            divider
            diskCell
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
            Sparkline(values: stats.cpuHistory, ceiling: 20)
                .frame(height: 22)
                .padding(.top, 4)
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
            MeterBar(fraction: fraction(stats.sample.memoryUsedBytes, of: stats.sample.memoryTotalBytes))
                .padding(.top, 10)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory")
        .accessibilityValue(SystemStats.memoryText(used: stats.sample.memoryUsedBytes, total: stats.sample.memoryTotalBytes))
    }

    private var diskCell: some View {
        cell(label: "Disk") {
            Text(diskValue)
                .font(Self.valueFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            MeterBar(fraction: fraction(stats.sample.diskUsedBytes, of: stats.sample.diskTotalBytes))
                .padding(.top, 10)
                .accessibilityHidden(true)
            Text(diskDetail)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk")
        .accessibilityValue(diskDetail)
    }

    private var networkCell: some View {
        cell(label: "Network") {
            VStack(alignment: .leading, spacing: 1) {
                Text("↓ " + SystemStats.rateText(stats.sample.networkDownBytesPerSec))
                    .font(Self.smallValueFont)
                    .foregroundStyle(.white)
                Text("↑ " + SystemStats.rateText(stats.sample.networkUpBytesPerSec))
                    .font(Self.smallValueFont)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .lineLimit(1)
            .padding(.top, 2)
            Sparkline(values: stats.networkHistory, ceiling: 64 * 1024)
                .frame(height: 18)
                .padding(.top, 4)
                .accessibilityHidden(true)
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
                    .padding(.top, 2)
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

    /// How full the disk is, as a percentage: the number people actually watch.
    private var diskValue: String {
        guard stats.sample.diskTotalBytes > 0 else { return "—" }
        return Self.percentText(fraction(stats.sample.diskUsedBytes, of: stats.sample.diskTotalBytes) * 100)
    }

    /// "412 GB free of 1 TB".
    private var diskDetail: String {
        let total = stats.sample.diskTotalBytes
        guard total > 0 else { return "Not available" }
        let free = total - min(total, stats.sample.diskUsedBytes)
        return "\(SystemStats.memoryFormatter.string(fromByteCount: Int64(clamping: free))) free"
    }

    private func fraction(_ part: UInt64, of whole: UInt64) -> Double {
        guard whole > 0 else { return 0 }
        return min(1, max(0, Double(part) / Double(whole)))
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
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 74)
            .padding(.trailing, 14)
            .accessibilityHidden(true)
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

/// How full something is: a thin capsule, filled from the left.
private struct MeterBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: max(0, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

/// A flat line of recent readings. Scaled to the busiest reading in the window (never below
/// `ceiling`), so an idle Mac shows a quiet trace rather than noise blown up to full height.
private struct Sparkline: View {
    let values: [Double]
    var ceiling: Double

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1, proxy.size.width > 0, proxy.size.height > 0 else { return }
                let top = max(ceiling, values.max() ?? 0)
                let step = proxy.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step,
                                        y: proxy.size.height * (1 - CGFloat(min(max(value, 0), top) / top)))
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
