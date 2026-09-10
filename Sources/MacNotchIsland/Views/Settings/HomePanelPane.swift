import SwiftUI

/// "Home Panel": the sections the panel can show beside Now Playing, and the control rail
/// under them.
struct HomePanelPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var windows = WindowsMonitor.shared
    /// Watched so the count beside Erase is the count, rather than what it was when this
    /// window was opened.
    @ObservedObject private var inbox = NotificationInbox.shared
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

    private static func help(for section: HomeSection) -> String {
        switch section {
        case .home: return "Every section as a tile, with a glimpse of what is in it."
        case .music: return "What is playing, wherever it is playing."
        case .controls: return "The networks in range and the devices you are paired with, each with its own switch."
        case .today: return "Your next events and reminders. Asks for calendar and reminders access when first opened."
        case .windows: return "Every open window as a live tile: click one to bring it forward, or snap it to a half of the screen. Asks for Screen Recording to draw the pictures and Accessibility to move windows."
        case .shelf: return "Drag files onto the island to keep them within reach."
        case .clipboard: return "Recent copies, pinned ones first."
        case .actions: return "Run your favourite shortcuts from the panel."
        case .notes: return "A scratchpad that keeps whatever you type."
        case .stats: return "Processor, memory, network and battery health."
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
                            // eight rows need is arithmetic rather than a guess — a guess left
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
                Text("Drag a section to move it. Home and Now Playing have no switch — one is the way to everything else, the other is what the island is for — but both can be moved like the rest. Step between sections with the buttons beside the notch, a sideways swipe, or Tab; the digits 1 to 9 count them from the left in this order.")
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
                Toggle("Add downloads to the shelf", isOn: $prefs.addDownloadsToShelf)
                    .help("Finished downloads land on the shelf instead of only alerting.")
                Toggle("Add screenshots to the shelf", isOn: $prefs.screenshotsToShelfEnabled)
                    .help("New screenshots land on the shelf, ready to drag into another app.")
            } header: {
                Text("Shelf")
            } footer: {
                // Not "never from disk", which was not true: a picture, link or note the
                // island wrote for the shelf has nowhere else to live, and goes to the Trash
                // when it leaves. A promise on this screen has to hold for every case of it.
                Text("Select several items to drag or AirDrop them together. Clearing never touches a file you dragged in from Finder. A picture, link or note the island wrote itself goes to the Trash, where you can get it back.")
            }
            .disabled(!prefs.shelfEnabled)

            Section {
                Stepper(value: $prefs.clipboardLimit, in: 10...200, step: 10) {
                    Text("Items kept: \(Int(prefs.clipboardLimit))")
                }
                Toggle("Paste after picking an item", isOn: $prefs.pasteOnPick)
                    .help("Clicking an item closes the panel and pastes it where you were typing. Needs Accessibility; without it the item is only put on the pasteboard.")
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Kept on this Mac, in Notch Island's own folder, where only your account can read it. Anything a password manager marks as concealed, or another tool marks as its own, is never recorded at all.")
            }
            .disabled(!prefs.clipboardEnabled)

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
                Toggle("Camera mirror", isOn: $prefs.mirrorEnabled)
                    .help("A mirror button in the rail, to check yourself before a call. Asks for camera access when first opened.")
            } header: {
                Text("Control rail")
            } footer: {
                HStack(spacing: 8) {
                    Text("Volume, light and dark, Keep Awake and Settings are in the rail under every section; brightness, Wi-Fi and Bluetooth when this Mac has them, and AirDrop when there is something on the shelf and you are not looking at it. Choose the apps and shortcuts that appear in the Actions section there.")
                    Button("Open Actions") {
                        selectedSection = SettingsSection.shortcuts.rawValue
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
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
