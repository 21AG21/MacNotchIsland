import SwiftUI

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

            // A volume or brightness key pressed while the panel is showing: a level line
            // along the panel's top edge, nothing else moves.
            if presentation.panelView != nil, let strip = center.overlayAlert, case .hud(let hud) = strip.content {
                HUDLine(hud: hud)
                    .frame(width: layout.bodyWidth)
                    .padding(.horizontal, layout.floating ? 0 : layout.topRadius)
                    .transition(.opacity)
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
        .islandDrop(isTargeted: $dropTargeted) { providers in
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
            case .card(let activity):
                ExpandedContentView(activity: activity, layout: layout, geometry: geometry)
            case .panel(let view):
                PanelView(view: view, geometry: geometry, layout: layout)
            case .shelf:
                PanelView(view: .home(tab: HomeSection.shelf.rawValue), geometry: geometry, layout: layout, isDropTarget: true)
            }
        }
        .id(presentation.contentID)
        .transition(IslandMotion.contentTransition(direction: center.navigationDirection))
        .environment(\.islandNamespace, islandNamespace)
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
