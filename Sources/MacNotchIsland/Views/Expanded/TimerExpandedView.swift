import SwiftUI

struct TimerExpandedView: View {
    let state: TimerState
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(alignment: .center, spacing: 16) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.isFinished ? "Timer done" : (state.isPaused ? "Paused" : state.label))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(state.isFinished ? "0:00" : state.remaining(at: context.date).timerString)
                            .font(.system(size: 40, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.orange)
                            .contentTransition(.numericText(countsDown: true))
                            .symbolEffect(.pulse, isActive: state.isFinished)
                            // While the matched frame is still pill-sized the 40 pt digits scale
                            // down to fit instead of truncating, so they read as growing.
                            .lineLimit(1)
                            .minimumScaleFactor(0.25)
                            .islandMatched(IslandMatchedID.timerTime)
                    }
                }
                Spacer(minLength: 0)
                if state.isFinished {
                    CircleActionButton(symbol: "arrow.counterclockwise", tint: .orange) { IslandTimer.shared.repeatLast() }
                    CircleActionButton(symbol: "xmark", tint: .orange, filled: true) { IslandTimer.shared.cancel() }
                } else {
                    CircleActionButton(symbol: state.isPaused ? "play.fill" : "pause.fill", tint: .orange) {
                        state.isPaused ? IslandTimer.shared.resume() : IslandTimer.shared.pause()
                    }
                    CircleActionButton(symbol: "xmark", tint: .white.opacity(0.85)) { IslandTimer.shared.cancel() }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
    }
}
