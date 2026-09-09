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
    @ObservedObject private var keepAwake = KeepAwake.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
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

    /// Whether the island is hidden by the clock rather than by an app in front. Pure, so the
    /// menu and the menu bar cannot disagree about which of the two words to show.
    static func isPaused(until: Double, now: Date = Date()) -> Bool {
        until > 0 && now.timeIntervalSince1970 < until
    }
}
