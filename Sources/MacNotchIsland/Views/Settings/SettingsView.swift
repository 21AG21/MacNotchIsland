import SwiftUI
import EventKit

/// Settings window in the house monochrome style: flat ground, big type, no boxes,
/// hairlines between rows, emphasis by weight and shade only.
struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var center: ActivityCenter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Notch Island")
                    .font(.system(size: 34, weight: .medium))
                    .tracking(-0.8)
                    .padding(.bottom, 2)
                Text("Dynamic Island for the MacBook notch")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 28)

                section("General") {
                    toggle("Launch at login", $prefs.launchAtLogin)
                    toggle("Expand when hovered", $prefs.hoverToExpand, note: "Hovering is the Mac's long press.")
                    toggle("Open Home panel when idle and hovered", $prefs.expandOnIdleHover)
                    toggle("Trackpad haptics", $prefs.hapticsEnabled)
                    VStack(alignment: .leading, spacing: 0) {
                        toggle("Keyboard shortcut", $prefs.hotkeyEnabled, note: "Opens the island (or the Home panel) from anywhere; press again to close.")
                        if prefs.hotkeyEnabled {
                            ShortcutRecorderView().padding(.leading, 16)
                        }
                    }
                    toggle("Show on every display", $prefs.showOnAllDisplays, note: "Displays without a notch get a simulated island.")
                    toggle("Check for updates", $prefs.updateChecksEnabled, note: "Once a day, against the GitHub releases page. Nothing is installed automatically.")
                    toggle("Hide in full-screen apps", $prefs.hideInFullscreen, note: "Videos and games get the whole screen; the island comes back when you leave full screen.")
                    slider("Hover delay", $prefs.hoverDelay, range: 0...0.6, unit: "s")
                    slider("Alert duration", $prefs.alertDuration, range: 1...6, unit: "s")
                }

                section("Activities") {
                    toggle("Now Playing", $prefs.nowPlayingEnabled, note: "Music, Spotify, Safari and any app using the system player.")
                    slider("Keep paused music for", $prefs.keepPausedMinutes, range: 0...30, unit: "min")
                    toggle("Battery and charging", $prefs.batteryEnabled)
                    toggle("AirPods and Bluetooth devices", $prefs.bluetoothEnabled)
                    toggle("Volume and silent mode", $prefs.volumeHUDEnabled)
                    toggle("Brightness", $prefs.brightnessHUDEnabled)
                    toggle("Microphone and camera indicators", $prefs.privacyIndicatorsEnabled)
                    toggle("Calls", $prefs.callDetectionEnabled, note: "FaceTime, Zoom, Teams, Meet, Slack, Discord and Webex.")
                    toggle("Focus", $prefs.focusEnabled)
                    toggle("Upcoming calendar events", $prefs.calendarEnabled, note: "Asks for calendar access when turned on.")
                    toggle("Unlock", $prefs.unlockEnabled)
                    toggle("Low Power Mode", $prefs.lowPowerEnabled)
                    toggle("Downloads", $prefs.downloadsEnabled, note: "Safari, Chrome and Firefox downloads in ~/Downloads, with a Done alert.")
                    toggle("Put finished downloads on the shelf", $prefs.addDownloadsToShelf)
                    toggle("Timer sound", $prefs.timerSoundEnabled)
                    toggle("Caps Lock", $prefs.capsLockEnabled, note: "A brief pill when Caps Lock turns on or off.")
                    toggle("Lyrics", $prefs.lyricsEnabled, note: "Time-synced lyrics under Now Playing, from LRCLIB.")
                    toggle("Audio-reactive visualizer", $prefs.reactiveVisualizerEnabled, note: "The bars follow the actual sound instead of a pattern. macOS asks for system audio capture access; nothing is recorded.")
                    toggle("Replace the system volume and brightness bezel", $prefs.hudReplacementEnabled, note: "The island becomes the only HUD for volume, mute and brightness. macOS asks for Accessibility access the first time. Hold Shift+Option for quarter steps; keyboard backlight keys are left to macOS.")
                }

                section("Shelf and clipboard") {
                    toggle("File shelf", $prefs.shelfEnabled, note: "Drag files onto the notch to keep them within reach. Select several, AirDrop them, or right-click for more.")
                    slider("Clear shelf items after", $prefs.shelfExpiryHours, range: 0...168, unit: "h", zeroLabel: "Never")
                    toggle("Clipboard history", $prefs.clipboardEnabled, note: "Recent copies in the Home panel. Password managers' concealed items are skipped.")
                    slider("Clipboard items kept", $prefs.clipboardLimit, range: 10...200, unit: "")
                    toggle("Quick actions", $prefs.quickActionsEnabled, note: "Run your Shortcuts from the island.")
                    toggle("Camera mirror", $prefs.mirrorEnabled, note: "A Mirror tab in the Home panel to check yourself before a call. Asks for camera access when opened.")
                    toggle("System stats", $prefs.statsEnabled, note: "CPU, memory, network and battery health in the Home panel.")
                    toggle("Weather", $prefs.weatherEnabled, note: "A Weather tab in the Home panel. Asks for your location when opened; data from Open-Meteo.")
                    toggle("Trackpad gestures on the island", $prefs.gesturesEnabled, note: "Swipe sideways to skip tracks or switch Home tabs; scroll up or down for volume.")
                }

                if prefs.quickActionsEnabled {
                    section("Quick actions") {
                        QuickActionsSettingsView()
                    }
                }

                section("Energy") {
                    toggle("Pause animations on battery", $prefs.pauseAnimationsOnBattery, note: "The visualizer and marquee already slow down on battery and stop in Low Power Mode and during sleep.")
                }

                section("Notch") {
                    slider("Width override", $prefs.notchWidthOverride, range: 0...320, unit: "pt", zeroLabel: "Auto")
                    slider("Height override", $prefs.notchHeightOverride, range: 0...60, unit: "pt", zeroLabel: "Auto")
                }

                section("Status") {
                    StatusRows()
                }

                section("Automation") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Push your own Live Activities from scripts and Shortcuts.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("open \"notchisland://activity?id=build&title=Building&symbol=hammer.fill&tint=blue&progress=0.4\"")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Text("open \"notchisland://activity/end?id=build\"")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Text("See Scripts/notchctl for a command-line helper.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Rows

    /// Live health of each data source, so a silently failing feature isn't a mystery.
    private struct StatusRows: View {
        @ObservedObject private var music = NowPlayingService.shared
        @State private var tick = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                row("Now Playing source", musicStatus)
                row("Media helper", AdapterBackend.dylibURL != nil ? "Bundled" : "Missing (AppleScript fallback)")
                row("Focus database", FocusMonitor.isReadable ? "Readable" : "Not readable")
                row("Calendar access", calendarStatus)
                row("Accessibility (HUD replacement)", MediaKeyInterceptor.isTrusted ? "Granted" : "Not granted")
            }
            .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
        }

        private var musicStatus: String {
            switch music.activeBackend {
            case .adapter: return "MediaRemote helper"
            case .mediaRemote: return "MediaRemote"
            case .appleScript: return "AppleScript (Music / Spotify)"
            case .inactive: return "Nothing playing"
            }
        }

        private var calendarStatus: String {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized: return "Granted"
            case .denied, .restricted: return "Denied"
            case .writeOnly: return "Write only"
            default: return "Not asked yet"
            }
        }

        private func row(_ title: String, _ value: String) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title).font(.system(size: 15))
                    Spacer()
                    Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 9)
                Divider().opacity(0.5)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            content()
        }
        .padding(.bottom, 26)
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15))
                    if let note {
                        Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.primary)
            }
            .padding(.vertical, 9)
            Divider().opacity(0.5)
        }
    }

    private func slider(_ title: String, _ binding: Binding<Double>, range: ClosedRange<Double>, unit: String, zeroLabel: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15))
                Spacer()
                Text(binding.wrappedValue == 0 && zeroLabel != nil ? zeroLabel! : formatted(binding.wrappedValue, unit: unit))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                Slider(value: binding, in: range)
                    .frame(width: 150)
                    .tint(.primary)
            }
            .padding(.vertical, 9)
            Divider().opacity(0.5)
        }
    }

    private func formatted(_ value: Double, unit: String) -> String {
        if unit == "s" { return String(format: "%.2f s", value) }
        return "\(Int(value.rounded())) \(unit)"
    }
}
