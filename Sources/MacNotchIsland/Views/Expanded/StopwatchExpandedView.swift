import SwiftUI

struct StopwatchExpandedView: View {
    let state: StopwatchState
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(alignment: .center, spacing: 16) {
                TimelineView(.animation(minimumInterval: 0.1, paused: !state.isRunning)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.laps.isEmpty ? "Stopwatch" : "Lap \(state.laps.count + 1)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(Self.format(state.elapsed(at: context.date)))
                            .font(.system(size: 40, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(state.isRunning ? .orange : .white)
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

    private static func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let tenths = Int((t - Double(total)) * 10)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths) : String(format: "%02d:%02d.%d", m, s, tenths)
    }
}
