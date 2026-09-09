import SwiftUI

/// What the island is showing right now.
enum IslandPresentation: Equatable {
    case idle
    case compact(IslandActivity, bubble: IslandActivity?)
    /// A card the system put up on its own (an alert with a large view, a timer that rang):
    /// one or two rows under the notch, no switcher, gone when the alert is.
    case card(IslandActivity)
    /// The user's panel: the switcher in the top band, one section or one activity below it,
    /// the control rail at the bottom. Opened by the pointer, a click or the keyboard.
    case panel(IslandView)
    /// The panel on its Shelf section while files are dragged over the island.
    case shelf

    var primary: IslandActivity? {
        switch self {
        case .compact(let a, _), .card(let a): return a
        default: return nil
        }
    }

    var isExpanded: Bool {
        switch self {
        case .card, .panel, .shelf: return true
        default: return false
        }
    }

    /// Stable identity used to drive content transitions.
    ///
    /// Every panel view shares one identity on purpose. The panel is one thing — the switcher
    /// in the band, a section, the rail — and stepping to the next section changes only the
    /// section. Giving each view its own identity here would tear the whole panel down and
    /// build it again on every step: the switcher and the rail would fade out and back in for
    /// a change that never touched them, and the rail's audio listeners would be dropped and
    /// rebuilt each time. The section makes its own, smaller transition inside `PanelView`.
    var contentID: String {
        switch self {
        case .idle: return "idle"
        case .compact(let a, _): return "compact-\(a.id)"
        case .card(let a): return "card-\(a.id)"
        case .panel, .shelf: return "panel"
        }
    }
}

/// Concrete geometry for a presentation on a given screen.
struct IslandLayout: Equatable {
    var bodyWidth: CGFloat
    var bodyHeight: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var leadingWidth: CGFloat
    var trailingWidth: CGFloat
    var privacyWidth: CGFloat
    var bubbleDiameter: CGFloat
    var bubbleGap: CGFloat
    var hasBubble: Bool
    var isExpanded: Bool
    /// True on a screen with no physical notch. There is nothing there for the island to fuse
    /// into, so it becomes the iPhone's free-floating pill instead: rounded on all four corners,
    /// hanging `topInset` below the top edge, with no outward "ears" in its frame.
    var floating: Bool = false
    /// How far below the top of the screen the body hangs. Zero against a physical notch, where
    /// the island *is* the notch.
    var topInset: CGFloat = 0
    /// The gap the compact content leaves between its two slots.
    ///
    /// The cutout, on a screen that has one — the iPhone's leading and trailing regions exist
    /// because the sensor housing is between them. On a screen with none it is a breath of
    /// space and nothing more: reserving the same width for a camera housing that is not there
    /// made a floating pill nearly three hundred points of black with a mark at either end.
    var middleWidth: CGFloat = 0

    // MARK: - The scale

    static let compactTopRadius: CGFloat = 8
    static let expandedTopRadius: CGFloat = 20
    static let expandedBottomRadius: CGFloat = 36

    /// The panel: one width for every view, so stepping between them never resizes the island.
    /// Wide enough for every section's switcher slot to sit beside the cutout at a size the
    /// pointer can hit, and for four window tiles to stand side by side.
    static let panelWidth: CGFloat = 720
    /// The top band straddles the notch by this much; the switcher lives in it.
    static let bandExtra: CGFloat = 2.5
    static let sectionHeight: CGFloat = 140
    static let railHeight: CGFloat = 40
    /// 8 pt, a hairline, 8 pt.
    static let dividerBlock: CGFloat = 16.5
    static let panelBottomInset: CGFloat = 14
    static let panelContentHeight: CGFloat = sectionHeight + dividerBlock + railHeight + panelBottomInset
    /// The content column inside the panel.
    static let panelInset: CGFloat = 24
    static var panelContentWidth: CGFloat { panelWidth - 2 * panelInset }

    /// A system card is narrower: one thing, one or two rows.
    static let cardWidth: CGFloat = 440

    /// The band a card keeps clear above its content: the cutout on a screen that has one,
    /// and on a screen with none just enough air to hang the content off. A card that keeps
    /// the height of a camera housing that is not there is a card with a hole in the top of
    /// it, and the content sitting low in its own shape.
    static let floatingCardTop: CGFloat = 12
    static func cardTopBand(_ g: NotchGeometry) -> CGFloat {
        g.hasPhysicalNotch ? g.notchHeight : floatingCardTop
    }

    /// The trailing slot while a track's title and artist are peeking.
    static let sneakPeekTrailingWidth: CGFloat = 150

    /// The live activity a transient alert is drawn over, when the alert is feedback (a
    /// volume or brightness HUD, mute) rather than news: its leading glyph stays on the pill.
    static func activityUnder(_ alert: IslandActivity, center: ActivityCenter) -> IslandActivity? {
        guard center.alert?.id == alert.id, ActivityCenter.alertRank(alert) <= 2,
              let primary = center.primary, primary.id != alert.id else { return nil }
        return primary
    }

    /// The resting pill on a notchless screen: a handle, not a slab.
    static let floatingIdleWidth: CGFloat = 72
    static let floatingIdleHeight: CGFloat = 22
    /// What stands in for the cutout there: enough that the two slots read as two, no more.
    static let floatingMiddle: CGFloat = 28

    /// Full width of the shape: the body plus the outward top corners, which only exist when the
    /// island is fused to a physical notch.
    var frameWidth: CGFloat { floating ? bodyWidth : bodyWidth + topRadius * 2 }

    /// Whether the bottom corners are semicircles at rest (compact pill); the shape uses this
    /// instead of the animated radius so corners never pop mid-spring.
    var isPillBottom: Bool { NotchShape.hasCapsuleBottom(height: bodyHeight, bottomRadius: bottomRadius) }

    /// How far the body's centre sits right of the notch's centre. The compact body is the
    /// notch gap with a leading and a trailing slot either side, and those are rarely the
    /// same width; centring the body on the notch would push the gap, and with it the wider
    /// slot's content, into the physical cutout. The body is shifted instead so the gap stays
    /// exactly on the notch and the island simply reaches further on the wider side. A
    /// floating pill has no cutout to keep clear of and stays centred.
    var bodyShift: CGFloat { floating ? 0 : (trailingWidth - leadingWidth) / 2 }

    /// How far the island reaches left of the notch centre, with a little margin for the
    /// anti-aliased edge.
    var hitLeading: CGFloat { frameWidth / 2 - bodyShift + 4 }
    /// How far it reaches right of the notch centre: the bubble hangs off this side only.
    var hitTrailing: CGFloat { frameWidth / 2 + bodyShift + (hasBubble ? bubbleGap + bubbleDiameter : 0) + 4 }
    var hitHeight: CGFloat { bodyHeight + topInset + 6 }

    /// Rect (centred on the notch, top-anchored) that should receive mouse events. It is
    /// symmetric so a hosting view centred on the notch can use it; the window itself is cut
    /// asymmetrically from `hitLeading` and `hitTrailing`, so the part of this rect that has
    /// nothing under it lies outside the window and never sees a click.
    var hitSize: CGSize {
        CGSize(width: 2 * max(hitLeading, hitTrailing), height: hitHeight)
    }

    static func make(presentation: IslandPresentation, geometry g: NotchGeometry, center: ActivityCenter = .shared,
                     clearance: MenuBarClearance.Limits = MenuBarClearance.shared.limits) -> IslandLayout {
        let notchW = g.notchWidth
        let h = g.notchHeight
        let privacy: CGFloat = center.privacyIndicatorsVisible ? 18 : 0
        let floating = !g.hasPhysicalNotch
        // The floating pill hangs just below the menu bar, never on it.
        let inset: CGFloat = floating ? g.menuBarHeight + 4 : 0
        // A floating island sits below the menu bar and covers nothing in it.
        let room = floating ? MenuBarClearance.Limits.unlimited : clearance

        switch presentation {
        case .idle:
            let tightest = [room.leading, room.trailing].compactMap { $0 }.min()
            let pad: CGFloat = privacy > 0 ? MenuBarClearance.fitted(privacy + 8, minimal: privacy + 8, free: tightest) : 0
            // Floating: a small resting handle rather than a slab as wide as the (absent) notch.
            let base = floating ? floatingIdleWidth : notchW
            let height = floating ? floatingIdleHeight : h
            let bottom = floating ? height / 2 : min(10, h / 2)
            return IslandLayout(bodyWidth: base + pad * 2, bodyHeight: height,
                                topRadius: floating ? bottom : compactTopRadius, bottomRadius: bottom,
                                leadingWidth: pad, trailingWidth: pad, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: false,
                                floating: floating, topInset: inset)

        case .compact(let a, let bubble):
            var full = a.content.compactWidths
            var minimal = a.content.compactMinimalWidths
            if a.id == NowPlayingService.peekAlertID {
                // The sneak peek: the title and artist where the bars usually are.
                full.trailing = sneakPeekTrailingWidth
                minimal.trailing = 28
            } else if let under = Self.activityUnder(a, center: center) {
                // A key-press HUD over a live activity keeps that activity's glyph on the left.
                full.leading = under.content.compactWidths.leading
                minimal.leading = under.content.compactMinimalWidths.leading
            }
            let leading = MenuBarClearance.fitted(full.leading, minimal: minimal.leading, free: room.leading)
            // The privacy dots come first on the right; the content gets what is left.
            let content = MenuBarClearance.fitted(full.trailing, minimal: minimal.trailing,
                                                  free: room.trailing.map { $0 - privacy })
            let trailing = content + privacy
            // The bubble hangs off the right, so it needs its own room beyond the trailing side.
            let bubbleRoom = h + 8
            let hasBubble = bubble != nil
                && (room.trailing.map { $0 - MenuBarClearance.margin >= trailing + bubbleRoom } ?? true)
            let bottom = h / 2
            let middle = floating ? floatingMiddle : notchW
            return IslandLayout(bodyWidth: middle + leading + trailing, bodyHeight: h,
                                topRadius: floating ? bottom : compactTopRadius, bottomRadius: bottom,
                                leadingWidth: leading, trailingWidth: trailing, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: hasBubble, isExpanded: false,
                                floating: floating, topInset: inset, middleWidth: middle)

        case .card(let a):
            return IslandLayout(bodyWidth: cardWidth, bodyHeight: cardTopBand(g) + a.content.cardHeight,
                                topRadius: floating ? expandedBottomRadius : expandedTopRadius,
                                bottomRadius: expandedBottomRadius,
                                leadingWidth: 0, trailingWidth: 0, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: true,
                                floating: floating, topInset: inset)

        case .panel, .shelf:
            return IslandLayout(bodyWidth: panelWidth, bodyHeight: h + bandExtra + panelContentHeight,
                                topRadius: floating ? expandedBottomRadius : expandedTopRadius,
                                bottomRadius: expandedBottomRadius,
                                leadingWidth: 0, trailingWidth: 0, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: true,
                                floating: floating, topInset: inset)
        }
    }
}
