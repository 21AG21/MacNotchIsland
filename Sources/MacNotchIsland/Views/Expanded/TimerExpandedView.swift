import SwiftUI

/// The Clock app's Timers tab as it appears inside the island: an orange ring, the label, the
/// countdown in large rounded digits, and circular pause / cancel buttons. Extra timers stack
/// underneath in one compact row each, most recent first.
struct TimerExpandedView: View {
    let state: TimerState
    let geometry: NotchGeometry
    @ObservedObject private var store = IslandTimer.shared

    init(state: TimerState, geometry: NotchGeometry) {
        self.state = state
        self.geometry = geometry
    }

    /// At most two extra rows fit inside the expanded height.
    private static let maxOtherRows = 2

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 6)
            HStack(alignment: .center, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(alignment: .center, spacing: 14) {
                        ring(at: context.date)
                        VStack(alignment: .leading, spacing: 0) {
                            header
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
                    // Ring, headline, session dots and digits as one sentence; the pause and
                    // cancel buttons beside them keep their own labels.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenLabel(at: context.date))
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
            .padding(.horizontal, IslandInsets.horizontal)
            .padding(.bottom, others.isEmpty ? 14 : 6)
            if !others.isEmpty { otherTimers }
        }
    }

    // MARK: - The timer that owns the island

    private func ring(at date: Date) -> some View {
        ProgressRing(progress: state.isFinished ? 1 : state.progress(at: date), lineWidth: 3, tint: .orange)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: ringSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
            )
            .accessibilityHidden(true)
    }

    private var ringSymbol: String {
        if state.isFinished { return "bell.fill" }
        if let phase = pomodoro, phase.isBreak { return "cup.and.saucer.fill" }
        return "timer"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
            if let phase = pomodoro { sessionDots(phase) }
        }
    }

    private var headline: String {
        if state.isFinished { return pomodoro == nil ? "Timer done" : "\(state.label) done" }
        return state.isPaused ? "Paused" : state.label
    }

    /// "Timer, 4 minutes 59 seconds remaining", "Pasta timer paused, 1 minute remaining",
    /// "Timer done", "Focus, 24 minutes 59 seconds remaining, session 2 of 4".
    private func spokenLabel(at date: Date) -> String {
        let name: String
        if let phase = pomodoro {
            name = phase.name
        } else if state.label.isEmpty || state.label == "Timer" {
            name = "Timer"
        } else {
            name = "\(state.label) timer"
        }
        var label: String
        if state.isFinished {
            label = "\(name) done"
        } else {
            let remaining = IslandAccessibility.spokenDuration(state.remaining(at: date).rounded(.up))
            label = state.isPaused ? "\(name) paused, \(remaining) remaining" : "\(name), \(remaining) remaining"
        }
        if let phase = pomodoro { label += ", session \(phase.cycle) of \(phase.cycles)" }
        return label
    }

    /// The session indicator: one small dot per Pomodoro cycle, filled up to the current one.
    private func sessionDots(_ phase: PomodoroPhase) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, min(phase.cycles, 8)), id: \.self) { i in
                Circle()
                    .fill(i < phase.cycle ? Color.orange : Color.orange.opacity(0.3))
                    .frame(width: 4, height: 4)
            }
        }
        .accessibilityLabel("Session \(phase.cycle) of \(phase.cycles)")
    }

    /// The Pomodoro phase, when this is the timer running it.
    private var pomodoro: PomodoroPhase? {
        guard let phase = store.pomodoro, let id = shownID, id == store.pomodoroTimerID else { return nil }
        return phase
    }

    // MARK: - The other timers

    /// Which timer this view is showing. The expanded view is handed a state, not an id, so
    /// match it back to its entry and fall back to the primary timer.
    private var shownID: String? {
        store.timers.first(where: { $0.state == state })?.id ?? store.primary?.id
    }

    private var others: [TimerEntry] {
        guard let id = shownID else { return [] }
        return store.timers.filter { $0.id != id }.sorted { $0.createdAt > $1.createdAt }
    }

    private var otherTimers: some View {
        let shown = Array(others.prefix(Self.maxOtherRows))
        let hidden = others.count - shown.count
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                ForEach(shown) { entry in
                    otherRow(entry, at: context.date, hidden: entry.id == shown.last?.id ? hidden : 0)
                }
            }
        }
        .padding(.horizontal, IslandInsets.horizontal)
        .padding(.bottom, 8)
    }

    private func otherRow(_ entry: TimerEntry, at date: Date, hidden: Int) -> some View {
        HStack(spacing: 8) {
            ProgressRing(progress: entry.state.isFinished ? 1 : entry.state.progress(at: date),
                         lineWidth: 2, tint: .orange)
                .frame(width: 13, height: 13)
                .accessibilityHidden(true)
            Text(entry.label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Text(entry.state.isFinished ? "0:00" : entry.state.remaining(at: date).timerString)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.orange)
                .contentTransition(.numericText(countsDown: true))
                .lineLimit(1)
            if entry.state.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Button(action: { IslandTimer.shared.cancel(id: entry.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("Cancel \(entry.label)")
        }
        .frame(height: IslandTimer.rowHeight)
        .accessibilityElement(children: .contain)
    }
}
