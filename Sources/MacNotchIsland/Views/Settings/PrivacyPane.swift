import AVFoundation
import CoreGraphics
import CoreLocation
import EventKit
import SwiftUI

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
    /// Held, not built inside `onReceive`: a publisher made there is a new publisher on every
    /// pass of the body, and this body runs on every beat of it.
    private let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                permission(
                    "Accessibility",
                    detail: "Moves windows from the Windows section, and replaces the system volume and brightness bezel.",
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
                    detail: "Used by the Mirror tab. The camera indicator itself never captures video.",
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
                    detail: "Used by the weather line in Today for your approximate location.",
                    status: locationStatus,
                    pane: .location
                )
                permission(
                    "Calendars",
                    detail: "Used to show your next event shortly before it starts.",
                    status: Self.calendarStatus,
                    pane: .calendars
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
                Text("Every permission is optional, and asked for only when the feature that needs it is turned on.")
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
                Text("Nothing else does, and each of these stops the moment its switch goes off. There is no account, no analytics, and nothing is ever sent about what you copy, type, open or look at.")
            }

            Section {
                LabeledContent("Focus database", value: FocusMonitor.isReadable ? "Readable" : "Not readable")
            } header: {
                Text("Status")
            } footer: {
                Text("Focus is read from a local file that macOS keeps in your home folder. Playback sources are listed in Media.")
            }
        }
        .formStyle(.grouped)
        .onReceive(ticker) { _ in tick += 1 }
    }

    // MARK: Rows

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
        switch EKEventStore.authorizationStatus(for: .event) {
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
