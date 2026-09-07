import SwiftUI

/// What the island is showing right now.
enum IslandPresentation: Equatable {
    case idle
    case compact(IslandActivity, bubble: IslandActivity?)
    case expanded(IslandActivity)
    case home
    case shelf

    var primary: IslandActivity? {
        switch self {
        case .compact(let a, _), .expanded(let a): return a
        default: return nil
        }
    }

    var isExpanded: Bool {
        switch self {
        case .expanded, .home, .shelf: return true
        default: return false
        }
    }

    /// Stable identity used to drive content transitions.
    var contentID: String {
        switch self {
        case .idle: return "idle"
        case .compact(let a, _): return "compact-\(a.id)"
        case .expanded(let a): return "expanded-\(a.id)"
        case .home: return "home"
        case .shelf: return "shelf"
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

    static let expandedTopRadius: CGFloat = 20
    static let expandedBottomRadius: CGFloat = 30
    static let homeSize = CGSize(width: 540, height: 150)
    /// The resting pill on a notchless screen, sized like the iPhone's idle island.
    static let floatingIdleWidth: CGFloat = 120
    static let floatingTopInset: CGFloat = 6

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
        let inset: CGFloat = floating ? floatingTopInset : 0
        // A floating island sits below the menu bar and covers nothing in it.
        let room = floating ? MenuBarClearance.Limits.unlimited : clearance

        switch presentation {
        case .idle:
            let tightest = [room.leading, room.trailing].compactMap { $0 }.min()
            let pad: CGFloat = privacy > 0 ? MenuBarClearance.fitted(privacy + 8, minimal: privacy + 8, free: tightest) : 0
            // Floating: a small resting pill rather than a slab as wide as the (absent) notch.
            let base = floating ? floatingIdleWidth : notchW
            let bottom = floating ? h / 2 : min(10, h / 2)
            return IslandLayout(bodyWidth: base + pad * 2, bodyHeight: h,
                                topRadius: floating ? bottom : 6, bottomRadius: bottom,
                                leadingWidth: pad, trailingWidth: pad, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: false,
                                floating: floating, topInset: inset)

        case .compact(let a, let bubble):
            let full = a.content.compactWidths
            let minimal = a.content.compactMinimalWidths
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
            return IslandLayout(bodyWidth: notchW + leading + trailing, bodyHeight: h,
                                topRadius: floating ? bottom : 8, bottomRadius: bottom,
                                leadingWidth: leading, trailingWidth: trailing, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: hasBubble, isExpanded: false,
                                floating: floating, topInset: inset)

        case .expanded(let a):
            let size = a.content.expandedSize(notch: g)
            return IslandLayout(bodyWidth: max(size.width, notchW + 120), bodyHeight: size.height,
                                topRadius: floating ? expandedBottomRadius : expandedTopRadius,
                                bottomRadius: expandedBottomRadius,
                                leadingWidth: 0, trailingWidth: 0, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: true,
                                floating: floating, topInset: inset)

        case .home, .shelf:
            return IslandLayout(bodyWidth: homeSize.width, bodyHeight: h + homeSize.height,
                                topRadius: floating ? expandedBottomRadius : expandedTopRadius,
                                bottomRadius: expandedBottomRadius,
                                leadingWidth: 0, trailingWidth: 0, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: true,
                                floating: floating, topInset: inset)
        }
    }
}
