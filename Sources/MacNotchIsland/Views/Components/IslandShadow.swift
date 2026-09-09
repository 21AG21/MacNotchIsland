import SwiftUI

/// What the island casts on what is behind it.
///
/// Every surface macOS floats over the desktop sits on one: a notification, Control Centre,
/// a menu, the Dock. Without it a black shape on a wallpaper is not an object in front of the
/// screen, it is a hole cut out of it — and a seven-hundred-point slab of black meeting the
/// desktop at a razor edge is the loudest thing in the app saying nobody at Apple drew it.
///
/// Two shadows rather than one, the way a real one falls: a tight dark contact shadow that
/// says the edge is a millimetre off the glass, and a wide soft one that carries the weight.
enum IslandShadow {
    static let contactRadius: CGFloat = 3
    static let contactOffset: CGFloat = 1
    static let contactOpacity: Double = 0.24

    /// The soft shadow at its largest, which is what a panel the size of a window casts.
    static let ambientRadius: CGFloat = 16
    static let ambientOffset: CGFloat = 6
    static let ambientOpacity: Double = 0.34
    /// And at its smallest: the compact pill is a couple of centimetres of black lying on the
    /// menu bar, and the halo of a window's shadow around it would be most of what you saw.
    /// Apple's shadows grow with the thing that casts them, so this one does too.
    static let smallestRadius: CGFloat = 6
    static let smallestOffset: CGFloat = 2
    static let smallestOpacity: Double = 0.22
    /// The height at which the soft shadow reaches its full size.
    static let fullHeight: CGFloat = 120

    /// How far the largest shadow reaches past the shape. The window keeps at least this much
    /// clear around the island; a blur with no room to fall in is cut off square at the
    /// window's own edge, which is a hard line exactly where the softest part should be.
    static var reach: CGFloat { ambientRadius + ambientOffset }

    /// The soft shadow for a surface this tall.
    static func ambient(height: CGFloat) -> (radius: CGFloat, offset: CGFloat, opacity: Double) {
        let t = min(1, max(0, height / fullHeight))
        return (smallestRadius + (ambientRadius - smallestRadius) * t,
                smallestOffset + (ambientOffset - smallestOffset) * t,
                smallestOpacity + (ambientOpacity - smallestOpacity) * Double(t))
    }
}

extension View {
    /// `strength` fades the whole thing rather than switching it off, so it can arrive on the
    /// same curve as the shape it belongs to.
    func islandShadow(_ strength: Double, height: CGFloat) -> some View {
        let ambient = IslandShadow.ambient(height: height)
        return shadow(color: .black.opacity(IslandShadow.contactOpacity * strength),
                      radius: IslandShadow.contactRadius, y: IslandShadow.contactOffset)
            .shadow(color: .black.opacity(ambient.opacity * strength),
                    radius: ambient.radius, y: ambient.offset)
    }
}
