import Carbon.HIToolbox
import SwiftUI

/// "Island": how the island reacts to the pointer, the trackpad and the keyboard.
struct IslandPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            // One section, not two at opposite ends of the pane: what the shortcuts are and
            // the control that sets them belong on the same screenful. And listed only while
            // they exist — the switch below takes every one of them away together, since they
            // are all registered off the same recorded combination.
            Section {
                Toggle("Use a keyboard shortcut", isOn: $prefs.hotkeyEnabled)
                    .help("Summon the island from anywhere, even in full-screen apps.")
                if prefs.hotkeyEnabled {
                    ShortcutRecorderView()
                    LabeledContent("Next section", value: HotKeyService.displayString(keyCode: kVK_Tab, carbonModifiers: HotKeyService.currentModifiers))
                    LabeledContent("Previous section", value: HotKeyService.displayString(keyCode: kVK_Tab, carbonModifiers: HotKeyService.currentModifiers | shiftKey))
                    LabeledContent("Step sideways", value: HotKeyService.displayString(keyCode: kVK_LeftArrow, carbonModifiers: HotKeyService.currentModifiers) + " and " + HotKeyService.displayString(keyCode: kVK_RightArrow, carbonModifiers: HotKeyService.currentModifiers))
                    LabeledContent("Close", value: "Escape")
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("The shortcut opens the panel on what is playing, or on Now Playing when nothing is; press it again to close. Tab steps through the live activities and every section in the order the switcher shows them; the arrows do the same without wrapping, and only while the panel is open. What you open stays open across desktops.")
            }

            Section {
                Toggle("Open when the pointer rests on the island", isOn: $prefs.hoverToExpand)
                    .help("The panel opens under the pointer, on what is playing or running, and closes when it leaves. A click keeps it open.")
                // Reads as what it is: a modifier of the switch above it. The two used to be
                // near enough the same sentence — one of them in the passive — and nothing
                // said which of them governed which island.
                Toggle("Open from the empty notch too", isOn: $prefs.expandOnIdleHover)
                    .help("With nothing playing or running there is nothing to peek at, so resting on the notch does nothing unless this is on.")
                if prefs.hoverToExpand || prefs.expandOnIdleHover {
                    SettingsSlider("Hover delay", value: $prefs.hoverDelay, range: 0...0.6, unit: "s")
                }
            } header: {
                Text("Pointer")
            } footer: {
                Text("What the pointer opens closes when it leaves. A click anywhere on the panel — its background or one of its controls — keeps it open until you click somewhere else, press Escape, or use the shortcut.")
            }

            Section {
                SettingsSlider("Alert duration", value: $prefs.alertDuration, range: 1...6, unit: "s")
                Toggle("Trackpad haptics", isOn: $prefs.hapticsEnabled)
                    .help("A light tap when an alert arrives, a timer rings, or a file is dragged onto the island. Never for a click: the trackpad has already clicked.")
                Toggle("Trackpad gestures", isOn: $prefs.gesturesEnabled)
                    .help("Swipe and scroll on the island to control playback and volume.")
                Toggle("Keep clear of menu bar items", isOn: $prefs.keepClearOfMenuBar)
                    .help("The island only widens into menu bar space that is free, so it never covers a menu title or a status item. Grant Accessibility under Privacy to include app menus.")
            } header: {
                Text("Alerts and gestures")
            } footer: {
                Text("Swipe sideways on the pill to skip tracks, or on the panel to step between sections; scroll up or down for volume.")
            }
        }
        .formStyle(.grouped)
    }
}
