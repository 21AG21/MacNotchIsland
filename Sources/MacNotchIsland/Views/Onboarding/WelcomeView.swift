import Carbon.HIToolbox
import SwiftUI

/// First-launch welcome, laid out the way Apple's own apps introduce themselves:
/// app icon, "Welcome to …", a short column of symbol + title + description rows,
/// and one prominent Continue button. Flat ground, system type, no boxes.
struct WelcomeView: View {
    @EnvironmentObject private var prefs: Preferences
    var dismiss: () -> Void
    @State private var page = 0

    private var shortcut: String {
        HotKeyService.displayString(keyCode: HotKeyService.currentKeyCode,
                                    carbonModifiers: HotKeyService.currentModifiers)
    }

    private var tabShortcut: String {
        HotKeyService.displayString(keyCode: kVK_Tab, carbonModifiers: HotKeyService.currentModifiers)
    }

    var body: some View {
        ZStack {
            if page == 0 {
                welcome.transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
            } else {
                picker.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .padding(.bottom, 28)
        .frame(width: 500, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
    }

    // MARK: - Page one: what it is

    private var welcome: some View {
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
                row("cursorarrow.motionlines", "Rest the pointer on it",
                    "The island shows what is playing, counting down or downloading. Hover to peek at the full view; click to keep it open.")
                row("rectangle.split.3x1", "One panel for everything",
                    "Music, today's agenda, the shelf, clipboard, notes and stats, with volume and brightness under them. Step between them beside the notch or with a swipe.")
                row("tray.and.arrow.down", "Drop files on the shelf",
                    "Drag anything onto the island and it waits there until you drag it out again, or AirDrop it from the rail.")
                row("keyboard", "Press \(shortcut)",
                    "Opens the panel from anywhere. \(tabShortcut) steps through every section; Escape closes.")
            }
            .frame(maxWidth: 400, alignment: .leading)
            .padding(.top, 32)

            Spacer(minLength: 24)

            VStack(spacing: 12) {
                Button(action: { withAnimation(.easeInOut(duration: 0.3)) { page = 1 } }) {
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
            }
        }
    }

    // MARK: - Page two: what it shows

    private var picker: some View {
        VStack(spacing: 0) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(height: 80)
                .accessibilityHidden(true)
                .padding(.top, 8)

            Text("Choose What It Shows")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 14)
            Text("Now Playing is always there. Everything else is up to you, and can change later in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 14) {
                choice("calendar", "Today", "Your next events and reminders. Asks for calendar access.", $prefs.calendarEnabled)
                choice("macwindow.on.rectangle", "Windows", "Every open window as a tile: click to switch, or snap it to half the screen. Asks for Screen Recording and Accessibility.", $prefs.windowsEnabled)
                choice("tray.full", "Shelf", "Files you drop on the island; downloads and screenshots land there too.", $prefs.shelfEnabled)
                choice("doc.on.clipboard", "Clipboard", "Recent copies, pinned ones first.", $prefs.clipboardEnabled)
                choice("note.text", "Notes", "A scratchpad that keeps whatever you type.", $prefs.notesEnabled)
                choice("gauge.with.dots.needle.bottom.50percent", "Stats", "Processor, memory, network and battery health.", $prefs.statsEnabled)
                choice("speaker.wave.2", "Replace the volume and brightness bezel", "The island becomes the only heads-up display. Asks for Accessibility access.", $prefs.hudReplacementEnabled)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.top, 28)

            Spacer(minLength: 20)

            VStack(spacing: 12) {
                Button(action: dismiss) {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(width: 300)

                Toggle("Open at login", isOn: $prefs.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
        }
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

    private func choice(_ symbol: String, _ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                    .frame(width: 32, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
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
