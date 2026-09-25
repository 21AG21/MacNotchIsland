import SwiftUI

/// The Clock app's Timers tab as it appears inside the island: an orange ring, the label, the
/// countdown in large rounded digits, and the pause / cancel controls. Extra timers stack
/// underneath in one compact row each, most recent first.
struct TimerExpandedView: View {
    let state: TimerState
    let geometry: NotchGeometry
    /// The live activity this card is drawn for, where the caller knows it. Without it the
    /// card finds its timer by its state, see `shownID`.
    let activityID: String?
    @ObservedObject private var store = IslandTimer.shared
    @Environment(\.insidePanel) private var insidePanel

    init(state: TimerState, geometry: NotchGeometry, activityID: String? = nil) {
        self.state = state
        self.geometry = geometry
        self.activityID = activityID
    }

    /// At most two extra rows fit inside the expanded height.
    private static let maxOtherRows = 2

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            HStack(alignment: .center, spacing: 14) {
                TimelineView(.periodic(from: .now, by: TimerRing.cadence)) { context in
                    HStack(alignment: .center, spacing: 14) {
                        ring(at: context.date)
                        // The eyebrow tucks into the whitespace above the digits' cap height,
                        // which is why the stack closes up rather than spacing out.
                        VStack(alignment: .leading, spacing: -4) {
                            header
                            // An alarm has no countdown to show: it shows the time it rang for.
                            let remaining = state.alarmAt.map(IslandAlarm.clock)
                                ?? (state.isFinished ? "0:00" : state.remaining(at: context.date).timerString)
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
                // Circles of the same weight, told apart by colour rather than by shape: the
                // timer's own orange for what it does next, white for the rest.
                //
                // Every one of them names the timer on the card. They used to call the forms
                // that name none and act on the primary timer, so with the 25-minute timer
                // swapped onto the card, Cancel cancelled the 5-minute one underneath, Pause
                // paused it, and Resume asked a running timer to resume and did nothing.
                HStack(spacing: 10) {
                    if state.isAlarm {
                        // Repeat means nothing to an alarm. Nine minutes more does.
                        CircleActionButton(symbol: "zzz", tint: .orange, label: "Snooze") {
                            onShown { IslandTimer.shared.snooze(id: $0) }
                        }
                    } else if state.isFinished {
                        CircleActionButton(symbol: "arrow.counterclockwise", tint: .orange, label: "Repeat") {
                            onShown { IslandTimer.shared.repeatTimer(id: $0) }
                        }
                    } else {
                        CircleActionButton(symbol: state.isPaused ? "play.fill" : "pause.fill", tint: .orange,
                                           label: state.isPaused ? "Resume" : "Pause") {
                            let paused = state.isPaused
                            onShown { paused ? IslandTimer.shared.resume(id: $0) : IslandTimer.shared.pause(id: $0) }
                        }
                        // The thing everybody asks a smart speaker for, and the one thing a
                        // countdown could not be told. Nothing to add to once it has rung.
                        CircleActionButton(symbol: "plus", tint: .white, label: "Add a minute") {
                            onShown { IslandTimer.shared.add(seconds: IslandTimer.addStep, id: $0) }
                        }
                    }
                    CircleActionButton(symbol: "xmark", tint: .white, label: "Cancel") {
                        onShown { IslandTimer.shared.cancel(id: $0) }
                    }
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
        TimerRing(state: state, date: date, diameter: 44, lineWidth: 3)
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
        if state.isAlarm { return "alarm.fill" }
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

    private var headline: String { Self.headline(for: state) }

    /// The line over the countdown: the name the timer was given, and what has become of it.
    ///
    /// A finished timer used to say "Timer done" and drop the name — which is the one thing
    /// worth saying, because several timers can run at once and the card is how you tell
    /// which of them rang. Only a timer with no name of its own falls back to the generic
    /// sentence. Pure and static so the rule can be tested.
    static func headline(for state: TimerState) -> String {
        let name = state.label.trimmingCharacters(in: .whitespaces)
        // An alarm is not done, it is going off; its name is the whole of what to say, over
        // the time it went off for.
        if state.isAlarm { return name.isEmpty ? IslandAlarm.defaultLabel : name }
        let named = !name.isEmpty && name != "Timer"
        if state.isFinished { return named ? "\(name) done" : "Timer done" }
        if state.isPaused { return named ? "\(name) paused" : "Paused" }
        return state.label
    }

    /// "Timer, 4 minutes 59 seconds remaining", "Pasta timer paused, 1 minute remaining",
    /// "Timer done", "Focus, 24 minutes 59 seconds remaining, session 2 of 4".
    private func spokenLabel(at date: Date) -> String {
        if let alarmAt = state.alarmAt { return "\(Self.headline(for: state)), \(IslandAlarm.clock(alarmAt))" }
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

    /// Which timer this view is showing: the activity it was drawn for, when it was told, and
    /// otherwise the timer whose state it was handed, see `shownID(for:in:primary:)`.
    private var shownID: String? {
        activityID ?? Self.shownID(for: state, in: store.timers, primary: store.primary?.id)
    }

    /// Runs a control on the timer this card shows, and on nothing when that timer has gone.
    private func onShown(_ act: (String) -> Void) {
        guard let id = shownID else { return }
        act(id)
    }

    /// The timer a card handed `state` is about: the one whose state it is, and the primary
    /// timer only when none matches — the island's own card, drawn a moment before the list
    /// caught up. Pure, so the matching is tested.
    static func shownID(for state: TimerState, in timers: [TimerEntry], primary: String?) -> String? {
        timers.first(where: { $0.state == state })?.id ?? primary
    }

    private var others: [TimerEntry] {
        guard let id = shownID else { return [] }
        return store.timers.filter { $0.id != id }.sorted { $0.createdAt > $1.createdAt }
    }

    private var otherTimers: some View {
        let shown = Array(others.prefix(Self.maxOtherRows))
        let hidden = others.count - shown.count
        return TimelineView(.periodic(from: .now, by: TimerRing.cadence)) { context in
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
            TimerRing(state: entry.state, date: date, diameter: 13, lineWidth: 2)
                .accessibilityHidden(true)
            Text(entry.label)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            let remaining = entry.state.alarmAt.map(IslandAlarm.clock)
                ?? (entry.state.isFinished ? "0:00" : entry.state.remaining(at: date).timerString)
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
                // Laid out at 18, taking its click in the row's full 24.
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .hitOutset(drawn: 18)
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("Cancel \(entry.label)")
        }
        .frame(height: IslandTimer.rowHeight)
        .accessibilityElement(children: .contain)
    }
}
