import AppKit
import SwiftUI

/// What a right-click on the island offers: the handful of things from the menu bar that are
/// worth having where the pointer already is.
///
/// Deliberately shorter than the status item's menu. That one is a whole menu bar's worth of
/// app — timers, the demo, diagnostics, About. This one is what somebody wants *of the island
/// they are looking at*: keep the Mac awake, clear the shelf, get it out of the way, open
/// Settings, quit.
struct IslandMenu: View {
    /// What the island is showing at this moment, if it is showing one thing. Its own
    /// commands come first: a right-click on a playing pill that cannot skip a track is a
    /// context menu with no context in it.
    var activity: IslandActivity?

    @ObservedObject private var keepAwake = KeepAwake.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if let activity, Self.hasCommands(activity.content) {
            commands(activity)
            Divider()
        }
        Button(keepAwake.isOn ? "Let the Mac Sleep" : "Keep Awake") { keepAwake.toggle() }
        if !shelf.items.isEmpty {
            Button("Clear Shelf") { ShelfStore.shared.clear() }
        }
        Divider()
        // The same pair of states the menu bar shows, said the same way.
        if Self.isPaused(until: prefs.pausedUntil) {
            Button("Show the Island") { ActivityCenter.shared.pause(for: 0) }
        } else {
            Button("Hide the Island for an Hour") { ActivityCenter.shared.pause(for: 3600) }
        }
        Button("Settings…") { SettingsWindow.open() }
        Divider()
        Button("Quit Notch Island") { NSApp.terminate(nil) }
    }

    /// Whether this activity has anything of its own to offer. Kept beside `commands` so the
    /// separator above them is never drawn over nothing.
    static func hasCommands(_ content: ActivityContent) -> Bool {
        switch content {
        case .nowPlaying, .timer, .stopwatch, .shelf, .call: return true
        default: return false
        }
    }

    /// What this activity can be told to do, without opening the panel to say it.
    @ViewBuilder
    private func commands(_ activity: IslandActivity) -> some View {
        switch activity.content {
        case .nowPlaying(let info):
            Button(info.isPlaying ? "Pause" : "Play") { NowPlayingService.shared.togglePlayPause() }
            Button("Next Track") { NowPlayingService.shared.next() }
            Button("Previous Track") { NowPlayingService.shared.previous() }
        case .timer(let state):
            if state.isFinished {
                Button("Repeat") { IslandTimer.shared.repeatLast() }
            } else {
                Button(state.isPaused ? "Resume Timer" : "Pause Timer") {
                    state.isPaused ? IslandTimer.shared.resume(id: activity.id)
                                   : IslandTimer.shared.pause(id: activity.id)
                }
            }
            Button("Cancel Timer") { IslandTimer.shared.cancel(id: activity.id) }
        case .stopwatch(let state):
            if state.isRunning {
                Button("Lap") { IslandStopwatch.shared.lap() }
                Button("Stop") { IslandStopwatch.shared.stop() }
            } else {
                Button("Start") { IslandStopwatch.shared.start() }
            }
            Button("Reset Stopwatch") { IslandStopwatch.shared.reset() }
        case .shelf:
            Button("AirDrop the Shelf") { ShelfStore.shared.airDrop(ShelfStore.shared.urls) }
        case .call(let call):
            Button("Open \(call.appName)") { activity.openAction?.perform() }
        default:
            EmptyView()
        }
    }

    /// Whether the island is hidden by the clock rather than by an app in front. Pure, so the
    /// menu and the menu bar cannot disagree about which of the two words to show.
    static func isPaused(until: Double, now: Date = Date()) -> Bool {
        until > 0 && now.timeIntervalSince1970 < until
    }
}
