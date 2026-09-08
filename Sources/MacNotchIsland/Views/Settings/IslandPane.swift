import Carbon.HIToolbox
import SwiftUI

/// "Island": how the island reacts to the pointer, the trackpad and the keyboard.
struct IslandPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Toggle island", value: HotKeyService.displayString(keyCode: HotKeyService.currentKeyCode, carbonModifiers: HotKeyService.currentModifiers))
                LabeledContent("Next view", value: HotKeyService.displayString(keyCode: kVK_Tab, carbonModifiers: HotKeyService.currentModifiers))
                LabeledContent("Previous view", value: HotKeyService.displayString(keyCode: kVK_Tab, carbonModifiers: HotKeyService.currentModifiers | shiftKey))
                LabeledContent("Close", value: "Escape")
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Change the shortcut under Shortcuts. Clicking the island opens it as well; a click anywhere else, or Escape, closes it. What you open stays open across desktops.")
            }

            Section {
                Toggle("Expand when the pointer rests on the island", isOn: $prefs.hoverToExpand)
                    .help("Off by default: the island reacts to clicks and the keyboard, never to the pointer passing by.")
                Toggle("Open Home panel when the empty island is hovered", isOn: $prefs.expandOnIdleHover)
                if prefs.hoverToExpand || prefs.expandOnIdleHover {
                    SettingsSlider("Hover delay", value: $prefs.hoverDelay, range: 0...0.6, unit: "s")
                }
            } header: {
                Text("Pointer")
            } footer: {
                Text("Both are off unless you want them. With them off, nothing opens until you click or use the keyboard.")
            }

            Section {
                SettingsSlider("Alert duration", value: $prefs.alertDuration, range: 1...6, unit: "s")
                Toggle("Trackpad haptics", isOn: $prefs.hapticsEnabled)
                    .help("A light tap when the island expands or an alert arrives.")
                Toggle("Trackpad gestures", isOn: $prefs.gesturesEnabled)
                    .help("Swipe and scroll on the island to control playback and volume.")
                Toggle("Keep clear of menu bar items", isOn: $prefs.keepClearOfMenuBar)
                    .help("The island only widens into menu bar space that is free, so it never covers a menu title or a status item. Grant Accessibility under Privacy to include app menus.")
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
