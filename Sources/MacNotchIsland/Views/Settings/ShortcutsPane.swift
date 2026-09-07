import SwiftUI

/// "Shortcuts": which of the user's Shortcuts become quick actions in the Home panel.
struct ShortcutsPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            if prefs.quickActionsEnabled {
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
}
