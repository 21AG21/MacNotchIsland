import AppKit
import SwiftUI

/// "Activities": every live thing the island is allowed to show.
struct ActivitiesPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var hud = SystemHUDReplacement.shared
    @ObservedObject private var keyboard = KeyboardLight.shared

    /// Why the island is or is not answering the volume and brightness keys.
    ///
    /// It only ever shows one of these at a time, because two heads-up displays for one
    /// keypress is the thing this setting exists to prevent: unless the island has actually
    /// taken the keys over, macOS is drawing its own bezel and the island stays quiet.
    private var hudFooter: String {
        guard prefs.hudReplacementEnabled else {
            return "Left off, macOS keeps its own bezel and the island adds nothing beside it — two of "
                 + "those for one keypress is worse than either. Scrolling on the island still shows "
                 + "its own display, because nothing else answers that. Turn this on and the island "
                 + "takes the media keys over, shows changes made anywhere else too, and names the "
                 + "headphones or speaker the sound is going to."
        }
        guard hud.isActive else {
            return "Waiting for Accessibility access. Until it is granted the media keys still reach macOS, "
                 + "so the island stays quiet rather than showing a bezel next to the system's."
        }
        guard keyboard.isAvailable else {
            return "Hold Shift and Option for quarter steps. The keyboard backlight keys are left to macOS: "
                 + "this Mac has no backlight the island can set."
        }
        return "Hold Shift and Option for quarter steps. The keyboard backlight keys are answered too, "
             + "through the same private framework Control Centre uses; switch Keyboard backlight off and "
             + "they go back to macOS. Hold Control and scroll on the island to set the backlight."
    }

    /// The choices offered for how long a paused track stays in the island, in minutes.
    private static let keepPausedOptions: [Double] = [0, 1, 5, 10, 15, 30]

    var body: some View {
        Form {
            Section {
                Toggle("Show what is playing", isOn: $prefs.nowPlayingEnabled)
                    .help("Show what Music, Spotify, Safari or any app using the system player is playing.")
                Picker("Keep paused music for", selection: keepPaused) {
                    Text("Not at all").tag(0.0)
                    Text("1 minute").tag(1.0)
                    Text("5 minutes").tag(5.0)
                    Text("10 minutes").tag(10.0)
                    Text("15 minutes").tag(15.0)
                    Text("30 minutes").tag(30.0)
                }
                .pickerStyle(.menu)
                .disabled(!prefs.nowPlayingEnabled)
                Toggle("Lyrics", isOn: $prefs.lyricsEnabled)
                    .help("Time-synced lyrics under Now Playing, from LRCLIB.")
                    .disabled(!prefs.nowPlayingEnabled)
                Toggle("Find missing album art", isOn: $prefs.artworkLookupEnabled)
                    .help("When a player hands over no cover — a browser, a podcast app — the track is looked up by name in Apple's public search and the cover comes from there. Only the title, artist and album are sent, and only when there is no cover already.")
                    .disabled(!prefs.nowPlayingEnabled)
                Toggle("Audio-reactive visualizer", isOn: $prefs.reactiveVisualizerEnabled)
                    .help("The bars follow the sound instead of a fixed pattern.")
                    .disabled(!prefs.nowPlayingEnabled)
                Toggle("Show new tracks in the pill", isOn: $prefs.sneakPeekEnabled)
                    .help("The title and artist appear in the pill for a moment when a track starts or changes.")
                    .disabled(!prefs.nowPlayingEnabled)
            } header: {
                Text("Now Playing")
            } footer: {
                Text("The visualizer asks macOS for system audio capture the first time it runs. Nothing is recorded.")
            }

            Section {
                Toggle("Battery and charging", isOn: $prefs.batteryEnabled)
                // Under the switch it hangs on. It used to sit under Downloads, a section away,
                // and stayed live with the battery off, when nothing reads the mark at all.
                Picker("Tell me at", selection: chargeAlert) {
                    Text("Never").tag(0.0)
                    Text("70%").tag(70.0)
                    Text("80%").tag(80.0)
                    Text("85%").tag(85.0)
                    Text("90%").tag(90.0)
                }
                .pickerStyle(.menu)
                .help("A laptop that lives on its charger sits at a hundred per cent, which is where a lithium battery ages fastest. Said once per charge.")
                .disabled(!ServiceHub.wantsBattery(prefs))
                Toggle("Bluetooth devices", isOn: $prefs.bluetoothEnabled)
                    .help("AirPods and other Bluetooth devices, with their battery level, as they connect.")
                Toggle("Low Power Mode", isOn: $prefs.lowPowerEnabled)
                Toggle("Caps Lock", isOn: $prefs.capsLockEnabled)
                    .help("A brief pill when Caps Lock turns on or off.")
                Toggle("Unlock", isOn: $prefs.unlockEnabled)
                    .help("A welcome back pill when you unlock your Mac.")
            } header: {
                Text("System")
            } footer: {
                Text(Self.systemFooter(watchingBattery: ServiceHub.wantsBattery(prefs)))
            }

            Section {
                Toggle("Answer the volume and brightness keys", isOn: $prefs.hudReplacementEnabled)
                    .help("The island takes the media keys over and becomes the only heads-up display for volume, mute and brightness.")
                // Neither is disabled with the master switch: each also owns the display a
                // scroll on the island puts up, which works either way, and a display with no
                // way to turn it off is worse than one setting that does two things. The
                // brightness one used to be greyed out behind a line saying the island had no
                // way to change the brightness — while an Option-scroll on it did exactly that,
                // and the rail carried a slider for it. The master switch ships off, so out of
                // the box the only control over that display was one nobody could reach.
                // A Mac has mute, not the phone's silent switch, and the switch is named for it.
                Toggle("Volume and mute", isOn: $prefs.volumeHUDEnabled)
                    .help("With the switch above on, this is every volume and mute change. With "
                          + "it off, it is only the one a scroll on the island makes itself.")
                Toggle("Brightness", isOn: $prefs.brightnessHUDEnabled)
                    .help("With the switch above on, this is every brightness change. With it off, "
                          + "it is only the one an Option-scroll on the island makes itself.")
                // Beside the brightness, and for the same two things: with the switch above on,
                // the backlight keys; either way, the display a Control-scroll puts up. Greyed out
                // only where there is no backlight to set, which is the one case where it would
                // be a switch for nothing.
                Toggle("Keyboard backlight", isOn: $prefs.keyboardLightHUDEnabled)
                    .help(keyboard.isAvailable
                          ? "With the switch above on, the keyboard backlight keys are answered in the island. "
                            + "With it off, this is only the display a Control-scroll on the island makes itself."
                          : "This Mac has no keyboard backlight the island can set.")
                    .disabled(!keyboard.isAvailable)
                // With every display off there is no key left to take, so the island is not
                // asking for Accessibility and must not offer to send anyone looking for it. The
                // backlight's switch counts only where there is a backlight, as in the hub.
                if ServiceHub.wantsMediaKeys(prefs, backlightAvailable: keyboard.isAvailable), !hud.isActive {
                    Button("Open Accessibility Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Volume and brightness")
            } footer: {
                Text(hudFooter)
            }

            Section {
                Toggle("Microphone and camera", isOn: $prefs.privacyIndicatorsEnabled)
                    .help("A dot in the island whenever the microphone or camera is in use.")
                Toggle("Calls", isOn: $prefs.callDetectionEnabled)
                    .help("FaceTime, Zoom, Teams, Meet, Slack, Discord and Webex.")
            } header: {
                Text("Privacy indicators")
            }

            Section {
                Toggle("Focus", isOn: $prefs.focusEnabled)
                    .help("Show the current Focus, including Do Not Disturb.")
                Toggle("Quieten alerts during a Focus", isOn: $prefs.quietDuringFocus)
                    .disabled(!prefs.focusEnabled)
                    .help("While a Focus is on, the island holds back the alerts that arrive on their own.")
                Toggle("Upcoming calendar events", isOn: $prefs.calendarEnabled)
                    .help("Your next event shortly before it starts, and the Today section of the panel.")
            } header: {
                Text("Focus and calendar")
            } footer: {
                Text("Calendar events ask for calendar access the first time they are turned on. The same switch shows the Today section in the panel. While a Focus is on, the island holds back what arrives on its own — a finished download, a device connecting, an event coming up, an alert a script pushed — and shows everything you did yourself, along with a nearly flat battery and a call.")
            }

            Section {
                Toggle("Downloads", isOn: $prefs.downloadsEnabled)
                    .help("Safari, Chrome and Firefox downloads in your Downloads folder, with a progress ring.")
                Toggle("Screenshots", isOn: $prefs.screenshotsEnabled)
                    .help("The picture you just took, with Copy, Copy Text and Open on it — and draggable straight into a message.")
                Toggle("External disks", isOn: $prefs.drivesEnabled)
                    .help("A card when a drive is plugged in, with Eject on it, and a word when one is unplugged.")
                Toggle("Timer sound", isOn: $prefs.timerSoundEnabled)
                    .help("Play a sound when an island timer finishes.")
            } header: {
                Text("Downloads, disks and timers")
            } footer: {
                Text("A capture's card shows the picture itself: drag it from there into a message without it ever touching the Desktop, put it or the words in it on the pasteboard, or open it. Finished downloads and screenshots also land on the shelf, unless you turn that off in Home Panel. A disk's card carries the Eject button, so getting a drive out safely no longer means finding its icon on the desktop.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            SettingsFormat.snap(&prefs.chargeAlertPercent, to: Self.chargeOptions)
            SettingsFormat.snap(&prefs.keepPausedMinutes, to: Self.keepPausedOptions)
        }
    }

    /// The System section's footer: what "Tell me at" is for, and, while "Battery and
    /// charging" is off, why it is greyed out — the mark is read by the battery monitor and by
    /// nothing else, so with that off it is a figure nobody reads. Pure, so a test holds the
    /// reason to the switch.
    static func systemFooter(watchingBattery: Bool) -> String {
        let mark = "A laptop that lives on its charger sits at a hundred per cent, which is where a "
            + "lithium battery ages fastest. Choose a figure under Tell me at and the island says when "
            + "it has had enough, once per charge."
        guard !watchingBattery else { return mark }
        return mark + " It needs Battery and charging: with that off, nothing is watching the charge."
    }

    /// The charge mark, snapped to one of the offered figures.
    private var chargeAlert: Binding<Double> {
        Binding(
            get: { SettingsFormat.nearest(prefs.chargeAlertPercent, in: Self.chargeOptions) },
            set: { prefs.chargeAlertPercent = $0 }
        )
    }

    private static let chargeOptions: [Double] = [0, 70, 80, 85, 90]

    /// Menus store discrete choices; a value set by an older build is shown as its nearest match.
    private var keepPaused: Binding<Double> {
        Binding(
            get: { SettingsFormat.nearest(prefs.keepPausedMinutes, in: Self.keepPausedOptions) },
            set: { prefs.keepPausedMinutes = $0 }
        )
    }
}
