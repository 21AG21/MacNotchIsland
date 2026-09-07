import SwiftUI

/// First-launch welcome. House style: flat ground, big type, no boxes, one real action.
struct WelcomeView: View {
    @EnvironmentObject private var prefs: Preferences
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notch Island")
                .font(.system(size: 40, weight: .medium))
                .tracking(-1)
            Text("Your notch is now a Dynamic Island.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 30)

            row("Hover the notch", "Expands whatever is live: music, a timer, a call, a download. Click to open the app behind it.")
            row("Drag files onto it", "They stay on the shelf until you drag them out again.")
            row("Press ⌃⌥Space", "Summons the island from anywhere, even in full-screen apps.")
            row("Watch the menu bar capsule", "Settings, timers, a demo of every alert, and Quit live there.")

            Spacer(minLength: 20)

            HStack {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                    .toggleStyle(.switch)
                    .tint(.primary)
                    .font(.system(size: 14))
                Spacer()
                Button(action: {
                    ActivityCenter.shared.showAlert(IslandActivity(id: "battery", kind: .battery,
                        content: .battery(BatteryState(percent: 82, isCharging: true, isPluggedIn: true, event: .pluggedIn)), priority: 85))
                }) {
                    Text("Show me").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button(action: dismiss) {
                    Text("Get started")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.primary))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .padding(.leading, 14)
            }
        }
        .padding(36)
        .frame(width: 520, height: 470, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 16)
    }
}

/// Owns the welcome window; shown once, or from the menu bar.
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func showIfFirstLaunch() {
        guard !Preferences.shared.hasSeenWelcome else { return }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = WelcomeView(dismiss: { [weak self] in self?.close() })
            .environmentObject(Preferences.shared)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Welcome to Notch Island"
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        Preferences.shared.hasSeenWelcome = true
        window?.close()
    }
}
