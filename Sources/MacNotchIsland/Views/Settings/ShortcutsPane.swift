import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Actions": the apps and Shortcuts that become buttons in the panel's Actions section.
///
/// The two lists share one row of ten (`QuickActionsRowView.capacity`), so each is capped by
/// what the other leaves as well as by its own limit: the pane counted them apart, and six
/// apps with eight favourites was fourteen buttons chosen for a row that drew eight.
struct ShortcutsPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var apps = FavoriteApps.shared
    @ObservedObject private var runner = ShortcutsRunner.shared

    /// How many apps the row has room for beside the favourites chosen.
    private var appRoom: Int { QuickActionsRowView.appRoom(besideShortcuts: runner.favorites.count) }

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
                    // Not drawn in the row while their disk is unplugged, but kept, and counted
                    // against the room (`FavoriteApps.hasRoom`): listed so that the place one
                    // holds can be given up here rather than only by plugging the disk in.
                    ForEach(apps.away, id: \.path) { app in
                        LabeledContent {
                            Button("Remove") { apps.remove(app.path) }
                        } label: {
                            Text(app.name)
                            Text("On a disk that is not plugged in. It keeps its place, and is back in the row when the disk is.")
                        }
                    }
                    Button("Add App…") { chooseApp() }
                        .disabled(!apps.hasRoom(beside: appRoom))
                } header: {
                    Text("Apps")
                } footer: {
                    Text("Up to \(FavoriteApps.maximum) apps sit at the front of the Actions section, before your Shortcuts, in a row of \(QuickActionsRowView.capacity) buttons the two share. Clicking one opens it and closes the panel.")
                }

                Section {
                    QuickActionsSettingsView()
                } header: {
                    Text("Quick actions")
                } footer: {
                    Text("Favourites appear in the Actions section after your apps, in the order you turn them on: up to \(ShortcutsRunner.maxFavorites), and \(QuickActionsRowView.capacity) buttons in all with the apps. The symbol field takes any SF Symbol name.")
                }
            } else {
                Section {
                    LabeledContent {
                        Button("Turn On") {
                            prefs.quickActionsEnabled = true
                        }
                    } label: {
                        Text("Quick actions are off")
                        // The switch is the whole Actions section, not only the Shortcuts: the
                        // favourite apps and the timers go with it.
                        Text("The Actions section is hidden, with your apps, your Shortcuts and the timers. Turn it on to have them in the panel again.")
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
        apps.add(url, room: appRoom)
    }
}
