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
                }
                Spacer(minLength: 0)
                if let last = state.laps.last {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last lap").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        Text(Self.format(last - (state.laps.dropLast().last ?? 0)))
                            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                if state.isRunning {
                    CircleActionButton(symbol: "flag.fill", tint: .white.opacity(0.85)) { IslandStopwatch.shared.lap() }
                    CircleActionButton(symbol: "stop.fill", tint: .orange) { IslandStopwatch.shared.stop() }
                } else {
                    CircleActionButton(symbol: "arrow.counterclockwise", tint: .white.opacity(0.85)) { IslandStopwatch.shared.reset() }
                    CircleActionButton(symbol: "play.fill", tint: .orange) { IslandStopwatch.shared.start() }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
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
