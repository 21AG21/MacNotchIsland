import SwiftUI

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
                    toggle("Show on every display", $prefs.showOnAllDisplays, note: "Displays without a notch get a simulated island.")
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
                    toggle("Timer sound", $prefs.timerSoundEnabled)
                }

                section("Shelf") {
                    toggle("File shelf", $prefs.shelfEnabled, note: "Drag files onto the notch to keep them within reach.")
                }

                section("Notch") {
                    slider("Width override", $prefs.notchWidthOverride, range: 0...320, unit: "pt", zeroLabel: "Auto")
                    slider("Height override", $prefs.notchHeightOverride, range: 0...60, unit: "pt", zeroLabel: "Auto")
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
