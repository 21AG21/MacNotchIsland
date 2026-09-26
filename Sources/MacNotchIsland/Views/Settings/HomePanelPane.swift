import SwiftUI

/// "Home Panel": the sections the panel can show beside Now Playing, and the control rail
/// under them.
struct HomePanelPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var windows = WindowsMonitor.shared
    /// Watched so the count beside Erase is the count, rather than what it was when this
    /// window was opened.
    @ObservedObject private var inbox = NotificationInbox.shared
    /// Watched so the rail list can say which controls this Mac has nothing for.
    @ObservedObject private var toggles = SystemToggles.shared
    @ObservedObject private var keyboard = KeyboardLight.shared
    @AppStorage("settingsSection") private var selectedSection = SettingsSection.general.rawValue
    /// Held rather than built inside `onReceive`, where it would be a new publisher on every
    /// pass of the body — and this body runs whenever a preference on it changes.
    private let permissionTicker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// The choices offered for shelf expiry, in hours.
    private static let expiryOptions: [Double] = [0, 1, 6, 24, 72, 168]

    /// A row of the arrangement list, the air above and below it, and the room every section
    /// needs together. The list keeps its own scroller as a safety net: better a list that
    /// scrolls by a couple of points than one whose last row cannot be reached.
    private static let rowHeight: CGFloat = 26
    private static let rowPadding: CGFloat = 4
    private static var listHeight: CGFloat {
        (rowHeight + rowPadding * 2) * CGFloat(HomeSection.allCases.count) + 4
    }

    /// One section: its glyph, its name, and its switch. Now Playing cannot be switched off,
    /// so it says so in the place the switch would be rather than showing a dead one.
    @ViewBuilder
    private func sectionRow(_ section: HomeSection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: section.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            if section == .home || section == .music {
                Text(section.title)
                Spacer(minLength: 8)
                Text("Always on")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Toggle(section.title, isOn: Binding(
                    get: { section.isEnabled(prefs) },
                    set: { section.setEnabled($0, in: prefs) }
                ))
                .help(Self.help(for: section))
            }
        }
        .frame(height: Self.rowHeight)
    }

    /// Moving a row writes the whole order, so the stored list is always complete and the
    /// next version's new section still lands at the end of it rather than in the middle.
    private func move(from source: IndexSet, to destination: Int) {
        var order = HomeSection.ordered(prefs)
        order.move(fromOffsets: source, toOffset: destination)
        prefs.sectionOrder = order.map(\.rawValue)
    }

    // MARK: - The control rail's list

    /// Every rail control but Settings, which has no switch and is always last — a row that
    /// could be dragged anywhere and then snapped back to the end would be a row that lies.
    private var railControls: [RailControl] {
        RailControl.ordered(prefs).filter { $0 != .settings }
    }

    private static var railListHeight: CGFloat {
        (rowHeight + rowPadding * 2) * CGFloat(RailControl.allCases.count - 1) + 4
    }

    /// One rail control: its glyph, its name and its switch, and a word when this Mac has
    /// nothing for it to do — the switch still keeps the choice for a Mac that does.
    @ViewBuilder
    private func railRow(_ control: RailControl) -> some View {
        HStack(spacing: 8) {
            Image(systemName: control.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Toggle(control.label, isOn: Binding(
                get: { control.isEnabled(prefs) },
                set: { control.setEnabled($0, in: prefs) }
            ))
            .help(Self.railHelp(for: control))
            if let note = railNote(for: control) {
                Spacer(minLength: 8)
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: Self.rowHeight)
    }

    /// The same rule as the sections': the whole order is written, so a control a later version
    /// adds still lands at the end rather than in the middle.
    private func moveRail(from source: IndexSet, to destination: Int) {
        var order = railControls
        order.move(fromOffsets: source, toOffset: destination)
        prefs.railOrder = order.map(\.rawValue)
    }

    /// Whether the rail is anything but the way it ships.
    private var railIsCustomised: Bool {
        RailControl.order(stored: prefs.railOrder) != RailControl.defaultOrder
            || !prefs.railSwitches.isEmpty || !prefs.mirrorEnabled
    }

    private func railNote(for control: RailControl) -> String? {
        switch control {
        case .wifi: return toggles.hasWiFi ? nil : "Not on this Mac"
        case .bluetooth: return toggles.hasBluetooth ? nil : "Not on this Mac"
        case .keyboardLight: return keyboard.isAvailable ? nil : "No backlight here"
        default: return nil
        }
    }

    private static func railHelp(for control: RailControl) -> String {
        switch control {
        case .wifi: return "Wi-Fi on and off."
        case .bluetooth: return "Bluetooth on and off."
        case .display: return "A popover with a brightness slider for every display that takes one, and Dark Mode, Night Shift and True Tone. Right-click Night Shift for its warmth."
        case .keepAwake: return "Keeps the Mac and its display awake until you switch it off again."
        case .mirror: return "A mirror button in the rail, to check yourself before a call. Asks for camera access when first opened."
        case .airDrop: return "Sends everything on the shelf by AirDrop. Shown only while there is something on the shelf and the Shelf section is not the one open."
        case .focus: return "Lit while a Focus is on. Opens a list of this Mac's Focus modes, which shows the one that is on and sets another. Right-click the disc for Focus in System Settings."
        case .microphone: return "Mutes and unmutes the microphone, lit while it is muted."
        case .lock: return "Locks the screen."
        case .sleepDisplay: return "Puts the display to sleep. The Mac itself stays awake."
        case .screenshot: return "Opens the screenshot toolbar."
        case .record: return "Starts and stops a recording of the screen, red while it runs."
        case .keyboardLight: return "Opens the keyboard's backlight: a slider and a switch to have it follow the room's light, where the keyboard has one. Right-click the disc for the switch alone."
        case .settings: return "Always on, and always last."
        }
    }

    private static func help(for section: HomeSection) -> String {
        switch section {
        case .home: return "Every section as a tile, with a glimpse of what is in it."
        case .music: return "What is playing, wherever it is playing."
        case .controls: return "The networks in range, the devices you are paired with, and where the sound goes and comes from, each list with its own switch — and above them, any control the rail had no room for."
        case .today: return "Your next events and reminders, and the card that appears on the island before a meeting with its Join button — switching this off turns that card off too. Asks for calendar and reminders access when first opened."
        case .windows: return "The windows on this desktop as live tiles, minimised ones and a hidden app's dimmed after the rest: click one to bring it forward, or snap it to a half of the screen. Asks for Screen Recording to draw the pictures and Accessibility to move windows and to find the ones put away."
        case .shelf: return "Drag files onto the island to keep them within reach."
        case .clipboard: return "Recent copies, pinned ones first."
        case .actions: return "Your favourite apps and shortcuts, timers you tap or type, alarms and the stopwatch."
        case .notes: return "A scratchpad that keeps whatever you type."
        case .stats: return "Processor, memory, disk, network and battery health."
        case .notifications: return "What came past on a banner, kept for three days. Records the app, what the banner said and when, in Notch Island's own folder on this Mac. Needs Accessibility to read the banners."
        }
    }

    var body: some View {
        Form {
            Section {
                // One list, in the order the panel shows them, with each section's switch on
                // its own row — the way Control Center is arranged. Dragging a row moves the
                // section everywhere at once: the switcher, a sideways swipe, Tab, and the
                // digit that reaches it.
                List {
                    ForEach(HomeSection.ordered(prefs), id: \.self) { section in
                        sectionRow(section)
                            // The insets are stated rather than left to the list, so the room
                            // the rows need is arithmetic rather than a guess — a guess left
                            // the last two off the bottom, where nothing could reach them.
                            .listRowInsets(EdgeInsets(top: Self.rowPadding, leading: 10,
                                                      bottom: Self.rowPadding, trailing: 10))
                    }
                    .onMove(perform: move)
                }
                .listStyle(.plain)
                .alternatingRowBackgrounds(.disabled)
                .frame(height: Self.listHeight)
                Toggle("Weather in Today", isOn: $prefs.weatherEnabled)
                    .help("The conditions outside, in the Today header. Asks for your location when first opened. Data from Open-Meteo.")
                    .disabled(!prefs.calendarEnabled)
                if prefs.sectionOrder != HomeSection.allCases.map(\.rawValue), !prefs.sectionOrder.isEmpty {
                    Button("Put the Sections Back in Order") { prefs.sectionOrder = [] }
                }
            } header: {
                Text("Sections")
            } footer: {
                // Not "the digits count them from the left": they follow the ring Tab walks,
                // which puts anything live first, and the band draws the sections it has no room
                // for to the left of the cutout, out of this order.
                Text("Drag a section to move it. Home and Now Playing have no switch — one is the way to everything else, the other is what the island is for — but both can be moved like the rest. Step between sections with the buttons beside the notch, a sideways swipe, or Tab. The swipe and Tab go in this order, and so do the digits 1 to 9, after anything live: a running timer takes 1 and moves every section along by one, and a section past the ninth has no digit.")
            }

            Section {
                Picker("Clear items after", selection: expiry) {
                    Text("Never").tag(0.0)
                    Text("1 hour").tag(1.0)
                    Text("6 hours").tag(6.0)
                    Text("1 day").tag(24.0)
                    Text("3 days").tag(72.0)
                    Text("1 week").tag(168.0)
                }
                .pickerStyle(.menu)
                // Each is read by the watcher that sees the file arrive, and that watcher is
                // switched in Activities, a pane away: with it off, these were live switches
                // for nothing. Greyed out then, and the footer names the switch.
                Toggle("Add downloads to the shelf", isOn: $prefs.addDownloadsToShelf)
                    .help("Finished downloads land on the shelf as well as being announced.")
                    .disabled(!prefs.downloadsEnabled)
                Toggle("Add screenshots to the shelf", isOn: $prefs.screenshotsToShelfEnabled)
                    .help("New screenshots land on the shelf, ready to drag into another app.")
                    .disabled(!prefs.screenshotsEnabled)
            } header: {
                Text("Shelf")
            } footer: {
                // Not "never from disk", which was not true: a picture, link or note the
                // island wrote for the shelf has nowhere else to live, and goes to the Trash
                // when it leaves. A promise on this screen has to hold for every case of it.
                let note = Self.shelfNote(downloads: prefs.downloadsEnabled, screenshots: prefs.screenshotsEnabled)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select several items to drag or AirDrop them together. Clearing never touches a file you dragged in from Finder. A picture, link or note the island wrote itself goes to the Trash, where you can get it back.")
                    if let note {
                        HStack(spacing: 8) {
                            Text(note)
                            Button("Open Activities") {
                                selectedSection = SettingsSection.activities.rawValue
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .disabled(!prefs.shelfEnabled)

            Section {
                Stepper(value: $prefs.clipboardLimit, in: 10...200, step: 10) {
                    Text("Items kept: \(Int(prefs.clipboardLimit))")
                }
                .disabled(!prefs.clipboardEnabled)
                Toggle("Paste after picking an item", isOn: $prefs.pasteOnPick)
                    .help("Clicking an item closes the panel and pastes it where you were typing. Needs Accessibility; without it the item is only put on the pasteboard.")
                    .disabled(!prefs.clipboardEnabled)
                // Not greyed out with the section's switch, for the notifications' reason:
                // turning this off is how what was written down is erased, and a history that
                // has been switched off is exactly the moment somebody wants that.
                Toggle("Keep history across relaunches", isOn: $prefs.clipboardPersists)
                    .help("Writes the history to disk so it is still there after Notch Island quits — its words, links and files, never a picture. Off, it is held in memory only, and turning this off erases what was written.")
            } header: {
                Text("Clipboard")
            } footer: {
                // Pictures are never written, which is right, and was never said: a pinned
                // picture vanished at the next launch with "Keep history" on.
                Text("Held in memory, and gone when Notch Island quits, unless you keep it across relaunches — then it is written to Notch Island's own folder on this Mac, where only your account can read it, and turning that off erases it. A copied picture is never written to disk, so it goes when the app quits, pinned or not. Anything a password manager marks as concealed, or another tool marks as its own, is never recorded at all.")
            }

            // Deliberately not disabled with the switch for this section. Turning the history
            // off is the most likely moment somebody wants what it already wrote gone, and a
            // pane that greys out the only way to erase it is a pane that traps it here.
            Section {
                LabeledContent("Reading banners") {
                    HStack(spacing: 8) {
                        Text(MediaKeyInterceptor.isTrusted ? "Allowed" : "Not allowed")
                            .foregroundStyle(.secondary)
                        Button("Accessibility…") { SystemSettingsPane.accessibility.open() }
                    }
                }
                LabeledContent("Kept") {
                    HStack(spacing: 8) {
                        Text(keptCount)
                            .foregroundStyle(.secondary)
                        Button("Erase") { NotificationInbox.shared.clear() }
                            .disabled(inbox.entries.isEmpty)
                            .help("Forget every notification kept so far. What was written to disk goes with them.")
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                // The cap and the expiry are read from the rules rather than written out here,
                // so this cannot quietly become a promise the app has stopped keeping.
                Text("Kept on this Mac, in Notch Island's own folder, where only your account can read it: the app that sent each banner, the words it showed, and the time. Nothing about a notification is ever sent anywhere. The last \(NotificationInbox.maxEntries) are kept, anything older than \(Int(NotificationInbox.maxAge / 86_400)) days goes on its own, and Erase takes the lot now.")
            }

            Section {
                LabeledContent("Pictures of windows") {
                    HStack(spacing: 8) {
                        Text(windows.canCapture ? "Allowed" : "Not allowed")
                            .foregroundStyle(.secondary)
                        Button("Screen Recording…") { SystemSettingsPane.screenRecording.open() }
                    }
                }
                LabeledContent("Moving windows") {
                    HStack(spacing: 8) {
                        Text(windows.canMove ? "Allowed" : "Not allowed")
                            .foregroundStyle(.secondary)
                        Button("Accessibility…") { SystemSettingsPane.accessibility.open() }
                    }
                }
            } header: {
                Text("Windows")
            } footer: {
                Text("Without Screen Recording the windows are still listed, by app, with no picture and no title.")
            }
            .disabled(!prefs.windowsEnabled)
            // Permissions are granted in System Settings, which tells nobody; the rows are
            // re-read while this pane is open so a grant shows up without a relaunch.
            .onReceive(permissionTicker) { _ in windows.refreshPermissions() }

            Section {
                // The same arrangement as the sections above: one list in the rail's order, a
                // switch on every row, drag to move. The camera mirror's switch is its row here
                // rather than a second switch beside it.
                List {
                    ForEach(railControls, id: \.self) { control in
                        railRow(control)
                            .listRowInsets(EdgeInsets(top: Self.rowPadding, leading: 10,
                                                      bottom: Self.rowPadding, trailing: 10))
                    }
                    .onMove(perform: moveRail)
                }
                .listStyle(.plain)
                .alternatingRowBackgrounds(.disabled)
                .frame(height: Self.railListHeight)
                if railIsCustomised {
                    Button("Put the Rail Back as It Ships") {
                        prefs.railOrder = []
                        prefs.railSwitches = [:]
                        prefs.mirrorEnabled = true
                    }
                }
            } header: {
                Text("Control rail")
            } footer: {
                HStack(spacing: 8) {
                    Text("Drag a control to move it. The volume and the brightness always lead the rail and Settings always ends it; Wi-Fi, Bluetooth and the keyboard's backlight appear where this Mac has them, and AirDrop when there is something on the shelf and you are not looking at it. Whatever does not fit the rail waits at the top of the Controls section, which comes back while anything is waiting there, even with its switch off. The apps and shortcuts in the Actions section are chosen in the Actions pane.")
                    Button("Open Actions") {
                        selectedSection = SettingsSection.shortcuts.rawValue
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { SettingsFormat.snap(&prefs.shelfExpiryHours, to: Self.expiryOptions) }
    }

    /// What the Shelf section's footer adds when one of its two switches can do nothing: each
    /// is read by the watcher that sees the file arrive, and a watcher runs only with its own
    /// switch in Activities on. Nil when both can. Pure, so a test holds the note to the
    /// switches it names.
    static func shelfNote(downloads: Bool, screenshots: Bool) -> String? {
        switch (downloads, screenshots) {
        case (true, true): return nil
        case (false, true): return "Downloads is off in Activities, so nothing downloaded is added."
        case (true, false): return "Screenshots is off in Activities, so no capture is added."
        case (false, false): return "Downloads and Screenshots are off in Activities, so neither is added."
        }
    }

    /// How many notifications are being kept at this moment, for the row the Erase button is
    /// on. "Nothing" rather than a nought: a nought reads as a tally that has gone wrong.
    private var keptCount: String {
        inbox.entries.isEmpty ? "Nothing" : String(inbox.entries.count)
    }

    /// Menus store discrete choices; a value set by an older build is shown as its nearest match.
    private var expiry: Binding<Double> {
        Binding(
            get: { SettingsFormat.nearest(prefs.shelfExpiryHours, in: Self.expiryOptions) },
            set: { prefs.shelfExpiryHours = $0 }
        )
    }
}
