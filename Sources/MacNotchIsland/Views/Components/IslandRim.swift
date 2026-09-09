import SwiftUI

/// The hairline of light along the island's own edges.
///
/// Against a pale menu bar the island's black is its own edge and this is barely there.
/// Against a dark wallpaper, where macOS draws the menu bar nearly black, it is the only
/// thing that says where the island ends — without it the shape dissolves into the bar and
/// what is in it reads as two marks floating in a void rather than as one object.
enum IslandRim {
    static let color = Color.white.opacity(0.10)
    static let width: CGFloat = 1

    /// How far down a fused island's sides the rim takes to reach full strength.
    ///
    /// Its top edge is not an edge: it runs along the top of the screen, into the black the
    /// bleed above it keeps solid. The outline leaves that edge out, and the ears either side
    /// of it leave the screen edge horizontally — stroking that first stretch would lay a lit
    /// hairline along the very top row of the display, which is the seam, not the shape.
    static let fade: CGFloat = 10
}
