import SwiftUI

@main
struct MacNotchIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(ActivityCenter.shared)
                .environmentObject(Preferences.shared)
        }
    }
}
