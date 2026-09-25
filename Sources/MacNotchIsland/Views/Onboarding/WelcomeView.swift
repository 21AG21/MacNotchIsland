import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// First-launch welcome, laid out the way Apple's own apps introduce themselves:
/// app icon, "Welcome to …", a short column of symbol + title + description rows,
/// and one prominent Continue button. Flat ground, system type, no boxes.
struct WelcomeView: View {
    /// The tour's one size, and the size its window is built at — see `SettingsView.windowSize`
    /// for why the window is told rather than left to ask. Forty points taller than it was, for
    /// the eighth choice and the second line the subtitle needs to name what it leaves out.
    static let windowSize = CGSize(width: 500, height: 640)

    @EnvironmentObject private var prefs: Preferences
    /// Watched so the keyboard row names the shortcut only while pressing it will do something.
    @ObservedObject private var hotkey = HotKeyService.shared
    var dismiss: () -> Void
    /// The last switch's answer, held back until the window closes — see `Draft`.
    @ObservedObject var draft: Draft
    @State private var page = 0

    /// The tour's last switch, held back until the tour is done.
    ///
    /// The others write straight to Preferences, and may: nothing runs off them that asks macOS
    /// for anything before the tour is marked seen (`ServiceHub.wantsCalendar`,
    /// `wantsDownloads`, `wantsScreenshots`). This one starts the media-key interceptor, which asks for
    /// Accessibility with a modal sheet — and did so over the tour, within a moment of the
    /// switch being flipped, before Done had been pressed. The calendar keeps the right order
    /// by having `ServiceHub.wantsCalendar` hold it until `hasSeenWelcome`; the hub reads this
    /// preference directly, so the holding is done a step earlier, by not writing the
    /// preference until the window closes. Done and the close button both go through
    /// `windowWillClose`, so neither loses the choice.
    final class Draft: ObservableObject {
        @Published var answersKeys: Bool

        init(answersKeys: Bool) { self.answersKeys = answersKeys }

        /// Writes the choice through, which is the moment the interceptor starts and macOS
        /// asks. Main thread only: the window delegate's, and Preferences publishes on it.
        func commit() {
            guard Preferences.shared.hudReplacementEnabled != answersKeys else { return }
            Preferences.shared.hudReplacementEnabled = answersKeys
        }
    }

    /// The shortcut, while pressing it opens the panel: switched on, registered, and not one of
    /// macOS's own — see `HotKeyService.takenBySystem`. Nil otherwise, and the row says where
    /// to choose one instead of teaching a combination that does nothing.
    private var shortcut: String? {
        guard prefs.hotkeyEnabled, !hotkey.registrationFailed, !hotkey.takenBySystem else { return nil }
        return HotKeyService.displayString(keyCode: HotKeyService.currentKeyCode,
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
            Text(Self.headline(hasNotch: NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 18) {
                row("cursorarrow.motionlines", "Rest the pointer on it",
                    "The island shows what is playing, counting down or downloading. Hover to peek at the full view; click to keep it open.")
                row("rectangle.split.3x1", "One panel for everything",
                    "Music, today's agenda, your open windows, the shelf, clipboard, notes and stats, with volume, brightness, Wi-Fi and Bluetooth under them. Step between them beside the notch or with a swipe.")
                row("tray.and.arrow.down", "Drop files on the shelf",
                    Self.shelfDetail(expiryHours: prefs.shelfExpiryHours))
                let keys = Self.keyboardRow(shortcut: shortcut, tab: tabShortcut)
                row("keyboard", keys.title, keys.detail)
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

    // MARK: - What page one says, as rules

    /// The line under the app's name. "Your notch" on a Mac without one was the first thing
    /// the tour got wrong, a line under the word Welcome.
    static func headline(hasNotch: Bool) -> String {
        hasNotch ? "Your notch is now a Dynamic Island." : "The top of your screen now has a Dynamic Island."
    }

    /// What the shelf keeps, and for how long. It said a file waited "until you drag it out
    /// again", and out of the box the shelf lets go of it after a day.
    static func shelfDetail(expiryHours: Double) -> String {
        guard expiryHours > 0 else {
            return "Drag anything onto the island and it waits there until you drag it out again, or AirDrop it from the rail."
        }
        return "Drag anything onto the island and it waits there for \(span(hours: expiryHours)), to drag out again or AirDrop from the rail."
    }

    /// "an hour", "six hours", "a day", "three days", "a week": the shelf's choices, in words.
    static func span(hours: Double) -> String {
        let h = max(1, Int(hours.rounded()))
        let words = [2: "two", 3: "three", 4: "four", 5: "five", 6: "six"]
        func counted(_ n: Int, _ one: String, _ many: String) -> String {
            n == 1 ? one : "\(words[n] ?? String(n)) \(many)"
        }
        if h % 168 == 0 { return counted(h / 168, "a week", "weeks") }
        if h % 24 == 0 { return counted(h / 24, "a day", "days") }
        return counted(h, "an hour", "hours")
    }

    /// The keyboard row. It named ⌃⌥Space on every Mac, including the ones where macOS takes
    /// ⌃⌥Space first for the input menu — the tour's one instruction, and it did nothing. It
    /// names the shortcut only when there is one that works, and otherwise where to set one.
    static func keyboardRow(shortcut: String?, tab: String) -> (title: String, detail: String) {
        guard let shortcut else {
            return ("Choose a shortcut",
                    "Pick a key combination in Settings, under Island, and it opens the panel from anywhere. Escape closes.")
        }
        return ("Press \(shortcut)", "Opens the panel from anywhere. \(tab) steps through every section; Escape closes.")
    }

    // MARK: - Page two: what it shows

    /// The one line under each choice's name.
    ///
    /// Eight of them have to be on the screen at once, and they only are while each is a
    /// single line: three of these used to run to two, which pushed the last — the volume
    /// and brightness keys, the choice that changes the most — under the bottom of the list.
    /// The list scrolls, but a Mac with overlay scrollbars shows nothing there until somebody
    /// scrolls, so the seventh choice was, in practice, not offered at all.
    ///
    /// They live here rather than inline so a test can hold them to their one line. The
    /// fuller explanation of each is in Settings, which is where there is room for it.
    enum ChoiceLine {
        // The three that ask macOS for something the moment the tour is finished — this one
        // for the calendar, the folders for Downloads and the Desktop, the last one for
        // Accessibility — so the tour is where they say so.
        static let today = "Your events and reminders. Asks for access."
        // What is on this desktop, not every window there is: the list is the window
        // server's on-screen one.
        static let windows = "This desktop's windows, as tiles to snap."
        static let shelf = "Files you drop on the island wait here."
        // Two questions, one for each folder, and they used to arrive unannounced beside the
        // calendar's the moment Done was pressed. Both watchers ship on, under one switch here.
        static let folders = "New files. Asks for access to those folders."
        static let clipboard = "Recent copies, pinned ones first."
        static let notes = "A scratchpad that keeps what you type."
        // "CPU", as the section itself labels it: with the disk, "Processor" ran past the line.
        static let stats = "CPU, memory, disk, network and battery."
        static let keys = "Answered in the island. Asks for access."
        static let all = [today, windows, shelf, folders, clipboard, notes, stats, keys]
        /// About as much as fits on one line at the width the tour gives these.
        static let limit = 44
    }

    /// The sections page two has a switch for. With Home and Now Playing, which have none,
    /// every section that is not here is named in the subtitle — see `subtitle(on:off:)`.
    static let offered: [HomeSection] = [.today, .windows, .shelf, .clipboard, .notes, .stats]

    /// The sections the page has no switch for, Home and Now Playing aside.
    static var notOffered: [HomeSection] {
        HomeSection.allCases.filter { $0 != .home && $0 != .music && !offered.contains($0) }
    }

    /// The line under the page's title. It said "Everything else is up to you" above a list
    /// that left out Controls and Actions — both on — and Notifications, which is off: three
    /// sections nobody was offered. `on` and `off` are their titles, as they are now.
    static func subtitle(on: [String], off: [String]) -> String {
        var text = "Now Playing is always there"
        if !on.isEmpty { text += ", and so \(on.count == 1 ? "is" : "are") \(spoken(on))" }
        text += ". Change any of it later in Settings"
        if !off.isEmpty { text += ", where \(spoken(off)) \(off.count == 1 ? "is" : "are") too" }
        return text + "."
    }

    /// "A", "A and B", "A, B and C".
    static func spoken(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// Downloads and screenshots, as the one choice the tour offers for both watchers.
    private var folders: Binding<Bool> {
        Binding(
            get: { prefs.downloadsEnabled || prefs.screenshotsEnabled },
            set: { on in
                prefs.downloadsEnabled = on
                prefs.screenshotsEnabled = on
            }
        )
    }

    private var picker: some View {
        let elsewhere = Self.notOffered
        return VStack(spacing: 0) {
            // Smaller than page one's app icon on purpose: this page has eight things to say
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
            Text(Self.subtitle(on: elsewhere.filter { $0.isEnabled(prefs) }.map(\.title),
                               off: elsewhere.filter { !$0.isEnabled(prefs) }.map(\.title)))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            // All eight fit without scrolling. It scrolls anyway, because a fixed height can
            // promise nothing at larger text sizes or if a ninth is ever added — and the
            // button that dismisses this window is not allowed to be the thing that falls off
            // the bottom of it. Which is what it was doing: "Done" and "Open at login" were
            // both under the edge, on the first window a new Mac shows.
            ScrollView {
                // Nine points apart rather than eleven: the eighth row costs the rest a little air.
                VStack(alignment: .leading, spacing: 9) {
                    choice("calendar", "Today", ChoiceLine.today, $prefs.calendarEnabled)
                    choice("macwindow.on.rectangle", "Windows", ChoiceLine.windows, $prefs.windowsEnabled)
                    choice("tray.full", "Shelf", ChoiceLine.shelf, $prefs.shelfEnabled)
                    choice("arrow.down.circle", "Downloads and screenshots", ChoiceLine.folders, folders)
                    choice("doc.on.clipboard", "Clipboard", ChoiceLine.clipboard, $prefs.clipboardEnabled)
                    choice("note.text", "Notes", ChoiceLine.notes, $prefs.notesEnabled)
                    choice("gauge.with.dots.needle.bottom.50percent", "Stats", ChoiceLine.stats, $prefs.statsEnabled)
                    choice("speaker.wave.2", "Volume and brightness", ChoiceLine.keys, $draft.answersKeys)
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.vertical, 2)
                // A lane of its own for the scroller, so it never sits on the switches — and
                // the same lane on the other side, so the list stays centred in the window
                // whether or not there is anything to scroll.
                .padding(.horizontal, 10)
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
                // What the tick cannot say on its own: waiting for approval, or refused.
                if let note = prefs.loginItemNote {
                    HStack(spacing: 6) {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if LoginItemRule.offersLoginItems(note) {
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                        }
                    }
                    .frame(maxWidth: 420)
                }
            }
            .padding(.top, 20)
        }
        .onAppear { prefs.settleLoginItem() }
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
    /// The last switch's answer, kept beside the window so that closing it — by Done or by
    /// the close button — is what writes the answer through.
    private var draft: WelcomeView.Draft?

    func showIfFirstLaunch() {
        guard !Preferences.shared.hasSeenWelcome else {
            IslandLog.island.debug("welcome: this Mac has seen the tour")
            return
        }
        show()
    }

    func show() {
        if let window {
            // A tour that is up stays on the page it is on. One that was closed starts again
            // from the first page: the window was kept, and with it the view's `page`, so the
            // tour reopened from the menu bar on its second page, with no welcome and no way
            // back to it. A fresh view is a fresh page and a fresh draft — the switch read
            // afresh, since Settings may have changed it since the tour was last up.
            if !window.isVisible {
                window.contentViewController = makeContent()
                window.setContentSize(WelcomeView.windowSize)
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: makeContent())
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
        // The same line Settings writes, for the same reason: a window that does not turn up
        // leaves nothing behind to look at otherwise, and the smoke test found exactly that.
        IslandLog.island.notice("welcome window opened \(NSStringFromRect(w.frame), privacy: .public)")
        SettingsWindow.reportWindows()
    }

    /// The tour's view and the draft behind its last switch, both new.
    private func makeContent() -> NSViewController {
        let answers = WelcomeView.Draft(answersKeys: Preferences.shared.hudReplacementEnabled)
        draft = answers
        let view = WelcomeView(dismiss: { [weak self] in self?.close() }, draft: answers)
            .environmentObject(Preferences.shared)
        return NSHostingController(rootView: view)
    }

    private func close() {
        Preferences.shared.hasSeenWelcome = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Preferences.shared.hasSeenWelcome = true
        // After the tour is marked seen, and in the same turn of the run loop: the hub
        // re-applies once for both, with the window already on its way out from under the
        // sheet that this may raise.
        draft?.commit()
    }
}
