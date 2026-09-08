import SwiftUI

/// The tabs across the top of the Home panel.
private enum HomeTab: String, CaseIterable {
    case music, shelf, clipboard, actions, mirror, stats, weather

    var title: String {
        switch self {
        case .music: return "Music"
        case .shelf: return "Shelf"
        case .clipboard: return "Clipboard"
        case .actions: return "Actions"
        case .mirror: return "Mirror"
        case .stats: return "Stats"
        case .weather: return "Weather"
        }
    }
}

/// Shown when the island is idle and hovered: Now Playing mini-player and timer presets,
/// with the file shelf and the clipboard history a tab away. The Mac's equivalent of
/// long-pressing an empty island.
struct HomeExpandedView: View {
    let geometry: NotchGeometry
    let layout: IslandLayout
    @ObservedObject private var music = NowPlayingService.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var center: ActivityCenter
    @AppStorage("homeTab") private var storedTab: String = HomeTab.music.rawValue
    @Namespace private var tabNamespace

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 4)
            if availableTabs.count > 1 { tabBar }
            content
                .id(selection)
                .transition(IslandMotion.contentTransition(direction: center.navigationDirection))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, IslandInsets.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
    }

    // MARK: - Tabs

    private var availableTabs: [HomeTab] {
        HomeTab.allCases.filter { tab in
            switch tab {
            case .music: return true
            case .shelf: return prefs.shelfEnabled
            case .clipboard: return prefs.clipboardEnabled
            case .actions: return prefs.quickActionsEnabled
            case .mirror: return prefs.mirrorEnabled
            case .stats: return prefs.statsEnabled
            case .weather: return prefs.weatherEnabled
            }
        }
    }

    /// The stored tab, falling back to Music when its feature has been switched off.
    private var selection: HomeTab {
        let stored = HomeTab(rawValue: storedTab) ?? .music
        return availableTabs.contains(stored) ? stored : .music
    }

    private func select(_ tab: HomeTab) {
        guard tab != selection else { return }
        // Slide the way the tab bar reads: rightward tabs push in from the right.
        let tabs = availableTabs
        let from = tabs.firstIndex(of: selection) ?? 0
        let to = tabs.firstIndex(of: tab) ?? 0
        center.setNavigationDirection(to > from ? 1 : -1)
        withAnimation(IslandMotion.navigate) { storedTab = tab.rawValue }
    }

    private var tabBar: some View {
        HStack(spacing: 16) {
            if selection == .clipboard && !clipboard.items.isEmpty {
                Button(action: { clipboard.clear() }) {
                    Text("Clear")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.bottom, 4)
                        // The bar is a fixed 20 pt; a 24 pt hit area overhangs it by 2 pt top
                        // and bottom without changing its layout height.
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IslandButtonStyle())
            }
            Spacer(minLength: 0)
            ForEach(availableTabs, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, IslandInsets.horizontal)
        .frame(height: 20)
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        let active = selection == tab
        return Button(action: { select(tab) }) {
            Text(tab.title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.4))
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) {
                    if active {
                        Capsule()
                            .fill(Color.white.opacity(0.8))
                            .frame(height: 1.5)
                            .matchedGeometryEffect(id: "homeTabUnderline", in: tabNamespace)
                    } else {
                        Color.clear.frame(height: 1.5)
                    }
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel("\(tab.title) tab")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .music:
            musicTab
        case .shelf:
            ShelfStripView(isDropTarget: false)
        case .clipboard:
            ClipboardView()
        case .actions:
            VStack(alignment: .leading, spacing: 0) {
                QuickActionsRowView()
                Spacer(minLength: 0)
            }
        case .mirror:
            MirrorView()
        case .stats:
            StatsView()
        case .weather:
            WeatherView()
        }
    }

    private var musicTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            miniPlayer
            timerRow
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if let info = music.info {
            HStack(spacing: 12) {
                ArtworkView(image: info.artwork, size: 44, radius: 9)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: info.title, font: .system(size: 13, weight: .semibold), color: .white)
                    MarqueeText(text: info.artist, font: .system(size: 11), color: .white.opacity(0.6))
                }
                .accessibilityElement(children: .combine)
                GlyphButton(symbol: "backward.fill", size: 13) { music.previous() }
                GlyphButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 18) { music.togglePlayPause() }
                GlyphButton(symbol: "forward.fill", size: 13) { music.next() }
            }
        } else {
            HStack(spacing: 12) {
                ArtworkView(image: nil, size: 44, radius: 9)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not Playing").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Play something in Music, Spotify or Safari").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
        }
    }

    private var timerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            ForEach([1, 5, 10, 25], id: \.self) { minutes in
                PillButton(title: "\(minutes)m", tint: .orange) {
                    IslandTimer.shared.start(seconds: TimeInterval(minutes * 60), label: "Timer")
                }
                .accessibilityLabel("Start \(minutes) minute timer")
            }
            PillButton(title: "Pomodoro", tint: .orange) { IslandTimer.shared.startPomodoro() }
            if IslandTimer.shared.state != nil {
                PillButton(title: "Cancel", tint: .white.opacity(0.85)) { IslandTimer.shared.cancel() }
            }
            Spacer(minLength: 0)
            PillButton(title: IslandStopwatch.shared.state == nil ? "Stopwatch" : "Stop", symbol: "stopwatch.fill", tint: .orange) {
                if IslandStopwatch.shared.state == nil { IslandStopwatch.shared.start() } else { IslandStopwatch.shared.reset() }
            }
        }
    }
}
