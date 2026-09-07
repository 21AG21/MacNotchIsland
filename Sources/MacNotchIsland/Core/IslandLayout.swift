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

    static let expandedTopRadius: CGFloat = 20
    static let expandedBottomRadius: CGFloat = 30
    static let homeSize = CGSize(width: 540, height: 150)

    /// Full width of the shape including the outward top corners.
    var frameWidth: CGFloat { bodyWidth + topRadius * 2 }

    /// Rect (centred, top-anchored) that should receive mouse events.
    var hitSize: CGSize {
        let extra = hasBubble ? (bubbleGap + bubbleDiameter) * 2 : 0
        return CGSize(width: frameWidth + extra + 8, height: bodyHeight + 6)
    }

    static func make(presentation: IslandPresentation, geometry g: NotchGeometry, center: ActivityCenter = .shared) -> IslandLayout {
        let notchW = g.notchWidth
        let h = g.notchHeight
        let privacy: CGFloat = center.privacyIndicatorsVisible ? 18 : 0

        switch presentation {
        case .idle:
            let pad: CGFloat = privacy > 0 ? 22 : 0
            return IslandLayout(bodyWidth: notchW + pad * 2, bodyHeight: h,
                                topRadius: 6, bottomRadius: min(10, h / 2),
                                leadingWidth: pad, trailingWidth: pad, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: false)

        case .compact(let a, let bubble):
            let w = a.content.compactWidths
            let trailing = w.trailing + privacy
            return IslandLayout(bodyWidth: notchW + w.leading + trailing, bodyHeight: h,
                                topRadius: 8, bottomRadius: h / 2,
                                leadingWidth: w.leading, trailingWidth: trailing, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: bubble != nil, isExpanded: false)

        case .expanded(let a):
            let size = a.content.expandedSize(notch: g)
            return IslandLayout(bodyWidth: max(size.width, notchW + 120), bodyHeight: size.height,
                                topRadius: expandedTopRadius, bottomRadius: expandedBottomRadius,
                                leadingWidth: 0, trailingWidth: 0, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: true)

        case .home, .shelf:
            return IslandLayout(bodyWidth: homeSize.width, bodyHeight: h + homeSize.height,
                                topRadius: expandedTopRadius, bottomRadius: expandedBottomRadius,
                                leadingWidth: 0, trailingWidth: 0, privacyWidth: privacy,
                                bubbleDiameter: h, bubbleGap: 8, hasBubble: false, isExpanded: true)
        }
    }
}
