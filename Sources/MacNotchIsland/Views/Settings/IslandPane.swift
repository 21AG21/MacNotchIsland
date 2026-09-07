import SwiftUI

/// "Island": how the island reacts to the pointer, the trackpad and the keyboard.
struct IslandPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Expand when hovered", isOn: $prefs.hoverToExpand)
                    .help("Hovering the notch is the Mac's equivalent of a long press.")
                Toggle("Open Home panel when idle and hovered", isOn: $prefs.expandOnIdleHover)
                    .help("With nothing live, hovering opens the Home panel instead of an empty island.")
                SettingsSlider("Hover delay", value: $prefs.hoverDelay, range: 0...0.6, unit: "s")
            } header: {
                Text("Hover")
            } footer: {
                Text("A longer delay keeps the island out of the way while you reach for the menu bar.")
            }

            Section {
                SettingsSlider("Alert duration", value: $prefs.alertDuration, range: 1...6, unit: "s")
                Toggle("Trackpad haptics", isOn: $prefs.hapticsEnabled)
                    .help("A light tap when the island expands or an alert arrives.")
                Toggle("Trackpad gestures", isOn: $prefs.gesturesEnabled)
                    .help("Swipe and scroll on the island to control playback and volume.")
            } header: {
                Text("Alerts and gestures")
            } footer: {
                Text("Swipe sideways on the island to skip tracks or switch Home panel tabs; scroll up or down for volume.")
            }

            Section {
                Toggle("Use a keyboard shortcut", isOn: $prefs.hotkeyEnabled)
                    .help("Summon the island from anywhere, even in full-screen apps.")
                if prefs.hotkeyEnabled {
                    ShortcutRecorderView()
                }
            } header: {
                Text("Keyboard shortcut")
            } footer: {
                Text("The shortcut opens the island, or the Home panel when nothing is live. Press it again to close.")
            }
        }
        .formStyle(.grouped)
    }
}
