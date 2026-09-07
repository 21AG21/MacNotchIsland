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

    /// Rect (centred, top-anchored) that should receive mouse events.
    var hitSize: CGSize {
        let extra = hasBubble ? (bubbleGap + bubbleDiameter) * 2 : 0
        return CGSize(width: frameWidth + extra + 8, height: bodyHeight + topInset + 6)
    }

    static func make(presentation: IslandPresentation, geometry g: NotchGeometry, center: ActivityCenter = .shared) -> IslandLayout {
        let notchW = g.notchWidth
        let h = g.notchHeight
        let privacy: CGFloat = center.privacyIndicatorsVisible ? 18 : 0
        let floating = !g.hasPhysicalNotch
        let inset: CGFloat = floating ? floatingTopInset : 0

        switch presentation {
        case .idle:
            let pad: CGFloat = privacy > 0 ? 22 : 0
            // Floating: a small resting pill rather than a slab as wide as the (absent) notch.
            let base = floating ? floatingIdleWidth : notchW
            let bottom = floating ? h / 2 : min(10, h / 2)
            return IslandLayout(bodyWidth: base + pad * 2, bodyHeight: h,
                                topRadius: floating ? bottom : 6, bottomRadius: bottom,
                                leadingWidth: pad, trailingWidth: pad, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: false,
                                floating: floating, topInset: inset)

        case .compact(let a, let bubble):
            let w = a.content.compactWidths
            let trailing = w.trailing + privacy
            let bottom = h / 2
            return IslandLayout(bodyWidth: notchW + w.leading + trailing, bodyHeight: h,
                                topRadius: floating ? bottom : 8, bottomRadius: bottom,
                                leadingWidth: w.leading, trailingWidth: trailing, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: bubble != nil, isExpanded: false,
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
