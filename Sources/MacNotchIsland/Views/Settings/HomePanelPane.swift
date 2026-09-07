import SwiftUI

/// "Home Panel": the drawer behind the island — shelf, clipboard and the tabs it can show.
struct HomePanelPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @AppStorage("settingsSection") private var selectedSection = SettingsSection.general.rawValue

    /// The choices offered for shelf expiry, in hours.
    private static let expiryOptions: [Double] = [0, 1, 6, 24, 72, 168]

    var body: some View {
        Form {
            Section {
                Toggle("File shelf", isOn: $prefs.shelfEnabled)
                    .help("Drag files onto the notch to keep them within reach.")
                Picker("Clear items after", selection: expiry) {
                    Text("Never").tag(0.0)
                    Text("1 hour").tag(1.0)
                    Text("6 hours").tag(6.0)
                    Text("1 day").tag(24.0)
                    Text("3 days").tag(72.0)
                    Text("1 week").tag(168.0)
                }
                .pickerStyle(.menu)
                .disabled(!prefs.shelfEnabled)
                Toggle("Add downloads to the shelf", isOn: $prefs.addDownloadsToShelf)
                    .help("Finished downloads land on the shelf instead of only alerting.")
                    .disabled(!prefs.shelfEnabled)
                Toggle("Add screenshots to the shelf", isOn: $prefs.screenshotsToShelfEnabled)
                    .help("New screenshots land on the shelf, ready to drag into another app.")
                    .disabled(!prefs.shelfEnabled)
            } header: {
                Text("Shelf")
            } footer: {
                Text("Select several items to drag or AirDrop them together. Clearing removes them from the shelf only, never from disk.")
            }

            Section {
                Toggle("Clipboard history", isOn: $prefs.clipboardEnabled)
                    .help("Keep recent copies in the Home panel.")
                Stepper(value: $prefs.clipboardLimit, in: 10...200, step: 10) {
                    Text("Items kept: \(Int(prefs.clipboardLimit))")
                }
                .disabled(!prefs.clipboardEnabled)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Items marked as concealed by password managers are never recorded.")
            }

            Section {
                Toggle("Quick actions", isOn: $prefs.quickActionsEnabled)
                    .help("Run your favourite shortcuts from the Home panel.")
                Toggle("Camera mirror", isOn: $prefs.mirrorEnabled)
                    .help("Check yourself before a call. Asks for camera access when first opened.")
                Toggle("System stats", isOn: $prefs.statsEnabled)
                    .help("Processor, memory, network and battery health.")
                Toggle("Weather", isOn: $prefs.weatherEnabled)
                    .help("Asks for your location when first opened. Data from Open-Meteo.")
            } header: {
                Text("Tabs")
            } footer: {
                HStack(spacing: 8) {
                    Text("Choose which shortcuts appear as quick actions in Shortcuts.")
                    Button("Open Shortcuts") {
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
