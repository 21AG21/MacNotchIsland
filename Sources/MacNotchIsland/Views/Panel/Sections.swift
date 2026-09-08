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
    @EnvironmentObject private var center: ActivityCenter
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(store.items.isEmpty ? "Clipboard" : "Clipboard · \(store.items.count) \(store.items.count == 1 ? "item" : "items")") {
                if !store.items.isEmpty {
                    searchField
                    PillButton(title: "Clear", tint: .white.opacity(0.85)) { store.clear() }
                }
            }
            ClipboardView(query: query)
        }
        .onAppear {
            guard !RenderMode.isGallery, !store.items.isEmpty else { return }
            center.setWantsKeyboard(true)
        }
        .onDisappear {
            query = ""
            center.setWantsKeyboard(false)
        }
    }

    /// Filters the list as you type. Typing needs the island to be the key window, which the
    /// section asks for while it shows and hands back when it goes.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityHidden(true)
            if RenderMode.isGallery {
                Text("Search")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
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
        .onTapGesture { NotchPanel.takeKeyboard() }
    }
}

// MARK: - Actions

/// Favourite Shortcuts as round buttons, and the timer presets, which are actions too.
struct ActionsSectionView: View {
    @ObservedObject private var runner = ShortcutsRunner.shared
    @ObservedObject private var timers = IslandTimer.shared

    var body: some View {
        VStack(spacing: 0) {
            QuickActionsRowView()
                .frame(height: 64)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.vertical, 8)
                .accessibilityHidden(true)
            timerRow
                .frame(height: 30)
            Spacer(minLength: 0)
        }
    }

    private var timerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 18)
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
            PillButton(title: IslandStopwatch.shared.state == nil ? "Stopwatch" : "Stop", symbol: "stopwatch.fill") {
                if IslandStopwatch.shared.state == nil { IslandStopwatch.shared.start() } else { IslandStopwatch.shared.reset() }
            }
        }
    }
}

// MARK: - Notes

struct NotesSectionView: View {
    @ObservedObject private var notes = NotesStore.shared
    @EnvironmentObject private var center: ActivityCenter

    var body: some View {
        VStack(spacing: 0) {
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
                        .accessibilityLabel("Notes")
                }
                if notes.text.isEmpty {
                    Text("Jot something down. It stays here, on this Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.top, 2)
        }
        .onAppear {
            guard !RenderMode.isGallery else { return }
            center.setWantsKeyboard(true)
            NotchPanel.takeKeyboard()
        }
        .onDisappear { center.setWantsKeyboard(false) }
    }
}

// MARK: - Stats

struct StatsSectionView: View {
    var body: some View {
        VStack(spacing: 0) {
            SectionHeader("Stats") {
                PillButton(title: "Activity Monitor", symbol: "arrow.up.forward", tint: .white.opacity(0.85)) {
                    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            StatsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 10)
        }
    }
}
