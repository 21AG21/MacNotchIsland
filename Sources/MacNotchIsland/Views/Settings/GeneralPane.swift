import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "General": when Notch Island runs, where the island shows itself, and the notch geometry.
struct GeneralPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $prefs.launchAtLogin)
                    .help("Start Notch Island automatically when you log in.")
                Toggle("Check for updates automatically", isOn: $prefs.updateChecksEnabled)
                    .help("Look for a newer release once a day.")
            } header: {
                Text("Startup")
            } footer: {
                Text("Update checks run once a day against the project's releases page. Nothing is downloaded or installed automatically.")
            }

            Section {
                Toggle("Show on all displays", isOn: $prefs.showOnAllDisplays)
                    .help("Displays without a notch get a simulated island along the top edge.")
                Toggle("Hide in full-screen apps", isOn: $prefs.hideInFullscreen)
                    .help("Keep the island out of the way while an app is full screen.")
            } header: {
                Text("Appearance")
            } footer: {
                Text("The island returns as soon as you leave full screen.")
            }

            Section {
                HiddenAppsList()
            } header: {
                Text("Hide for these apps")
            } footer: {
                Text("The island stays hidden while one of these apps is frontmost.")
            }

            Section {
                SettingsSlider("Width", value: $prefs.notchWidthOverride,
                               range: 0...320, unit: "pt", zeroLabel: "Automatic")
                SettingsSlider("Height", value: $prefs.notchHeightOverride,
                               range: 0...60, unit: "pt", zeroLabel: "Automatic")
            } header: {
                Text("Notch size")
            } footer: {
                Text("Leave both automatic unless the island sits slightly off your notch.")
            }

            Section {
                Toggle("Pause animations on battery", isOn: $prefs.pauseAnimationsOnBattery)
                    .help("Stop the visualizer and the scrolling title while unplugged.")
            } header: {
                Text("Energy")
            } footer: {
                Text("Animations already slow down on battery, and stop in Low Power Mode and while your Mac sleeps.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The per-app hide list, laid out like Login Items: a bordered list of apps with an add and a
/// remove button underneath. Only bundle identifiers are stored, so a moved app still matches.
struct HiddenAppsList: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach(prefs.hiddenAppBundleIDs, id: \.self) { bundleID in
                    row(for: bundleID)
                        .tag(bundleID)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 118)
            .overlay {
                if prefs.hiddenAppBundleIDs.isEmpty {
                    Text("No apps")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
                Button {
                    addApps()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 16)
                }
                .help("Add an app.")
                .accessibilityLabel(Text("Add an app"))

                Button {
                    removeSelection()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 18, height: 16)
                }
                .disabled(selection == nil)
                .help("Remove the selected app.")
                .accessibilityLabel(Text("Remove the selected app"))

                Spacer()
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Rows

    private func row(for bundleID: String) -> some View {
        HStack(spacing: 8) {
            icon(for: bundleID)
                .frame(width: 16, height: 16)
            Text(name(for: bundleID))
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(bundleID)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func icon(for bundleID: String) -> some View {
        if let image = Self.appIcon(for: bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "questionmark.app.dashed")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Editing

    /// An open panel restricted to applications, starting in /Applications, exactly like the
    /// picker System Settings uses for Login Items.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps that should hide the island while they are frontmost."
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var identifiers = prefs.hiddenAppBundleIDs
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else { continue }
            guard !identifiers.contains(bundleID) else { continue }
            identifiers.append(bundleID)
        }
        guard identifiers != prefs.hiddenAppBundleIDs else { return }
        prefs.hiddenAppBundleIDs = identifiers
    }

    private func removeSelection() {
        guard let selection else { return }
        prefs.hiddenAppBundleIDs.removeAll { $0 == selection }
        self.selection = nil
    }

    // MARK: Lookup

    private func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let display = FileManager.default.displayName(atPath: url.path)
        return display.isEmpty ? bundleID : display
    }

    private static func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
