import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Actions": the apps and Shortcuts that become buttons in the panel's Actions section.
struct ShortcutsPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var apps = FavoriteApps.shared

    var body: some View {
        Form {
            if prefs.quickActionsEnabled {
                Section {
                    ForEach(apps.apps, id: \.path) { app in
                        LabeledContent {
                            HStack(spacing: 6) {
                                Button("Move Up") { apps.move(app.path, up: true) }
                                    .disabled(apps.paths.first == app.path)
                                Button("Remove") { apps.remove(app.path) }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if let icon = apps.icon(for: app.path) {
                                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                }
                                Text(app.name)
                            }
                        }
                    }
                    Button("Add App…") { chooseApp() }
                        .disabled(apps.paths.count >= FavoriteApps.maximum)
                } header: {
                    Text("Apps")
                } footer: {
                    Text("Up to \(FavoriteApps.maximum) apps sit at the front of the Actions section, before your Shortcuts. Clicking one opens it and closes the panel.")
                }

                Section {
                    QuickActionsSettingsView()
                } header: {
                    Text("Quick actions")
                } footer: {
                    Text("Favourites appear in the Home panel, up to eight, in the order you turn them on. The symbol field takes any SF Symbol name.")
                }
            } else {
                Section {
                    LabeledContent {
                        Button("Turn On") {
                            prefs.quickActionsEnabled = true
                        }
                    } label: {
                        Text("Quick actions are off")
                        Text("Turn them on to run your Shortcuts from the Home panel.")
                    }
                } header: {
                    Text("Quick actions")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The standard open panel, pointed at /Applications and accepting only apps.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose an app for the Actions section."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        apps.add(url)
    }
}
