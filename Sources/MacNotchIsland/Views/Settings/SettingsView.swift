import AppKit
import SwiftUI

/// The Settings window: built and owned here, not left to SwiftUI's `Settings` scene.
///
/// That scene is how a SwiftUI app is supposed to get one, and every way in used to ask for it
/// through `showSettingsWindow:` — the undocumented selector it installs on the responder
/// chain. On this app it does not work, and it does not fail either: `sendAction` returns
/// true, and no window is ever made. Notch Island has no Dock icon (`setActivationPolicy` is
/// `.accessory`), which is where a SwiftUI app's Settings scene stops appearing, and every
/// switch in this window was unreachable behind an action that reported success three times
/// running while the app's only window was its status bar item.
///
/// So the window is made the same way the welcome tour's has always been made: an
/// `NSHostingController` in an `NSWindow` this owns and shows itself. Nothing undocumented is
/// left in the path, and `reportWindows` writes down what actually came up.
enum SettingsWindow {
    @discardableResult
    static func open(_ section: SettingsSection? = nil) -> Bool {
        SettingsWindowHost.shared.show(section)
        IslandLog.island.notice("settings window opened on \(section?.rawValue ?? "the last pane", privacy: .public)")
        reportWindows()
        return true
    }

    /// What windows the app has a moment after asking for one.
    ///
    /// An action being accepted is not the same as a window arriving, and from outside the app
    /// the two look identical — which is exactly how this stayed broken. One line per time
    /// anybody opens Settings, in the support report and in the smoke test.
    private static func reportWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + windowSettle) {
            let list = NSApp.windows
                .filter { !($0 is NotchPanel) }
                .map { "\(type(of: $0)) \(NSStringFromRect($0.frame)) visible=\($0.isVisible)" }
            IslandLog.island.notice("app windows: \(list.count, privacy: .public) — \(list.isEmpty ? "none" : list.joined(separator: " | "), privacy: .public)")
        }
    }

    /// Long enough for the window to have been built and shown.
    static let windowSettle: TimeInterval = 0.6
}

/// Holds the one Settings window, so opening it twice does not make two.
private final class SettingsWindowHost {
    static let shared = SettingsWindowHost()
    private var window: NSWindow?

    func show(_ section: SettingsSection?) {
        if let section {
            UserDefaults.standard.set(section.rawValue, forKey: "settingsSection")
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SettingsView()
            .environmentObject(ActivityCenter.shared)
            .environmentObject(Preferences.shared))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable]
        // Named for the pane it is about to show, the way System Settings names its window.
        // `navigationTitle` will say the same thing a moment later; without this the window
        // opens under a different name and changes it in front of you.
        w.title = (section ?? SettingsSection(rawValue: UserDefaults.standard.string(forKey: "settingsSection") ?? "") ?? .general).title
        // Closing it puts it away rather than tearing it down, so what you were reading is
        // still there the next time, and nothing has to be rebuilt to show it.
        w.isReleasedWhenClosed = false
        // Sized before it is placed. A hosting controller has not laid its SwiftUI out when
        // the window is built, so a window centred first is a window of the wrong size
        // centred, and the right size then grows out of whichever corner the wrong one was
        // pinned by: 715 points of Settings starting 511 points across a 1024-point screen,
        // with a fifth of it over the edge.
        w.setContentSize(SettingsView.windowSize)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
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
        case .privacy: return "Privacy"
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
    /// One screenful of Settings, and the size the window is built at — the window cannot ask
    /// the hosting controller, which has not laid this out yet when it is made.
    static let windowSize = CGSize(width: 715, height: 470)

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
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
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
