import SwiftUI

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
        case .shortcuts: return "Shortcuts"
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
/// form on the right, one window title per pane. The palette stays monochrome — the sidebar
/// glyphs are neutral grey squares and every control inherits a greyscale tint.
struct SettingsView: View {
    @AppStorage("settingsSection") private var storedSection = SettingsSection.general.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: current)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 715, height: 470)
        .tint(.primary)
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
