import SwiftUI

@main
struct MacNotchIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// SwiftUI wants a scene and this is the natural one to declare, but nothing opens it: on
    /// an app with no Dock icon its window never appears, which is how every switch in Settings
    /// came to be unreachable. `SettingsWindow` builds and shows the real one.
    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(ActivityCenter.shared)
                .environmentObject(Preferences.shared)
        }
    }
}
