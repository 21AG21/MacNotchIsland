import SwiftUI

/// First-launch welcome, laid out the way Apple's own apps introduce themselves:
/// app icon, "Welcome to …", a short column of symbol + title + description rows,
/// and one prominent Continue button. Flat ground, system type, no boxes.
struct WelcomeView: View {
    @EnvironmentObject private var prefs: Preferences
    var dismiss: () -> Void

    private var shortcut: String {
        HotKeyService.displayString(keyCode: HotKeyService.currentKeyCode,
                                    carbonModifiers: HotKeyService.currentModifiers)
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
                .padding(.top, 8)

            Text("Welcome to Notch Island")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 14)
            Text("Your notch is now a Dynamic Island.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 18) {
                row("cursorarrow.rays", "Hover to expand",
                    "See what is playing, counting down or downloading without opening the app. Click to jump to it.")
                row("tray.and.arrow.down", "Drop files on the shelf",
                    "Drag anything onto the island and it waits there until you drag it out again.")
                row("keyboard", "Press \(shortcut)",
                    "Summon the island from anywhere, even in full-screen apps.")
                row("menubar.rectangle", "Find it in the menu bar",
                    "Settings, timers and the stopwatch are a click away in the menu bar.")
            }
            .frame(maxWidth: 400, alignment: .leading)
            .padding(.top, 32)

            Spacer(minLength: 24)

            VStack(spacing: 12) {
                Button(action: dismiss) {
                    Text("Continue")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(width: 300)

                Button("Show an Example") {
                    ActivityCenter.shared.showAlert(IslandActivity(id: "battery", kind: .battery,
                        content: .battery(BatteryState(percent: 82, isCharging: true, isPluggedIn: true, event: .pluggedIn)),
                        priority: 85))
                }
                .buttonStyle(.link)
                .font(.system(size: 12))

                Toggle("Open at login", isOn: $prefs.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .padding(.bottom, 28)
        .frame(width: 500, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .frame(width: 40, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Owns the welcome window; shown once, or from the menu bar.
final class WelcomeWindowController: NSObject, NSWindowDelegate {
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
        w.isMovableByWindowBackground = true
        w.title = "Welcome to Notch Island"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        Preferences.shared.hasSeenWelcome = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Preferences.shared.hasSeenWelcome = true
    }
}
