import SwiftUI

struct StopwatchExpandedView: View {
    let state: StopwatchState
    let geometry: NotchGeometry

    @ObservedObject private var energy = EnergyPolicy.shared

    /// On battery (or once the energy policy has paused animation entirely) there's no point
    /// redrawing ten times a second for a digit nobody can read anyway.
    private var coarse: Bool { energy.isOnBattery || energy.animationsPaused }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(alignment: .center, spacing: 16) {
                TimelineView(.animation(minimumInterval: coarse ? 1 : 0.1, paused: !state.isRunning)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.laps.isEmpty ? "Stopwatch" : "Lap \(state.laps.count + 1)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(Self.format(state.elapsed(at: context.date), showTenths: !coarse))
                            .font(.system(size: 40, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(state.isRunning ? .orange : .white)
                            .contentTransition(.numericText(countsDown: false))
                            // Scales down rather than truncating while the matched frame is
                            // still the size of the compact pill's digits.
                            .lineLimit(1)
                            .minimumScaleFactor(0.25)
                            .islandMatched(IslandMatchedID.stopwatchTime)
                    }
                    // Heading and digits as one sentence; VoiceOver would otherwise read
                    // "01:05.3" as a bare number. The buttons keep their own labels.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenLabel(at: context.date))
                }
                Spacer(minLength: 0)
                if let lap = lastLap {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last lap").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        Text(Self.format(lap))
                            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Last lap, \(IslandAccessibility.spokenDuration(lap))")
                }
                if state.isRunning {
                    CircleActionButton(symbol: "flag.fill", tint: .white.opacity(0.85)) { IslandStopwatch.shared.lap() }
                    CircleActionButton(symbol: "stop.fill", tint: .orange) { IslandStopwatch.shared.stop() }
                } else {
                    CircleActionButton(symbol: "arrow.counterclockwise", tint: .white.opacity(0.85), label: "Reset") { IslandStopwatch.shared.reset() }
                    CircleActionButton(symbol: "play.fill", tint: .orange) { IslandStopwatch.shared.start() }
                }
            }
            .padding(.horizontal, IslandInsets.horizontal)
            .padding(.bottom, 14)
        }
    }

    /// The most recent lap's own duration (laps are stored as cumulative times).
    private var lastLap: TimeInterval? {
        guard let last = state.laps.last else { return nil }
        return last - (state.laps.dropLast().last ?? 0)
    }

    /// "Stopwatch, 1 minute 5 seconds, running" — "Stopwatch, lap 3, …" once laps have been taken.
    private func spokenLabel(at date: Date) -> String {
        let heading = state.laps.isEmpty ? "Stopwatch" : "Stopwatch, lap \(state.laps.count + 1)"
        let elapsed = IslandAccessibility.spokenDuration(state.elapsed(at: date))
        return "\(heading), \(elapsed), \(state.isRunning ? "running" : "paused")"
    }

    private static func format(_ t: TimeInterval, showTenths: Bool = true) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        guard showTenths else {
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        }
        let tenths = Int((t - Double(total)) * 10)
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths) : String(format: "%02d:%02d.%d", m, s, tenths)
    }
}
