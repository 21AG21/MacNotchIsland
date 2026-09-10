import SwiftUI

/// The black island itself: shape, content, hover / click / drop handling.
struct IslandBodyView: View {
    let geometry: NotchGeometry
    let presentation: IslandPresentation
    let layout: IslandLayout
    var panelID: String = "main"
    /// The curve the outline is morphing on, handed down from the root so it can be re-asserted
    /// *under* the press feedback. See where it is applied.
    var shapeAnimation: Animation = IslandMotion.open

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
                .islandShadow(shadowStrength, height: layout.bodyHeight)
            rim

            content
                .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
                // Cut to the outline, not to its bounding box. `.clipped()` is a square clip,
                // and the body's bottom corners are a 36 pt continuous curve that pulls the
                // black some fifty points inward along the bottom edge. At rest nothing is
                // drawn down there, so it never showed — but all the way through the growth
                // the clip's bottom edge sweeps up through the switcher, the section and the
                // divider, and a tapering sliver of each escaped at both corners and sat on
                // the wallpaper outside the island.
                .clipShape(NotchShape(topRadius: 0, bottomRadius: layout.bottomRadius,
                                      floating: layout.floating, isPill: layout.isPillBottom))
                .padding(.horizontal, layout.floating ? 0 : layout.topRadius)
        }
        .frame(width: layout.frameWidth, height: layout.bodyHeight)
        .contentShape(NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius, floating: layout.floating, isPill: layout.isPillBottom))
        // The outline's own curve, said again here — and this is load-bearing.
        //
        // Nested `.animation(_:value:)` is innermost-wins, so the press feedback below governed
        // everything above it, the frame and the shape included. `pressed` always falls to
        // false in the very transaction that opens the panel, so every click-to-open morphed
        // the whole island on the press release's spring — 0.3 s at bounce 0.3 — instead of the
        // open spring, with the scale springing over the top of it. Two overshoots at once, and
        // an open that looked nothing like the one hovering gives you.
        .animation(shapeAnimation, value: layout)
        // Press-in feedback while the whole island is the button (compact and idle); the
        // expanded panels have controls of their own that give their own feedback. Applied
        // outside the line above, so it governs the scale and nothing else.
        .scaleEffect(pressed ? 0.97 : 1, anchor: .top)
        .animation(IslandMotion.press(down: pressed), value: pressed)
        // A floating pill hangs below the top edge instead of fusing into it; zero otherwise.
        .offset(y: layout.topInset)
        .onHover { hovering in center.setHovering(hovering, panel: panelID) }
        .onTapGesture { center.tap(panel: panelID) }
        // The island is the app's face, so it answers a right-click the way its menu bar item
        // does. `NotchHostingView.rightMouseDown` has been holding the panel open for a menu
        // that was never there; this is the menu. A shelf tile's own menu wins over it, the
        // way an inner context menu always does.
        .contextMenu { IslandMenu(activity: presentation.primary) }
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

    /// How much of a shadow the island casts. A floating pill is an object on every screen and
    /// always has one. A fused island only becomes an object when it has something to say: at
    /// rest it *is* the notch, and a shadow there would print a soft halo on the menu bar all
    /// round a camera housing that has never cast one.
    ///
    /// Both this and the rim's opacity are left to whatever animation is running when they
    /// change, which is the one `IslandRootView` puts on the layout — the same spring the
    /// shape is morphing under, so the edge and the shadow arrive with it. Scoping a fade of
    /// their own here would have caught the shape too: `.animation(_:value:)` governs every
    /// animatable change in its subtree for that transaction, and the radii change in exactly
    /// the same one, so the island's whole morph would have crossed on a linear fade instead
    /// of the open spring.
    private var shadowStrength: Double {
        layout.floating || !isResting ? 1 : 0
    }

    /// `IslandRim`, cut to the shape the island is wearing.
    ///
    /// The fused island has three edges, not four: `openTop` leaves the screen's own out, and
    /// the fade takes care of the ears that run along it. A floating pill has four real edges
    /// and gets the whole closed loop, lit from the top one down.
    ///
    /// At rest on a notched screen it has none at all. An island showing nothing *is* the
    /// notch — the same width, the same height, and the black in it is the bezel's — so an
    /// outline there would trace the camera housing in the island's own rounding rather than
    /// the housing's, and land beside it. Having something to say is what makes it an object,
    /// and an object gets an edge.
    @ViewBuilder
    private var rim: some View {
        let shape = NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius,
                               floating: layout.floating, isPill: layout.isPillBottom,
                               openTop: !layout.floating)
        if layout.floating {
            shape
                .stroke(IslandRim.lit, lineWidth: IslandRim.width)
                .accessibilityHidden(true)
        } else {
            shape
                .stroke(IslandRim.color, lineWidth: IslandRim.width)
                .accessibilityHidden(true)
                // Measured from the height on screen rather than the one being arrived at.
                // A `UnitPoint` is a fraction of whatever it is drawn into, and taking that
                // fraction from the final height while the mask was still the notch's own
                // scaled the fade with the growth: the lit rim reached full strength a point
                // below the top of the screen instead of ten, which is the bright hairline
                // along the top row of the display that `IslandRim.fade` exists to prevent.
                .mask {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .black], startPoint: .top,
                                       endPoint: UnitPoint(x: 0.5, y: IslandRim.fade / max(1, proxy.size.height)))
                    }
                }
                // Faded rather than taken away: the island is already growing out of the
                // notch when this changes, and an edge that snaps into existence on frame one
                // of that is the one part of the move that did not move. On the shape's own
                // curve, not a fade of its own — see `shadowStrength`.
                .opacity(isResting ? 0 : 1)
        }
    }

    /// Nothing to show: the island is the notch and nothing more.
    private var isResting: Bool {
        if case .idle = presentation { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch presentation {
            case .idle:
                IdleContentView(layout: layout)
            case .compact(let activity, _):
                CompactContentView(activity: activity, layout: layout)
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
