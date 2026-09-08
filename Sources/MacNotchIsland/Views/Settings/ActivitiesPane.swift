import SwiftUI

/// "Activities": every live thing the island is allowed to show.
struct ActivitiesPane: View {
    @ObservedObject private var prefs = Preferences.shared

    /// The choices offered for how long a paused track stays in the island, in minutes.
    private static let keepPausedOptions: [Double] = [0, 1, 5, 10, 15, 30]

    var body: some View {
        Form {
            Section {
                Toggle("Now Playing", isOn: $prefs.nowPlayingEnabled)
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
                Toggle("Bluetooth devices", isOn: $prefs.bluetoothEnabled)
                    .help("AirPods and other Bluetooth devices, with their battery level, as they connect.")
                Toggle("Volume and silent mode", isOn: $prefs.volumeHUDEnabled)
                Toggle("Brightness", isOn: $prefs.brightnessHUDEnabled)
                Toggle("Low Power Mode", isOn: $prefs.lowPowerEnabled)
                Toggle("Caps Lock", isOn: $prefs.capsLockEnabled)
                    .help("A brief pill when Caps Lock turns on or off.")
                Toggle("Unlock", isOn: $prefs.unlockEnabled)
                    .help("A welcome back pill when you unlock your Mac.")
            } header: {
                Text("System")
            }

            Section {
                Toggle("Replace the system volume and brightness bezel", isOn: $prefs.hudReplacementEnabled)
                    .help("The island becomes the only heads-up display for volume, mute and brightness.")
            } footer: {
                Text("macOS asks for Accessibility access the first time. Hold Shift and Option for quarter steps; the keyboard backlight keys are left to macOS.")
            }

            Section {
                Toggle("Microphone and camera indicators", isOn: $prefs.privacyIndicatorsEnabled)
                    .help("A dot in the island whenever the microphone or camera is in use.")
                Toggle("Calls", isOn: $prefs.callDetectionEnabled)
                    .help("FaceTime, Zoom, Teams, Meet, Slack, Discord and Webex.")
            } header: {
                Text("Privacy indicators")
            }

            Section {
                Toggle("Focus", isOn: $prefs.focusEnabled)
                    .help("Show the current Focus, including Do Not Disturb.")
                Toggle("Upcoming calendar events", isOn: $prefs.calendarEnabled)
                    .help("Your next event shortly before it starts, and the Today section of the panel.")
            } header: {
                Text("Focus and calendar")
            } footer: {
                Text("Calendar events ask for calendar access the first time they are turned on. The same switch shows the Today section in the panel.")
            }

            Section {
                Toggle("Downloads", isOn: $prefs.downloadsEnabled)
                    .help("Safari, Chrome and Firefox downloads in your Downloads folder, with a progress ring.")
                Toggle("Timer sound", isOn: $prefs.timerSoundEnabled)
                    .help("Play a sound when an island timer finishes.")
            } header: {
                Text("Downloads and timers")
            } footer: {
                Text("Finished downloads and screenshots can also land on the shelf. Turn that on in Home Panel.")
            }
        }
        .formStyle(.grouped)
    }

    /// Menus store discrete choices; a value set by an older build is shown as its nearest match.
    private var keepPaused: Binding<Double> {
        Binding(
            get: { SettingsFormat.nearest(prefs.keepPausedMinutes, in: Self.keepPausedOptions) },
            set: { prefs.keepPausedMinutes = $0 }
        )
    }
}
