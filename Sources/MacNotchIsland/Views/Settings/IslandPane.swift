import Carbon.HIToolbox
import SwiftUI

/// "Island": how the island reacts to the pointer, the trackpad and the keyboard.
struct IslandPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Toggle island", value: HotKeyService.displayString(keyCode: HotKeyService.currentKeyCode, carbonModifiers: HotKeyService.currentModifiers))
                LabeledContent("Next section", value: HotKeyService.displayString(keyCode: kVK_Tab, carbonModifiers: HotKeyService.currentModifiers))
                LabeledContent("Previous section", value: HotKeyService.displayString(keyCode: kVK_Tab, carbonModifiers: HotKeyService.currentModifiers | shiftKey))
                LabeledContent("Close", value: "Escape")
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Change the shortcut under Shortcuts. Tab steps through the live activities and every section in the order the switcher shows them. What you open stays open across desktops.")
            }

            Section {
                Toggle("Open when the pointer rests on the island", isOn: $prefs.hoverToExpand)
                    .help("The panel opens under the pointer, on what is playing or running, and closes when it leaves. A click keeps it open.")
                Toggle("Open the panel when the empty island is hovered", isOn: $prefs.expandOnIdleHover)
                if prefs.hoverToExpand || prefs.expandOnIdleHover {
                    SettingsSlider("Hover delay", value: $prefs.hoverDelay, range: 0...0.6, unit: "s")
                }
            } header: {
                Text("Pointer")
            } footer: {
                Text("What the pointer opens closes when it leaves. A click on the island keeps the panel open until you click somewhere else, press Escape, or use the shortcut.")
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

            Section {
                Toggle("Use a keyboard shortcut", isOn: $prefs.hotkeyEnabled)
                    .help("Summon the island from anywhere, even in full-screen apps.")
                if prefs.hotkeyEnabled {
                    ShortcutRecorderView()
                }
            } header: {
                Text("Keyboard shortcut")
            } footer: {
                Text("The shortcut opens the panel on what is playing, or on Now Playing when nothing is. Press it again to close.")
            }
        }
        .formStyle(.grouped)
    }
}
