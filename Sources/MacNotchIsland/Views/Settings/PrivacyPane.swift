import AVFoundation
import CoreGraphics
import CoreLocation
import EventKit
import SwiftUI
import UserNotifications

/// "Privacy": what Notch Island is allowed to see, why it asks, and a way
/// straight to the matching pane in System Settings. Also the live health of each data
/// source, so a silently failing feature is never a mystery.
struct PrivacyPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var locationManager = CLLocationManager()
    /// Nothing on this pane is published: every status is read from the system as the body is
    /// built. Touching this is what asks for the body again, so a permission granted in System
    /// Settings while this window is open turns from "Not granted" to "Granted" on its own.
    @State private var tick = 0
    /// Read asynchronously, unlike every other status on this pane, so it is held rather than
    /// asked for while the body is being built.
    @State private var notificationStatus = "Not asked yet"
    /// Held, not built inside `onReceive`: a publisher made there is a new publisher on every
    /// pass of the body, and this body runs on every beat of it.
    private let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                permission(
                    "Accessibility",
                    detail: "Moves windows from the Windows section, replaces the system volume and brightness bezel, and is what lets the Notifications section read the banners it keeps — without it that section stays empty.",
                    status: MediaKeyInterceptor.isTrusted ? "Granted" : "Not granted",
                    pane: .accessibility
                )
                permission(
                    "Screen Recording",
                    detail: "Draws the picture of each window in the Windows section. Nothing is ever recorded or sent.",
                    status: CGPreflightScreenCaptureAccess() ? "Granted" : "Not granted",
                    pane: .screenRecording
                )
                permission(
                    "Camera",
                    detail: "Used by the mirror in the control rail. The camera indicator itself never captures video.",
                    status: Self.captureStatus(for: .video),
                    pane: .camera
                )
                permission(
                    "Microphone",
                    detail: "Only checked to show the microphone indicator. Nothing is recorded.",
                    status: Self.captureStatus(for: .audio),
                    pane: .microphone
                )
                permission(
                    "Location",
                    detail: "Used by the weather line in Today for your approximate location, and by the Wi-Fi list in Controls, since macOS only tells an app the names of the networks around it once Location allows it.",
                    status: locationStatus,
                    pane: .location
                )
                permission(
                    "Calendars",
                    detail: "Used to show your next event shortly before it starts.",
                    status: Self.calendarStatus,
                    pane: .calendars
                )
                // Asked for alongside the calendar, and granted separately: this screen lists
                // what the app may see, and one of the two things Today reads was missing
                // from it.
                permission(
                    "Reminders",
                    detail: "Used to show what is still due today, under your events.",
                    status: Self.remindersStatus,
                    pane: .reminders
                )
                permission(
                    "Notifications",
                    detail: "A banner when a timer goes off while the island is hidden or an app is full screen.",
                    status: notificationStatus,
                    pane: .notifications
                )
                permission(
                    "Automation",
                    detail: "Lets Notch Island ask Music and Spotify what is playing when the system player is quiet.",
                    status: "Asked when needed",
                    pane: .automation
                )
            } header: {
                Text("Permissions")
            } footer: {
                Text("Every permission is optional, and asked for only when the feature that needs it is turned on. macOS ties each one to the exact copy of the app it was granted to, so replacing this build with a newer one starts them from nothing again — nothing is wrong, and this list is where to see it.")
            }

            // Named, one by one. This used to say "nothing Notch Island reads ever leaves your
            // Mac", which was not true of the four features that ask somebody else a question —
            // and a blanket promise is the worst possible thing to be wrong about on the screen
            // where somebody comes to check.
            Section {
                outbound("Weather", detail: "Where you are, rounded to about a hundred metres — never an address.",
                         host: "open-meteo.com", on: prefs.weatherEnabled)
                outbound("Lyrics", detail: "The title and artist of what is playing.",
                         host: "lrclib.net", on: prefs.lyricsEnabled)
                outbound("Missing album art", detail: "The title, artist and album of what is playing, when the player hands over no cover. A cover Spotify names is fetched from the address Spotify gave.",
                         host: "itunes.apple.com", on: prefs.artworkLookupEnabled)
                outbound("Update check", detail: "Nothing about you or this Mac. It asks what the newest release is.",
                         host: "api.github.com", on: prefs.updateChecksEnabled)
            } header: {
                Text("What leaves this Mac")
            } footer: {
                Text("Nothing else does, and each of these stops the moment its switch goes off. There is no account, no analytics, and nothing is ever sent about what you copy, type, open, look at, or are notified about.")
            }

            // What is on the island is the other way something can leave the Mac: on somebody
            // else's screen, in the middle of a call, with the panel open on the clipboard.
            Section {
                let shown = ScreenSharingSwitches.shown(hidden: prefs.hiddenFromScreenSharing,
                                                        duringCalls: prefs.hideFromScreenSharingDuringCalls)
                Toggle("Hide the island from screen sharing", isOn: Binding(
                    get: { shown.hide },
                    set: { on in storeScreenSharing(hide: on, onlyDuringCalls: false) }
                ))
                .help("Leave the island out of screen sharing, screen recordings and screenshots.")
                Toggle("Only during calls", isOn: Binding(
                    get: { shown.onlyDuringCalls },
                    set: { on in storeScreenSharing(hide: true, onlyDuringCalls: on) }
                ))
                .disabled(!shown.hide)
                .help("Hide it only during a call.")
            } header: {
                Text("Screen sharing")
            } footer: {
                Text("The panel can show what you copied, your notes and your notification history. Hidden, the island is left out of what a screen share, a recording or a screenshot can see — while a call is on, or all the time. Screen sharing built on ScreenCaptureKit may still show it on macOS 15 and later.")
            }

            Section {
                // Read once per pass of the body, which the ticker below asks for every few
                // seconds, so a grant made in System Settings shows up here on its own.
                let focusReadable = FocusMonitor.isReadable
                LabeledContent("Focus database") {
                    HStack(spacing: 10) {
                        Text(focusReadable ? "Readable" : "Not readable")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if !focusReadable {
                            Button("Open Full Disk Access") { SystemSettingsPane.fullDiskAccess.open() }
                                .help("Open the Full Disk Access pane in System Settings.")
                        }
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Focus is read from a local file that macOS keeps in your home folder, and macOS may refuse to hand it over without Full Disk Access. Playback sources are listed in Media.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshNotifications)
        .onReceive(ticker) { _ in
            tick += 1
            refreshNotifications()
        }
    }

    // MARK: Rows

    /// Writes what the two screen-sharing switches say into the two preferences behind them.
    private func storeScreenSharing(hide: Bool, onlyDuringCalls: Bool) {
        let stored = ScreenSharingSwitches.stored(hide: hide, onlyDuringCalls: onlyDuringCalls)
        prefs.hiddenFromScreenSharing = stored.hidden
        prefs.hideFromScreenSharingDuringCalls = stored.duringCalls
    }

    private func permission(_ title: String, detail: String, status: String,
                            pane: SystemSettingsPane) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open") { pane.open() }
                    .help("Open the \(title) pane in System Settings.")
                    .accessibilityLabel(Text("Open \(title) in System Settings"))
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    /// One thing the app asks somebody else: what is sent, who is asked, and whether it is
    /// switched on at this moment.
    private func outbound(_ title: String, detail: String, host: String, on: Bool) -> some View {
        LabeledContent {
            Text(on ? host : "Off")
                .font(.callout)
                .foregroundStyle(.secondary)
        } label: {
            Text(title)
            Text(detail)
        }
    }

    // MARK: Status

    /// Only a real .app bundle may ask the notification centre anything; unbundled it traps.
    private func refreshNotifications() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "Granted"
            case .denied: text = "Denied"
            case .notDetermined: text = "Not asked yet"
            @unknown default: text = "Unknown"
            }
            DispatchQueue.main.async {
                if self.notificationStatus != text { self.notificationStatus = text }
            }
        }
    }

    private static func captureStatus(for type: AVMediaType) -> String {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private static var calendarStatus: String {
        status(EKEventStore.authorizationStatus(for: .event))
    }

    /// Reminders is a permission of its own, granted or refused separately from the calendar.
    private static var remindersStatus: String {
        status(EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func status(_ value: EKAuthorizationStatus) -> String {
        switch value {
        case .fullAccess, .authorized: return "Granted"
        case .denied, .restricted: return "Denied"
        case .writeOnly: return "Write only"
        default: return "Not asked yet"
        }
    }

    /// The authorized cases differ across platforms and SDK versions, so only the three
    /// stable ones are named and everything else counts as granted.
    private var locationStatus: String {
        switch locationManager.authorizationStatus {
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not asked yet"
        default: return "Granted"
        }
    }
}

/// The two screen-sharing switches, read from and written to the two preferences behind them.
///
/// The preferences are independent — hidden always, hidden during calls — because that is the
/// rule the panel applies (`NotchPanel.sharesScreen`). The switches read as one choice and a
/// refinement of it: hide the island, and then whether only during calls. The shipping pair,
/// not always but during calls, reads as both switches on.
enum ScreenSharingSwitches {
    static func shown(hidden: Bool, duringCalls: Bool) -> (hide: Bool, onlyDuringCalls: Bool) {
        (hide: hidden || duringCalls, onlyDuringCalls: duringCalls && !hidden)
    }

    /// Turning the first switch on hides the island all the time, which is what it says.
    static func stored(hide: Bool, onlyDuringCalls: Bool) -> (hidden: Bool, duringCalls: Bool) {
        guard hide else { return (hidden: false, duringCalls: false) }
        return onlyDuringCalls ? (hidden: false, duringCalls: true) : (hidden: true, duringCalls: false)
    }
}
