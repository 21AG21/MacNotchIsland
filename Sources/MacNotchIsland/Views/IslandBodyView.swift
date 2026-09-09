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

    /// How far the fused island carries its black past its own top edge. Up there is the
    /// bezel around the camera, black already, so the overdraw cannot be seen — and it means
    /// no rounding or compositing seam can leave a light hairline between the island and the
    /// top of the screen. Anything above the window's edge is simply clipped away.
    static let topBleed: CGFloat = 4

    var body: some View {
        ZStack(alignment: .top) {
            // A floating island has a real top edge to show, so it gets no bleed.
            if !layout.floating {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: layout.frameWidth, height: Self.topBleed)
                    .offset(y: -Self.topBleed)
                    .accessibilityHidden(true)
            }

            NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius, floating: layout.floating, isPill: layout.isPillBottom)
                .fill(Color.black)

            content
                .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
                .clipped()
                .padding(.horizontal, layout.floating ? 0 : layout.topRadius)
        }
        .frame(width: layout.frameWidth, height: layout.bodyHeight)
        .contentShape(NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius, floating: layout.floating, isPill: layout.isPillBottom))
        // Press-in feedback while the whole island is the button (compact and idle); the
        // expanded panels have controls of their own that give their own feedback.
        .scaleEffect(pressed ? 0.97 : 1, anchor: .top)
        .animation(IslandMotion.press(down: pressed), value: pressed)
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
        // The content crosses over on its own, shorter curve rather than riding the outline's.
        // The shape is what bounces; the thing inside it settles first and holds still while
        // the outline finishes arriving, which is the layering the phone's island has.
        .animation(IslandMotion.content, value: presentation.contentID)
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
        .animation(IslandMotion.content, value: center.privacyIndicatorsVisible)
    }
}
