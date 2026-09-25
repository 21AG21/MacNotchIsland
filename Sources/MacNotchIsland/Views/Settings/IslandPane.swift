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
                Text("The shortcut opens the panel on what is playing or running, or on the section you last had open when nothing is; press it again to close. Tab steps through the live activities and then every section, in the order Home Panel lists them; the arrows do the same without wrapping, and only while the panel is open. What you open stays open across desktops.")
            }

            // The keys that need nothing held down. Listed only while they are on, for the
            // same reason the shortcuts above are.
            Section {
                Toggle("The panel answers the keyboard", isOn: $prefs.panelKeysEnabled)
                    .help("While the panel is pinned open, these keys are the island's. They go back to the app in front the moment it closes.")
                if prefs.panelKeysEnabled {
                    LabeledContent("Step between views", value: "← and →")
                    LabeledContent("Go straight to a view", value: "1 to 9")
                    LabeledContent("Type a timer, on Actions", value: "0 to 9")
                    LabeledContent("Play or pause", value: "Space")
                    LabeledContent("Quick Look the shelf", value: "Space")
                    LabeledContent("Volume", value: "↑ and ↓")
                    LabeledContent("Find in a list", value: "A to Z")
                    LabeledContent("Walk the matches", value: "↑ and ↓")
                    LabeledContent("Take the one you are on", value: "Return")
                    LabeledContent("Leave the find", value: "Escape")
                }
            } header: {
                Text("While the panel is open")
            } footer: {
                // The digits are not the band's slots counted from the left: they follow the
                // ring Tab walks, and the band draws the sections it has no room for on the far
                // side of the cutout. Where somebody wants a slot's digit, the band shows it.
                Text("Only while the panel is pinned open — resting the pointer on the island takes nothing from the keyboard — and never while Notes is showing, where every key is yours to type. The digits go in Tab's order: the live activities, then the sections, so a running timer takes 1 and moves every section along by one, and anything past the ninth has none. Rest the pointer on a button beside the notch to see its digit. Space is Quick Look while the shelf is the section on screen. On Actions the digits type a timer's minutes or an alarm's time instead; Tab and the arrows still step. The letters are claimed only on \(Self.findSections), which are the sections that are lists of things: typing on one of them narrows it, the vertical arrows walk what is left, Return takes the one you are on, and Escape leaves the find without closing the panel.")
            }

            Section {
                Toggle("Open when the pointer rests on the island", isOn: $prefs.hoverToExpand)
                    .help("The panel opens under the pointer, on what is playing or running, and closes when it leaves. A click keeps it open.")
                // Reads as what it is: a modifier of the switch above it. The two used to be
                // near enough the same sentence — one of them in the passive — and nothing
                // said which of them governed which island.
                //
                // It and the delay only mean anything while the pointer opens the panel at all,
                // and both were left live with that switched off — the delay showing on the
                // strength of this switch alone — saying something about a behaviour that was
                // not happening.
                Toggle("Open from the empty notch too", isOn: $prefs.expandOnIdleHover)
                    .help("With nothing playing or running there is nothing to peek at, so resting on the notch does nothing unless this is on.")
                    .disabled(!prefs.hoverToExpand)
                SettingsSlider("Hover delay", value: $prefs.hoverDelay, range: 0...0.6, unit: "s")
                    .disabled(!prefs.hoverToExpand)
            } header: {
                Text("Pointer")
            } footer: {
                Text("What the pointer opens closes when it leaves. A click anywhere on the panel — its background or one of its controls — keeps it open until you click somewhere else, press Escape, or use the shortcut.")
            }

            Section {
                // The figure is a scale, not a length every alert is held to: each kind of alert
                // has a length of its own — a copied line a second, a HUD a moment and a half, a
                // finished download four — and the slider moves all of them together. It used
                // to be only the fallback for the few that named none, and read "Alert
                // duration" while a download banner stayed exactly as long wherever it was put.
                // See `ActivityCenter.alertDuration(requested:preference:)`.
                SettingsSlider("Alerts stay for about", value: $prefs.alertDuration, range: 1...6, unit: "s")
                    .help("How long an ordinary alert stays — a Focus changing, Low Power Mode. Every other alert keeps its own proportion to that: a copied line stays about half as long, a finished download about twice, and all of them move together as this moves.")
                Toggle("Trackpad haptics", isOn: $prefs.hapticsEnabled)
                    .help("A light tap when an alert arrives, a timer rings, or a file is dragged onto the island. Never for a click: the trackpad has already clicked.")
                Toggle("Trackpad gestures", isOn: $prefs.gesturesEnabled)
                    .help("Swipe and scroll on the island to control playback, volume and brightness.")
                Toggle("Keep clear of menu bar items", isOn: $prefs.keepClearOfMenuBar)
                    .help("The island only widens into menu bar space that is free, so it never covers a menu title or a status item. Grant Accessibility under Privacy to include app menus.")
            } header: {
                Text("Alerts and gestures")
            } footer: {
                Text("The seconds are an ordinary alert's, such as a Focus changing, and they set the pace for all of them: a copied line stays about half as long, a finished download or a screenshot about twice, a volume or brightness change a little less, and moving the slider moves every one of them in step — at six seconds everything stays more than three times as long as it ships. Swipe sideways on the pill to skip tracks, or on the panel to step between sections; scroll up or down for the volume — or to open and close the panel, if you choose that below — and hold Option while you scroll for the brightness: the rail's two sliders, without opening the panel. A section that scrolls by itself, like the clipboard, keeps its own scroll.")
            }

            Section {
                Picker("Vertical swipe on the island", selection: verticalSwipe) {
                    Text("Volume").tag(GestureRouter.VerticalSwipe.volume.rawValue)
                    Text("Open and close").tag(GestureRouter.VerticalSwipe.openClose.rawValue)
                }
                .help("What two fingers up or down on the island do: move the volume, or open and close the panel.")
                .disabled(!prefs.gesturesEnabled)
                // Only while it governs something: the slider sets how far a swipe to open or
                // close has to go, and the volume has no such distance.
                if GestureRouter.VerticalSwipe(preference: prefs.verticalSwipe) == .openClose {
                    SettingsSlider("Swipe sensitivity", value: swipeSensitivity, range: 50...200, unit: "%")
                        .help("How far a swipe has to travel to open or close the panel. Higher is a shorter swipe.")
                        .disabled(!prefs.gesturesEnabled)
                }
            } header: {
                Text("Vertical swipe")
            } footer: {
                Text("Volume is how the island has always read a scroll. With Open and close, swipe down on the island to open the panel on whatever it is showing, and up on the panel to close it again — once for each swipe, however far the fingers go on. The sensitivity is how far a swipe has to travel: higher is a shorter one. Option and Control still move the brightness and the keyboard's backlight either way, and a section that scrolls by itself keeps its scroll. On a running timer's pill a small scroll moves it a minute a step — up adds one, down takes one off — and in Open and close a swipe down long enough still opens the panel, with the timer put back as it was.")
            }
        }
        .formStyle(.grouped)
    }

    /// The sections that take the letters, named from `PanelFind.sections` itself in the order
    /// the panel ships them, so a list that gains a find is named here without anybody having
    /// to remember this sentence. Written out by hand it had already missed Notifications.
    static var findSections: String {
        let names = HomeSection.allCases.filter { PanelFind.sections.contains($0) }.map(\.title)
        guard let last = names.last else { return "no section" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The stored choice, read back through `VerticalSwipe` so that a value this build does not
    /// know shows as the volume it behaves as, rather than as a menu with nothing picked.
    private var verticalSwipe: Binding<String> {
        Binding(
            get: { GestureRouter.VerticalSwipe(preference: prefs.verticalSwipe).rawValue },
            set: { prefs.verticalSwipe = $0 }
        )
    }

    /// The slider speaks in whole percentages, the way the Motion pane's do; the preference
    /// is the factor, held to the slider's range.
    private var swipeSensitivity: Binding<Double> {
        Binding(
            get: { prefs.swipeSensitivity * 100 },
            set: { percent in
                let range = GestureRouter.sensitivityRange
                prefs.swipeSensitivity = min(range.upperBound, max(range.lowerBound, percent.rounded() / 100))
            }
        )
    }
}
