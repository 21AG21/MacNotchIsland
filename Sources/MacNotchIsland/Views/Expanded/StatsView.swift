import SwiftUI

/// The panel's Stats section: processor, memory, disk, network and battery health across one
/// row, each cell a small grey label over a big white number with its own trace or bar under
/// it. Sampling only runs while this view is on screen.
struct StatsView: View {
    @ObservedObject private var stats = SystemStats.shared

    private static let valueFont = Font.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit()
    private static let smallValueFont = Font.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()
    private static let detailFont = Font.system(size: 10)

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
                .contentTransition(.numericText())
                .animation(IslandMotion.digits, value: stats.sample.cpuPercent)
        } footer: {
            Sparkline(values: stats.cpuHistory, ceiling: 20)
                .frame(height: 30)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU")
        .accessibilityValue("\(Int(stats.sample.cpuPercent.rounded())) percent")
    }

    /// The headline is the share in use, so the row reads as one scale across five columns
    /// rather than one column of gigabytes among four percentages; the gigabytes are the
    /// small print under the bar, where the disk's free space is.
    private var memoryCell: some View {
        cell(label: "Memory") {
            Text(memoryValue)
                .font(Self.valueFont)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(IslandMotion.digits, value: memoryValue)
        } footer: {
            MeterBar(fraction: fraction(stats.sample.memoryUsedBytes, of: stats.sample.memoryTotalBytes))
                .accessibilityHidden(true)
            Text(memoryDetail)
                .font(Self.detailFont)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory")
        .accessibilityValue("\(memoryValue), \(memoryDetail)")
    }

    private var diskCell: some View {
        cell(label: "Disk") {
            Text(diskValue)
                .font(Self.valueFont)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(IslandMotion.digits, value: diskValue)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } footer: {
            // A volume that will not say how full it is gets the em dash and nothing else,
            // rather than an empty bar and a line explaining itself.
            if let detail = diskDetail {
                MeterBar(fraction: fraction(stats.sample.diskUsedBytes, of: stats.sample.diskTotalBytes))
                    .accessibilityHidden(true)
                Text(detail)
                    .font(Self.detailFont)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk")
        .accessibilityValue(diskDetail ?? "Not available")
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
            .padding(.top, 1)
            .contentTransition(.numericText())
            .animation(IslandMotion.digits, value: stats.sample.networkDownBytesPerSec)
        } footer: {
            Sparkline(values: stats.networkHistory, ceiling: 64 * 1024)
                .frame(height: 22)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network")
        .accessibilityValue("Download \(SystemStats.rateText(stats.sample.networkDownBytesPerSec)), upload \(SystemStats.rateText(stats.sample.networkUpBytesPerSec))")
    }

    /// The laptop question, in the order it is asked: how much is left, then for how long,
    /// then how the battery is ageing.
    private var batteryCell: some View {
        cell(label: "Battery") {
            Text(batteryValue)
                .font(Self.valueFont)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(IslandMotion.digits, value: batteryValue)
        } footer: {
            if let percent = stats.sample.batteryPercent {
                MeterBar(fraction: Double(percent) / 100)
                    .accessibilityHidden(true)
                if let time = batteryTime {
                    Text(time)
                        .font(Self.detailFont)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            if let detail = batteryDetail {
                Text(detail)
                    .font(Self.detailFont)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(batteryAccessibilityValue)
    }

    /// "3 h 40 min left", "48 min to full", or "Plugged in" when there is no estimate.
    private var batteryTime: String? {
        guard stats.sample.batteryPercent != nil else { return nil }
        guard let minutes = stats.sample.batteryMinutesRemaining else {
            return stats.sample.batteryCharging ? "Charging" : nil
        }
        let duration = BatteryFormatting.formatMinutes(minutes)
        return stats.sample.batteryCharging ? "\(duration) to full" : "\(duration) left"
    }

    /// "82 percent, 3 h 40 min left, 91 percent health", or "Not available" on a desktop.
    private var batteryAccessibilityValue: String {
        guard let percent = stats.sample.batteryPercent else { return "Not available" }
        var parts = ["\(percent) percent"]
        if let time = batteryTime { parts.append(time) }
        if let detail = batteryDetail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    /// How much charge is left, or an em dash on a Mac with no battery to ask.
    private var batteryValue: String {
        guard let percent = stats.sample.batteryPercent else { return "—" }
        return "\(percent)%"
    }

    /// "91% health · 214 cycles", dropping whatever the battery did not report. Health belongs
    /// under the charge, not instead of it.
    private var batteryDetail: String? {
        var parts: [String] = []
        if let health = stats.sample.batteryHealthPercent { parts.append("\(Int(health.rounded()))% health") }
        if let cycles = stats.sample.cycleCount { parts.append("\(cycles) cycles") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How full the disk is, as a percentage: the number people actually watch.
    private var diskValue: String {
        guard stats.sample.diskTotalBytes > 0 else { return "—" }
        return Self.percentText(fraction(stats.sample.diskUsedBytes, of: stats.sample.diskTotalBytes) * 100)
    }

    /// How full the memory is, as a percentage: the same scale as the CPU and the disk.
    private var memoryValue: String {
        guard stats.sample.memoryTotalBytes > 0 else { return "\u{2014}" }
        return Self.percentText(fraction(stats.sample.memoryUsedBytes, of: stats.sample.memoryTotalBytes) * 100)
    }

    /// "17.1 / 22.4 GB" under the bar, where the disk puts what is free.
    private var memoryDetail: String {
        guard stats.sample.memoryTotalBytes > 0 else { return " " }
        return SystemStats.memoryText(used: stats.sample.memoryUsedBytes, total: stats.sample.memoryTotalBytes)
    }

    /// "412 GB free", or nothing at all when the volume did not answer.
    private var diskDetail: String? {
        let total = stats.sample.diskTotalBytes
        guard total > 0 else { return nil }
        let free = total - min(total, stats.sample.diskUsedBytes)
        return "\(SystemStats.gigabytes(free)) GB free"
    }

    private func fraction(_ part: UInt64, of whole: UInt64) -> Double {
        guard whole > 0 else { return 0 }
        return min(1, max(0, Double(part) / Double(whole)))
    }

    // MARK: - Furniture

    /// One column of the row: the name at the top, the number under it, and whatever draws
    /// the shape of that number - a trace, a bar, a line of detail - sitting on the section's
    /// floor. Pinning the footer down is what makes five columns of unequal content read as
    /// one row, and fills the section rather than leaving 50 pt of black beneath it.
    private func cell<Value: View, Footer: View>(label: String,
                                                 @ViewBuilder value: () -> Value,
                                                 @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
            value()
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 4) { footer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The hairline between two columns, the same distance from each. It used to sit 16 pt
    /// from the column on its left and 14 from the one on its right.
    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, Self.gutter)
            .accessibilityHidden(true)
    }

    /// Half the space between two columns: the hairline stands in the middle of it.
    static let gutter: CGFloat = 14

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
