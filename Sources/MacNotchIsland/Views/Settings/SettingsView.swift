import AppKit
import SwiftUI

/// Opening Settings, in one place.
///
/// SwiftUI's `Settings` scene installs its opener on the responder chain under a selector with
/// no public symbol, and the name has already changed once — `showPreferencesWindow:` before
/// macOS 14, `showSettingsWindow:` after. Four call sites each spelled it out by hand, none of
/// them looked at what `sendAction` returned, and so a name that stopped answering would have
/// taken every way into this window at once, silently. This asks under both names and says
/// which one answered.
enum SettingsWindow {
    private static let selectors = ["showSettingsWindow:", "showPreferencesWindow:"]

    @discardableResult
    static func open(_ section: SettingsSection? = nil) -> Bool {
        if let section {
            UserDefaults.standard.set(section.rawValue, forKey: "settingsSection")
        }
        NSApp.activate(ignoringOtherApps: true)
        for name in selectors {
            guard NSApp.sendAction(Selector((name)), to: nil, from: nil) else { continue }
            IslandLog.island.notice("settings window opened by \(name, privacy: .public) on \(section?.rawValue ?? "the last pane", privacy: .public)")
            reportWindows()
            return true
        }
        IslandLog.island.error("settings window refused: nothing in the responder chain opens it")
        reportWindows()
        return false
    }

    /// What windows the app has a moment after asking for one.
    ///
    /// The action being accepted is not the same as a window arriving — a responder can claim
    /// the selector and put nothing on screen — and the difference is invisible from the
    /// outside. This is the line that says which of the two happened, in the support report
    /// and in the smoke test, and it costs one log line per time anybody opens Settings.
    private static func reportWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + windowSettle) {
            let list = NSApp.windows
                .filter { !($0 is NotchPanel) }
                .map { "\(type(of: $0)) \(NSStringFromRect($0.frame)) visible=\($0.isVisible)" }
            IslandLog.island.notice("app windows: \(list.isEmpty ? "none" : list.joined(separator: " | "), privacy: .public)")
        }
    }

    /// Long enough for SwiftUI to have built and shown the window it was asked for.
    static let windowSettle: TimeInterval = 0.6
}

/// The panes in the Settings sidebar, in the order System Settings would list them.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case island
    case activities
    case home
    case media
    case shortcuts
    case privacy
    case about

    var id: String { rawValue }

    /// Pane names are titles, so they take title-style capitalization.
    var title: String {
        switch self {
        case .general: return "General"
        case .island: return "Island"
        case .activities: return "Activities"
        case .home: return "Home Panel"
        case .media: return "Media"
        case .shortcuts: return "Actions"
        case .privacy: return "Privacy & Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .island: return "capsule.fill"
        case .activities: return "bell.fill"
        case .home: return "square.grid.2x2.fill"
        case .media: return "play.fill"
        case .shortcuts: return "bolt.fill"
        case .privacy: return "hand.raised.fill"
        case .about: return "info"
        }
    }
}

/// Settings, laid out the way System Settings is: a sidebar of panes on the left, a grouped
/// form on the right, one window title per pane. The sidebar glyphs are neutral grey squares;
/// selection and controls take the user's own accent colour, as every Apple window does.
struct SettingsView: View {
    @AppStorage("settingsSection") private var storedSection = SettingsSection.general.rawValue
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: selection) {
                ForEach(SettingsSection.allCases) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        SettingsSidebarIcon(section.symbol)
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 208, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane
                .navigationTitle(current.title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 715, height: 470)
    }

    // MARK: Panes

    @ViewBuilder
    private var pane: some View {
        switch current {
        case .general: GeneralPane()
        case .island: IslandPane()
        case .activities: ActivitiesPane()
        case .home: HomePanelPane()
        case .media: MediaPane()
        case .shortcuts: ShortcutsPane()
        case .privacy: PrivacyPane()
        case .about: AboutPane()
        }
    }

    // MARK: Selection

    /// The chosen pane survives closing the window, and any pane can send the user to another
    /// one by writing the same defaults key.
    private var current: SettingsSection {
        SettingsSection(rawValue: storedSection) ?? .general
    }

    private var selection: Binding<SettingsSection?> {
        Binding(
            get: { current },
            set: { newValue in
                guard let newValue else { return }
                storedSection = newValue.rawValue
            }
        )
    }
}
