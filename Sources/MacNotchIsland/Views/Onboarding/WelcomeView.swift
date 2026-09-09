import Carbon.HIToolbox
import SwiftUI

/// First-launch welcome, laid out the way Apple's own apps introduce themselves:
/// app icon, "Welcome to …", a short column of symbol + title + description rows,
/// and one prominent Continue button. Flat ground, system type, no boxes.
struct WelcomeView: View {
    /// The tour's one size, and the size its window is built at — see `SettingsView.windowSize`
    /// for why the window is told rather than left to ask.
    static let windowSize = CGSize(width: 500, height: 600)

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
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
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
                    "Music, today's agenda, your open windows, the shelf, clipboard, notes and stats, with volume, brightness, Wi-Fi and Bluetooth under them. Step between them beside the notch or with a swipe.")
                row("tray.and.arrow.down", "Drop files on the shelf",
                    "Drag anything onto the island and it waits there until you drag it out again, or AirDrop it from the rail.")
                row("keyboard", "Press \(shortcut)",
                    "Opens the panel from anywhere. \(tabShortcut) steps through every section; Escape closes.")
            }
            .frame(maxWidth: 400, alignment: .leading)
            .padding(.top, 32)

            Spacer(minLength: 24)

            VStack(spacing: 12) {
                Button(action: { withAnimation(IslandMotion.navigate) { page = 1 } }) {
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

    /// The one line under each choice's name.
    ///
    /// Seven of them have to be on the screen at once, and they only are while each is a
    /// single line: three of these used to run to two, which pushed the seventh — the volume
    /// and brightness keys, the choice that changes the most — under the bottom of the list.
    /// The list scrolls, but a Mac with overlay scrollbars shows nothing there until somebody
    /// scrolls, so the seventh choice was, in practice, not offered at all.
    ///
    /// They live here rather than inline so a test can hold them to their one line. The
    /// fuller explanation of each is in Settings, which is where there is room for it.
    enum ChoiceLine {
        static let today = "Your day's events and reminders."
        static let windows = "Every open window as a tile you can snap."
        static let shelf = "Files you drop on the island wait here."
        static let clipboard = "Recent copies, pinned ones first."
        static let notes = "A scratchpad that keeps what you type."
        static let stats = "Processor, memory, network and battery."
        static let keys = "Answered in the island, not by macOS."
        static let all = [today, windows, shelf, clipboard, notes, stats, keys]
        /// About as much as fits on one line at the width the tour gives these.
        static let limit = 44
    }

    private var picker: some View {
        VStack(spacing: 0) {
            // Smaller than page one's app icon on purpose: this page has seven things to say
            // and that one has a name to introduce. The points come off the picture rather
            // than off the bottom of the list.
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 34, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(height: 56)
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

            // All seven fit without scrolling. It scrolls anyway, because a fixed height can
            // promise nothing at larger text sizes or if an eighth is ever added — and the
            // button that dismisses this window is not allowed to be the thing that falls off
            // the bottom of it. Which is what it was doing: "Done" and "Open at login" were
            // both under the edge, on the first window a new Mac shows.
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    choice("calendar", "Today", ChoiceLine.today, $prefs.calendarEnabled)
                    choice("macwindow.on.rectangle", "Windows", ChoiceLine.windows, $prefs.windowsEnabled)
                    choice("tray.full", "Shelf", ChoiceLine.shelf, $prefs.shelfEnabled)
                    choice("doc.on.clipboard", "Clipboard", ChoiceLine.clipboard, $prefs.clipboardEnabled)
                    choice("note.text", "Notes", ChoiceLine.notes, $prefs.notesEnabled)
                    choice("gauge.with.dots.needle.bottom.50percent", "Stats", ChoiceLine.stats, $prefs.statsEnabled)
                    choice("speaker.wave.2", "Volume and brightness", ChoiceLine.keys, $prefs.hudReplacementEnabled)
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.vertical, 2)
                // A lane of its own for the scroller, so it never sits on the switches.
                .padding(.trailing, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 18)

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
            .padding(.top, 20)
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
        // Sized before it is placed: the hosting controller has not laid this out yet, so a
        // window centred first is a window of the wrong size centred, and the right size then
        // grows out of the corner the wrong one was pinned by — off the edge of a small
        // screen. It is the first thing a new Mac shows of this app.
        w.setContentSize(WelcomeView.windowSize)
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
