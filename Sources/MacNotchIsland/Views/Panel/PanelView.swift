import SwiftUI

/// The user's panel: the switcher in the top band, one view in the section area, the control
/// rail underneath. One size for every view, so stepping between them only moves the content.
struct PanelView: View {
    let view: IslandView
    let geometry: NotchGeometry
    let layout: IslandLayout
    var isDropTarget = false

    @EnvironmentObject private var center: ActivityCenter
    @State private var showingMirror = false

    var body: some View {
        VStack(spacing: 0) {
            SwitcherBand(geometry: geometry, current: view)

            ZStack(alignment: .top) {
                if showingMirror {
                    MirrorView()
                        .transition(.opacity)
                } else {
                    section
                        .id(view)
                        .transition(IslandMotion.contentTransition(direction: center.navigationDirection))
                }
            }
            .frame(width: IslandLayout.panelContentWidth, height: IslandLayout.sectionHeight, alignment: .top)
            .clipped()
            .environment(\.insidePanel, true)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: IslandLayout.panelContentWidth, height: 0.5)
                .padding(.vertical, 8)
                .accessibilityHidden(true)

            ZStack {
                // The rail stays mounted under a banner: unmounting it would drop the audio
                // device listeners and rebuild them a second later, on every volume keypress.
                ControlRail(showingMirror: $showingMirror)
                    .opacity(center.overlayAlert == nil ? 1 : 0)
                    .allowsHitTesting(center.overlayAlert == nil)
                    .accessibilityHidden(center.overlayAlert != nil)
                if let alert = center.overlayAlert {
                    AlertBanner(activity: alert)
                        .transition(.asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .opacity))
                }
            }
            .frame(height: IslandLayout.railHeight)
            .animation(IslandMotion.quick, value: center.overlayAlert?.id)

            Color.clear.frame(height: IslandLayout.panelBottomInset)
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
        .onChange(of: view) { _, _ in showingMirror = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title(for: view, center: center))
    }

    static func title(for view: IslandView, center: ActivityCenter) -> String {
        SwitcherBand.entry(for: view, center: center).title
    }

    @ViewBuilder
    private var section: some View {
        switch view {
        case .activity(let id):
            if let activity = center.activity(id: id) {
                ExpandedContentView(activity: activity, layout: layout, geometry: geometry)
            } else {
                MusicSectionView(geometry: geometry)
            }
        case .home(let tab):
            switch HomeSection(rawValue: tab) ?? .music {
            case .music: MusicSectionView(geometry: geometry)
            case .today: TodaySectionView()
            case .shelf: ShelfSectionView(isDropTarget: isDropTarget)
            case .clipboard: ClipboardSectionView()
            case .actions: ActionsSectionView()
            case .notes: NotesSectionView()
            case .stats: StatsSectionView()
            }
        }
    }
}

/// The shared empty state: one glyph, one title, one line, one control if there is one.
/// Sits a little above the section's centre so it never floats in the middle of black.
struct SectionEmptyState<Action: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var action: () -> Action

    init(symbol: String, title: String, subtitle: String? = nil, @ViewBuilder action: @escaping () -> Action) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            action()
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}

extension SectionEmptyState where Action == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A section's header line: the name on the left, at most a control or two on the right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(height: 22)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
