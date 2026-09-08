import SwiftUI
import UniformTypeIdentifiers

/// The black island itself: shape, content, hover / click / drop handling.
struct IslandBodyView: View {
    let geometry: NotchGeometry
    let presentation: IslandPresentation
    let layout: IslandLayout
    var panelID: String = "main"

    @EnvironmentObject private var center: ActivityCenter
    @EnvironmentObject private var prefs: Preferences
    @State private var dropTargeted = false
    @Namespace private var islandNamespace

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius, floating: layout.floating, isPill: layout.isPillBottom)
                .fill(Color.black)

            content
                .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
                .clipped()
                .padding(.horizontal, layout.floating ? 0 : layout.topRadius)

            // A HUD or a warning that arrives while a panel is open sits over its top edge in
            // the island's compact form; the panel underneath stays exactly where it is.
            if layout.isExpanded, let strip = center.overlayAlert {
                AlertStrip(activity: strip, geometry: geometry, layout: layout)
                    .transition(IslandMotion.pop(scale: 0.85))
            }
        }
        .frame(width: layout.frameWidth, height: layout.bodyHeight)
        .animation(IslandMotion.quick, value: center.overlayAlert?.id)
        .contentShape(NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius, floating: layout.floating, isPill: layout.isPillBottom))
        // Press-in feedback while the whole island is the button (compact and idle); the
        // expanded panels have controls of their own that give their own feedback.
        .scaleEffect(pressed ? 0.97 : 1, anchor: .top)
        .animation(IslandMotion.quick, value: pressed)
        // A floating pill hangs below the top edge instead of fusing into it; zero otherwise.
        .offset(y: layout.topInset)
        .onHover { hovering in center.setHovering(hovering, panel: panelID) }
        .onTapGesture { center.tap(panel: panelID) }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard prefs.shelfEnabled else { return false }
            return ShelfStore.shared.acceptDrop(providers)
        }
        .onChange(of: dropTargeted) { _, targeted in
            center.setDragTargeted(targeted && prefs.shelfEnabled, panel: panelID)
        }
    }

    private var pressed: Bool {
        center.pressedPanel == panelID && !layout.isExpanded
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch presentation {
            case .idle:
                IdleContentView(layout: layout)
            case .compact(let activity, _):
                CompactContentView(activity: activity, layout: layout, geometry: geometry)
            case .expanded(let activity):
                ExpandedContentView(activity: activity, layout: layout, geometry: geometry)
            case .home:
                HomeExpandedView(geometry: geometry, layout: layout)
            case .shelf:
                ShelfExpandedView(geometry: geometry, layout: layout, isDropTarget: true)
            }
        }
        .id(presentation.contentID)
        .transition(IslandMotion.contentTransition(direction: center.navigationDirection))
        .environment(\.islandNamespace, islandNamespace)
    }
}

/// The island's compact form for one alert, drawn over an open panel.
private struct AlertStrip: View {
    let activity: IslandActivity
    let geometry: NotchGeometry
    let layout: IslandLayout
    @EnvironmentObject private var center: ActivityCenter
    @ObservedObject private var menuBar = MenuBarClearance.shared

    var body: some View {
        let strip = IslandLayout.make(presentation: .compact(activity, bubble: nil), geometry: geometry,
                                      center: center, clearance: menuBar.limits)
        ZStack(alignment: .top) {
            NotchShape(topRadius: strip.topRadius, bottomRadius: strip.bottomRadius, floating: strip.floating, isPill: strip.isPillBottom)
                .fill(Color.black)
            CompactContentView(activity: activity, layout: strip, geometry: geometry)
                .frame(width: strip.bodyWidth, height: strip.bodyHeight, alignment: .top)
                .padding(.horizontal, strip.floating ? 0 : strip.topRadius)
        }
        .frame(width: strip.frameWidth, height: strip.bodyHeight)
        // The panel is already shifted by its own `bodyShift`; only the difference remains.
        .offset(x: strip.bodyShift - layout.bodyShift)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct IdleContentView: View {
    let layout: IslandLayout
    @EnvironmentObject private var center: ActivityCenter

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if center.privacyIndicatorsVisible {
                PrivacyDots()
                    .frame(width: layout.privacyWidth + 4, height: layout.bodyHeight)
                    .padding(.trailing, 4)
                    .transition(IslandMotion.pop(scale: 0.5))
            }
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight)
        .animation(IslandMotion.quick, value: center.privacyIndicatorsVisible)
    }
}
