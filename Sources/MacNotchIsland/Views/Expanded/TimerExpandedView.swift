import SwiftUI

/// The Clock app's Timers tab as it appears inside the island: an orange ring, the label, the
/// countdown in large rounded digits, and the pause / cancel controls. Extra timers stack
/// underneath in one compact row each, most recent first.
struct TimerExpandedView: View {
    let state: TimerState
    let geometry: NotchGeometry
    @ObservedObject private var store = IslandTimer.shared
    @Environment(\.insidePanel) private var insidePanel

    init(state: TimerState, geometry: NotchGeometry) {
        self.state = state
        self.geometry = geometry
    }

    /// At most two extra rows fit inside the expanded height.
    private static let maxOtherRows = 2

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(alignment: .center, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(alignment: .center, spacing: 14) {
                        ring(at: context.date)
                        // The eyebrow tucks into the whitespace above the digits' cap height,
                        // which is why the stack closes up rather than spacing out.
                        VStack(alignment: .leading, spacing: -4) {
                            header
                            let remaining = state.isFinished ? "0:00" : state.remaining(at: context.date).timerString
                            Text(remaining)
                                .font(.system(size: 40, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                                // A timeline's tick carries no animation of its own, so the
                                // numeric transition declared here never actually ran: the
                                // digits were swapped, not rolled. This is what rolls them.
                                .contentTransition(.numericText(countsDown: true))
                                .animation(IslandMotion.digits, value: remaining)
                                // While the matched frame is still pill-sized the 40 pt digits scale
                                // down to fit instead of truncating, so they read as growing.
                                .lineLimit(1)
                                .minimumScaleFactor(0.25)
                                .islandMatched(IslandMatchedID.timerTime)
                        }
                    }
                    // Ring, headline, session dots and digits as one sentence; the pause and
                    // cancel controls beside them keep their own labels.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenLabel(at: context.date))
                }
                Spacer(minLength: 0)
                // Two circles of the same weight, told apart by colour rather than by shape:
                // the timer's own orange for what it does next, white for cancelling it.
                HStack(spacing: 10) {
                    if state.isFinished {
                        CircleActionButton(symbol: "arrow.counterclockwise", tint: .orange, label: "Repeat") { IslandTimer.shared.repeatLast() }
                    } else {
                        CircleActionButton(symbol: state.isPaused ? "play.fill" : "pause.fill", tint: .orange,
                                           label: state.isPaused ? "Resume" : "Pause") {
                            state.isPaused ? IslandTimer.shared.resume() : IslandTimer.shared.pause()
                        }
                    }
                    CircleActionButton(symbol: "xmark", tint: .white, label: "Cancel") { IslandTimer.shared.cancel() }
                }
            }
            .islandContentColumn()
            .padding(.bottom, others.isEmpty && !insidePanel ? 16 : 0)
            if !others.isEmpty { otherTimers }
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
    }

    // MARK: - The timer that owns the island

    private func ring(at date: Date) -> some View {
        ProgressRing(progress: state.isFinished ? 1 : state.progress(at: date), lineWidth: 3, tint: .orange)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: ringSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    // The glyph is the thing that can pulse; the same modifier on the digits
                    // beside it was quietly doing nothing, because a symbol effect needs a
                    // symbol. A timer's phases swap here too, so they cross over rather than
                    // cutting: timer to cup at the break, cup to bell when it rings.
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: state.isFinished)
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
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            if let phase = pomodoro { sessionDots(phase) }
        }
    }

    /// Cancelling is the quietest thing on the card: a bare glyph, no disc, but still a
    /// 40 pt target to hit.
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
        .islandContentColumn()
    }

    private func otherRow(_ entry: TimerEntry, at date: Date, hidden: Int) -> some View {
        HStack(spacing: 8) {
            ProgressRing(progress: entry.state.isFinished ? 1 : entry.state.progress(at: date),
                         lineWidth: 2, tint: .orange)
                .frame(width: 13, height: 13)
                .accessibilityHidden(true)
            Text(entry.label)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            let remaining = entry.state.isFinished ? "0:00" : entry.state.remaining(at: date).timerString
            Text(remaining)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(IslandMotion.digits, value: remaining)
                .lineLimit(1)
            if entry.state.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Button(action: { IslandTimer.shared.cancel(id: entry.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("Cancel \(entry.label)")
        }
        .frame(height: IslandTimer.rowHeight)
        .accessibilityElement(children: .contain)
    }
}
