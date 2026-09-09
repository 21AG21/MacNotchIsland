import SwiftUI

/// Routes an activity to its expanded (large) view.
struct ExpandedContentView: View {
    let activity: IslandActivity
    let layout: IslandLayout
    let geometry: NotchGeometry

    var body: some View {
        Group {
            switch activity.content {
            case .nowPlaying:
                MusicSectionView(geometry: geometry)
                    .islandContentColumn()
                    .padding(.top, insidePanel ? 0 : geometry.notchHeight + 12)
            case .timer(let t):
                TimerExpandedView(state: t, geometry: geometry)
            case .stopwatch(let s):
                StopwatchExpandedView(state: s, geometry: geometry)
            case .call(let c):
                CallExpandedView(state: c, activity: activity, geometry: geometry)
            case .battery(let b):
                BatteryExpandedView(state: b, geometry: geometry)
            case .bluetooth(let d):
                BluetoothExpandedView(state: d, geometry: geometry)
            case .focus(let f):
                FocusExpandedView(state: f, geometry: geometry)
            case .hud(let h):
                HUDExpandedView(state: h, geometry: geometry)
            case .calendar(let c):
                CalendarExpandedView(state: c, geometry: geometry)
            case .download(let d):
                DownloadExpandedView(state: d, activity: activity, geometry: geometry)
            case .custom(let c):
                CustomExpandedView(state: c, activity: activity, geometry: geometry)
            case .shelf:
                ShelfSectionView(isDropTarget: false)
                    .islandContentColumn()
                    .padding(.top, insidePanel ? 0 : geometry.notchHeight + 12)
            case .unlock, .silent:
                EmptyView()
            }
        }
        .frame(width: insidePanel ? IslandLayout.panelContentWidth : layout.bodyWidth,
               height: insidePanel ? IslandLayout.sectionHeight : layout.bodyHeight,
               alignment: insidePanel ? .center : .top)
    }

    @Environment(\.insidePanel) private var insidePanel
}

/// Shared header spacing: content starts below the physical notch. Inside the panel the band
/// above already cleared the notch, so this collapses to nothing.
struct NotchClearance: View {
    let geometry: NotchGeometry
    var extra: CGFloat = 8
    @Environment(\.insidePanel) private var insidePanel
    var body: some View {
        Color.clear
            .frame(height: insidePanel ? 0 : IslandLayout.cardTopBand(geometry) + extra)
            .accessibilityHidden(true)
    }
}

private struct InsidePanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for content drawn in the panel's section area rather than in a system card.
    var insidePanel: Bool {
        get { self[InsidePanelKey.self] }
        set { self[InsidePanelKey.self] = newValue }
    }
}

/// Shared edge insets for the expanded panels, so every card's content lines up with the
/// Home panel's rather than each view picking its own number.
enum IslandInsets {
    /// Leading / trailing inset of a *system card*'s content. The card is a free-standing
    /// 440 pt shape with no column of its own, so it draws one here.
    static let horizontal: CGFloat = 20
}

/// Puts content in the island's content column.
///
/// Outside the panel that is the card's own inset. Inside the panel it is nothing: the panel
/// already lays out one 24 pt column that the switcher, every section header, every section's
/// content and the control rail stand on. Adding a second inset here put a card's content —
/// the battery bar, a download's progress, the timer's buttons — 20 pt inside the rail
/// directly beneath it, so stepping from a section to an activity shifted the whole panel.
private struct ContentColumn: ViewModifier {
    @Environment(\.insidePanel) private var insidePanel

    func body(content: Content) -> some View {
        content.padding(.horizontal, insidePanel ? 0 : IslandInsets.horizontal)
    }
}

extension View {
    /// Lines this content up with the panel's column, or insets it inside a system card.
    func islandContentColumn() -> some View { modifier(ContentColumn()) }
}
