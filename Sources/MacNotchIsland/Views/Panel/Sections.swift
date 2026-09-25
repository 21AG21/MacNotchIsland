import AppKit
import SwiftUI

// MARK: - Shelf

struct ShelfSectionView: View {
    var isDropTarget: Bool

    var body: some View {
        ShelfStripView(isDropTarget: isDropTarget)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Clear

/// What the Clear pill on the three lists says: the shelf, the clipboard and the notifications.
///
/// "Clear" while nothing is typed, and with a find up the number it is about to take — the
/// matches, never the rows the find is hiding. Ten files on the shelf, "pdf" typed and two
/// showing: the pill said "Clear" and emptied all ten, and the eight nobody could see went with
/// no way back.
enum ClearPill {
    static func title(clearing count: Int, query: String?) -> String {
        PanelFind.needle(query) == nil ? "Clear" : "Clear \(count)"
    }
}

// MARK: - Clipboard

struct ClipboardSectionView: View {
    @ObservedObject private var store = ClipboardStore.shared
    /// The find is the panel's, not this view's: it is opened by typing on the section as
    /// much as by clicking the glass, and it has to survive the row that is redrawn under it.
    @ObservedObject private var center = ActivityCenter.shared

    private var matches: [ClipboardItem] { ClipboardView.ordered(store.items, query: center.findQuery) }

    /// The row the arrows are on, which Return would put back on the pasteboard.
    private var foundID: UUID? {
        guard let index = center.findTarget(of: matches.count) else { return nil }
        return matches[index].id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            SectionHeader(store.items.isEmpty ? "Clipboard" : "Clipboard · \(store.items.count) \(store.items.count == 1 ? "item" : "items")") {
                // The glass appears with the first copy; a find already under way keeps its
                // field whatever the list does, so an entry expiring underneath it never
                // takes the caret away mid-word.
                if !store.items.isEmpty || center.findQuery != nil {
                    // Return puts the first match back on the pasteboard: type three letters
                    // of something copied an hour ago and press Return, without ever leaving
                    // the keyboard or looking at the list.
                    FindField(matches: matches.count) {
                        guard let index = center.findTarget(of: matches.count) else { return }
                        store.pick(item: matches[index])
                    }
                }
                // A pin is somebody saying "keep this", and Clear is not them taking it back:
                // the pill takes what is not pinned, so a list of nothing but pins has none.
                let clearable = ClipboardStore.clearing(store.items, query: center.findQuery)
                if store.clearedItems != nil {
                    // Where the Clear was, for the moment the offer stands. A copy arriving in
                    // the meantime must not turn the pill back into a Clear under the pointer.
                    PillButton(title: "Undo Clear", tint: .white.opacity(0.85)) { store.undoClear() }
                } else if !clearable.isEmpty {
                    PillButton(title: ClearPill.title(clearing: clearable.count, query: center.findQuery),
                               tint: .white.opacity(0.85)) {
                        store.clear(matching: center.findQuery)
                    }
                }
            }
            ClipboardView(query: center.findQuery ?? "", found: foundID)
        }
    }
}

// MARK: - Actions

/// Favourite Shortcuts as round buttons, and the timer presets, which are actions too.
struct ActionsSectionView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared
    /// Watched only so the header knows whether the row below it is empty.
    @ObservedObject private var apps = FavoriteApps.shared
    @ObservedObject private var timers = IslandTimer.shared
    /// Watched, not merely read: the pill's title is "Stopwatch" or "Stop" depending on it,
    /// and the row was only ever redrawn because something else in the panel happened to
    /// change at the same moment.
    @ObservedObject private var stopwatch = IslandStopwatch.shared
    /// The timer entry is the panel's find, see `TimerEntryField`.
    @ObservedObject private var center = ActivityCenter.shared

    /// Two rows and the rule between them, measured so they fill the section exactly: the
    /// header and its gap, 65.5 pt of buttons, the hairline with 8 pt of air above and below
    /// it, and the presets on the floor. Uniform stack spacing plus the rule's own padding
    /// used to leave 27 pt of black under the presets.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Actions") {
                // Nothing to edit yet means the empty row below is already offering the only
                // thing there is to do, in more words and with the reason for it. Two pills
                // on one screen opening the same pane of Settings is one pill.
                if !isEmpty {
                    PillButton(title: "Edit", tint: .white.opacity(0.85)) { QuickActionsRowView.openSettings() }
                }
            }
            Color.clear.frame(height: SectionMetrics.gapBelowHeader)
            QuickActionsRowView()
                .frame(height: Self.actionsRow)
            Spacer(minLength: Self.ruleGap)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .accessibilityHidden(true)
            Spacer(minLength: Self.ruleGap)
            timerRow
                .frame(height: Self.timerRowHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var isEmpty: Bool { runner.favorites.isEmpty && apps.apps.isEmpty }

    /// 65.5 rather than a round 64, so the two spacers come out at exactly `ruleGap` and the
    /// half-point hairline starts 103.5 pt down the section, on a whole pixel of a Retina
    /// display. At 64 the spacers shared 17.5 pt, 8.75 each, and the rule fell at 102.75 —
    /// between two pixels, drawn as a smudge across both.
    static let actionsRow: CGFloat = 65.5
    static let timerRowHeight: CGFloat = 28
    /// The air above and below the hairline between the two rows.
    static let ruleGap: CGFloat = 8
    /// Between one thing on the timer row and the next.
    static let timerRowSpacing: CGFloat = 8
    /// The timer glyph at the head of the row, drawn this wide so it hangs from the column
    /// the header does. It takes its clicks in `IslandHit.minimum`, a few points out either
    /// side — into the panel's margin and the gap before the first preset — so nothing on the
    /// row moves to make room for the target.
    static let timerGlyphWidth: CGFloat = 16

    /// Every word the stopwatch's pill can say. The pill keeps the width of the longest of
    /// them whichever it is showing: it sits at the far end of the row, so a pill that shrank
    /// from "Stopwatch" to "Stop" pulled its left edge 35 points out from under the pointer,
    /// and the click that was meant to stop the watch landed on nothing.
    static let stopwatchTitles = ["Stopwatch", "Stop", "Reset"]

    /// Stopwatch to start one, Stop while it runs, Reset once it has stopped — never Reset
    /// straight away, which used to take the laps with it. `isRunning` is nil with no
    /// stopwatch at all.
    static func stopwatchTitle(isRunning: Bool?) -> String {
        guard let isRunning else { return "Stopwatch" }
        return isRunning ? "Stop" : "Reset"
    }

    /// Whether the timer entry is up: the find, on this section.
    private var entryOpen: Bool { center.findQuery != nil && PanelFind.takesEntry(center.openSection) }

    private var timerRow: some View {
        HStack(spacing: Self.timerRowSpacing) {
            // The way in for a pointer, as the glass is on a list: typing a number is the other.
            Button(action: { ActivityCenter.shared.beginFind() }) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(entryOpen ? 0.3 : 0.55))
                    .frame(width: Self.timerGlyphWidth, height: Self.timerRowHeight, alignment: .leading)
                    // 16 across was 8 short of what the pointer is owed.
                    .hitOutset(horizontal: IslandHit.outset(drawn: Self.timerGlyphWidth), vertical: 0)
            }
            .buttonStyle(IslandButtonStyle())
            .disabled(entryOpen)
            .help("Type minutes for a timer, or a time for an alarm — or just start typing")
            .accessibilityLabel("Type a timer or an alarm")
            if entryOpen {
                // In place of the presets while it is up: what is typed is a preset of its own.
                TimerEntryField()
            } else {
                ForEach([1, 5, 10, 25], id: \.self) { minutes in
                    PillButton(title: "\(minutes)m") {
                        IslandTimer.shared.start(seconds: TimeInterval(minutes * 60), label: "Timer")
                    }
                    .accessibilityLabel("Start \(minutes) minute timer")
                }
                PillButton(title: "Pomodoro") { IslandTimer.shared.startPomodoro() }
            }
            if timers.state != nil {
                PillButton(title: "Cancel", tint: .white.opacity(0.7)) { IslandTimer.shared.cancel() }
            }
            if let soonest = timers.alarms.first {
                alarmPill(soonest, others: timers.alarms.count - 1)
            }
            Spacer(minLength: 0)
            stopwatchPill
        }
    }

    /// Stop means stop: it used to reset, and took the laps with it. Stopped, the same button
    /// clears it, and says so.
    ///
    /// Drawn here rather than as a `PillButton`, the way the alarm's capsule beside it is, and
    /// to the same measure as one — the same type, the same glyph, the same padding and fill —
    /// because it has to hold its width while its word changes: every word it can say is laid
    /// in the same place and only one of them shows, so the capsule is as wide as the longest
    /// whichever it is showing.
    private var stopwatchPill: some View {
        let title = Self.stopwatchTitle(isRunning: stopwatch.state?.isRunning)
        return Button(action: {
            if stopwatch.state == nil {
                stopwatch.start()
            } else if stopwatch.state?.isRunning == true {
                stopwatch.stop()
            } else {
                stopwatch.reset()
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 11, weight: .bold))
                ZStack {
                    ForEach(Self.stopwatchTitles, id: \.self) { word in
                        Text(word)
                            .font(.system(size: 12, weight: .semibold))
                            .opacity(word == title ? 1 : 0)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(IslandButtonStyle())
        // The words laid underneath are for the width only; this is what it says.
        .accessibilityLabel(title)
    }

    /// The next alarm, by the time it will ring, with a cross to take it back — and how many
    /// more are waiting behind it, which the menu bar and the island's menu list in full. One
    /// capsule, because the row has room for one beside the presets, the Cancel and the
    /// stopwatch; a second would push the stopwatch off the end.
    private func alarmPill(_ alarm: IslandAlarm, others: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "alarm.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(IslandAlarm.clock(alarm.fireDate) + (others > 0 ? " +\(others)" : ""))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
            Button(action: { IslandTimer.shared.cancelAlarm(id: alarm.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .hitOutset(drawn: 14)
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("Cancel the alarm at \(IslandAlarm.describe(alarm.fireDate))")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: Self.timerRowHeight)
        .background(Capsule().fill(Color.white.opacity(0.18)))
        .help(alarm.menuTitle() + (others > 0 ? ", and \(others) more" : "") + ". " + IslandAlarm.awakeNote)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Alarm, \(alarm.menuTitle())")
    }
}

// MARK: - Notes

struct NotesSectionView: View {
    @ObservedObject private var notes = NotesStore.shared
    @EnvironmentObject private var center: ActivityCenter
    // Qualified: the island has a `FocusState` of its own, the payload of a Focus activity.
    @SwiftUI.FocusState private var editing: Bool

    /// What `TextEditor` insets its text by on macOS.
    private static let editorInset: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            SectionHeader("Notes") {
                if !notes.text.isEmpty {
                    PillButton(title: "Copy", tint: .white.opacity(0.85)) { notes.copyAll() }
                    PillButton(title: "Clear", tint: .white.opacity(0.85)) { notes.clear() }
                } else if notes.clearedText != nil {
                    // The one click here that can lose a week of jottings is the one click
                    // that can be taken back. Offered only while the scratchpad is still
                    // empty, so it can never overwrite something typed since.
                    PillButton(title: "Undo Clear", tint: .white.opacity(0.85)) { notes.undoClear() }
                }
            }
            ZStack(alignment: .topLeading) {
                if RenderMode.isGallery {
                    Text(notes.text.isEmpty ? " " : notes.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: $notes.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // The editor keeps 5 pt of its own either side of the text. Taking
                        // that back is what puts a note's first character on the same column
                        // as the title above it, and its last on the same edge as the rail.
                        .padding(.horizontal, -Self.editorInset)
                        .focused($editing)
                        .accessibilityLabel("Notes")
                }
                if notes.text.isEmpty {
                    // 0.4, like every other line of small print in the panel. At 0.3 this was
                    // the one piece of running text in the app under the contrast a 13 pt line
                    // needs — and it is the line that tells you the section is for typing in.
                    Text("Jot something down. It stays here, on this Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        // The panel takes key status the moment this section is pinned open; the caret then
        // goes into the editor, so there is something to type into rather than a dead field.
        .onAppear {
            guard !RenderMode.isGallery, center.wantsKeyboard else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { editing = true }
        }
        .onDisappear { editing = false }
    }
}

// MARK: - Stats

struct StatsSectionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            SectionHeader("Stats") {
                PillButton(title: "Activity Monitor", symbol: "arrow.up.forward", symbolTrailing: true,
                           tint: .white.opacity(0.85)) {
                    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            StatsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
