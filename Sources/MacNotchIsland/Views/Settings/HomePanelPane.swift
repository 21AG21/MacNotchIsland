import SwiftUI

/// "Home Panel": the sections the panel can show beside Now Playing, and the control rail
/// under them.
struct HomePanelPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var windows = WindowsMonitor.shared
    @AppStorage("settingsSection") private var selectedSection = SettingsSection.general.rawValue
    /// Held rather than built inside `onReceive`, where it would be a new publisher on every
    /// pass of the body — and this body runs whenever a preference on it changes.
    private let permissionTicker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// The choices offered for shelf expiry, in hours.
    private static let expiryOptions: [Double] = [0, 1, 6, 24, 72, 168]

    var body: some View {
        Form {
            Section {
                Toggle("Today", isOn: $prefs.calendarEnabled)
                    .help("Your next events and reminders. Asks for calendar and reminders access when first opened.")
                Toggle("Weather in Today", isOn: $prefs.weatherEnabled)
                    .help("The conditions outside, in the Today header. Asks for your location when first opened. Data from Open-Meteo.")
                    .disabled(!prefs.calendarEnabled)
                Toggle("Windows", isOn: $prefs.windowsEnabled)
                    .help("Every open window as a live tile: click one to bring it forward, or snap it to a half of the screen. Asks for Screen Recording to draw the pictures and Accessibility to move windows.")
                Toggle("Shelf", isOn: $prefs.shelfEnabled)
                    .help("Drag files onto the island to keep them within reach.")
                Toggle("Clipboard", isOn: $prefs.clipboardEnabled)
                    .help("Recent copies, pinned ones first.")
                Toggle("Actions", isOn: $prefs.quickActionsEnabled)
                    .help("Run your favourite shortcuts from the panel.")
                Toggle("Notes", isOn: $prefs.notesEnabled)
                    .help("A scratchpad that keeps whatever you type.")
                Toggle("Stats", isOn: $prefs.statsEnabled)
                    .help("Processor, memory, network and battery health.")
            } header: {
                Text("Sections")
            } footer: {
                Text("Now Playing is always there. Step between sections with the buttons beside the notch, a sideways swipe, or Tab.")
            }

            Section {
                Picker("Clear items after", selection: expiry) {
                    Text("Never").tag(0.0)
                    Text("1 hour").tag(1.0)
                    Text("6 hours").tag(6.0)
                    Text("1 day").tag(24.0)
                    Text("3 days").tag(72.0)
                    Text("1 week").tag(168.0)
                }
                .pickerStyle(.menu)
                Toggle("Add downloads to the shelf", isOn: $prefs.addDownloadsToShelf)
                    .help("Finished downloads land on the shelf instead of only alerting.")
                Toggle("Add screenshots to the shelf", isOn: $prefs.screenshotsToShelfEnabled)
                    .help("New screenshots land on the shelf, ready to drag into another app.")
            } header: {
                Text("Shelf")
            } footer: {
                // Not "never from disk", which was not true: a picture, link or note the
                // island wrote for the shelf has nowhere else to live, and goes to the Trash
                // when it leaves. A promise on this screen has to hold for every case of it.
                Text("Select several items to drag or AirDrop them together. Clearing never touches a file you dragged in from Finder. A picture, link or note the island wrote itself goes to the Trash, where you can get it back.")
            }
            .disabled(!prefs.shelfEnabled)

            Section {
                Stepper(value: $prefs.clipboardLimit, in: 10...200, step: 10) {
                    Text("Items kept: \(Int(prefs.clipboardLimit))")
                }
                Toggle("Paste after picking an item", isOn: $prefs.pasteOnPick)
                    .help("Clicking an item closes the panel and pastes it where you were typing. Needs Accessibility; without it the item is only put on the pasteboard.")
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Kept on this Mac, in Notch Island's own folder, where only your account can read it. Anything a password manager marks as concealed, or another tool marks as its own, is never recorded at all.")
            }
            .disabled(!prefs.clipboardEnabled)

            Section {
                LabeledContent("Pictures of windows") {
                    HStack(spacing: 8) {
                        Text(windows.canCapture ? "Allowed" : "Not allowed")
                            .foregroundStyle(.secondary)
                        Button("Screen Recording…") { SystemSettingsPane.screenRecording.open() }
                    }
                }
                LabeledContent("Moving windows") {
                    HStack(spacing: 8) {
                        Text(windows.canMove ? "Allowed" : "Not allowed")
                            .foregroundStyle(.secondary)
                        Button("Accessibility…") { SystemSettingsPane.accessibility.open() }
                    }
                }
            } header: {
                Text("Windows")
            } footer: {
                Text("Without Screen Recording the windows are still listed, by app, with no picture and no title.")
            }
            .disabled(!prefs.windowsEnabled)
            // Permissions are granted in System Settings, which tells nobody; the rows are
            // re-read while this pane is open so a grant shows up without a relaunch.
            .onReceive(permissionTicker) { _ in windows.refreshPermissions() }

            Section {
                Toggle("Camera mirror", isOn: $prefs.mirrorEnabled)
                    .help("A mirror button in the rail, to check yourself before a call. Asks for camera access when first opened.")
            } header: {
                Text("Control rail")
            } footer: {
                HStack(spacing: 8) {
                    Text("Volume, light and dark, Keep Awake and Settings are in the rail under every section; brightness, Wi-Fi and Bluetooth when this Mac has them, and AirDrop when there is something on the shelf and you are not looking at it. Choose the apps and shortcuts that appear in the Actions section there.")
                    Button("Open Actions") {
                        selectedSection = SettingsSection.shortcuts.rawValue
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Menus store discrete choices; a value set by an older build is shown as its nearest match.
    private var expiry: Binding<Double> {
        Binding(
            get: { SettingsFormat.nearest(prefs.shelfExpiryHours, in: Self.expiryOptions) },
            set: { prefs.shelfExpiryHours = $0 }
        )
    }
}
