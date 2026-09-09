import AppKit
import SwiftUI

// MARK: - Shelf

struct ShelfSectionView: View {
    var isDropTarget: Bool

    var body: some View {
        ShelfStripView(isDropTarget: isDropTarget, wide: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Clipboard

struct ClipboardSectionView: View {
    @ObservedObject private var store = ClipboardStore.shared
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            SectionHeader(store.items.isEmpty ? "Clipboard" : "Clipboard · \(store.items.count) \(store.items.count == 1 ? "item" : "items")") {
                if !store.items.isEmpty {
                    searchField
                    PillButton(title: "Clear", tint: .white.opacity(0.85)) { store.clear() }
                }
            }
            ClipboardView(query: query)
        }
        .onDisappear { query = "" }
    }

    /// Filters the list as you type. Typing needs the island to be the key window, which it is
    /// while this section is open: `ActivityCenter.wantsKeyboard`.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityHidden(true)
            if RenderMode.isGallery {
                // The real field takes the width and pushes the magnifier to the leading
                // edge; the stand-in has to do the same or the gallery lies about it.
                Text("Search")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Search the clipboard")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 170, height: 22)
        .background(Capsule().fill(Color.white.opacity(0.08)))
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

    /// Two rows and the rule between them, measured so they fill the section exactly: the
    /// header and its gap, 64 pt of buttons, the hairline with the same air above and below
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

    static let actionsRow: CGFloat = 64
    static let timerRowHeight: CGFloat = 28
    /// The air above and below the hairline between the two rows.
    static let ruleGap: CGFloat = 8

    private var timerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 16, alignment: .leading)
                .accessibilityHidden(true)
            ForEach([1, 5, 10, 25], id: \.self) { minutes in
                PillButton(title: "\(minutes)m") {
                    IslandTimer.shared.start(seconds: TimeInterval(minutes * 60), label: "Timer")
                }
                .accessibilityLabel("Start \(minutes) minute timer")
            }
            PillButton(title: "Pomodoro") { IslandTimer.shared.startPomodoro() }
            if timers.state != nil {
                PillButton(title: "Cancel", tint: .white.opacity(0.7)) { IslandTimer.shared.cancel() }
            }
            Spacer(minLength: 0)
            PillButton(title: stopwatch.state == nil ? "Stopwatch" : "Stop", symbol: "stopwatch.fill") {
                if stopwatch.state == nil { stopwatch.start() } else { stopwatch.reset() }
            }
        }
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
                    Text("Jot something down. It stays here, on this Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
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
                PillButton(title: "Activity Monitor", symbol: "arrow.up.forward", tint: .white.opacity(0.85)) {
                    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            StatsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
