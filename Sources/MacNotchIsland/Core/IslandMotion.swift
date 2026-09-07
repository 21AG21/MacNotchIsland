import SwiftUI

/// Spring curves tuned to feel like the iPhone's Dynamic Island: a slightly overshooting
/// open, a firmer close, and a soft settle for content swaps.
enum IslandMotion {
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.68, blendDuration: 0)
    static let close = Animation.spring(response: 0.34, dampingFraction: 0.84, blendDuration: 0)
    static let content = Animation.spring(response: 0.30, dampingFraction: 0.80, blendDuration: 0)
    static let bubble = Animation.spring(response: 0.48, dampingFraction: 0.66, blendDuration: 0)
    static let quick = Animation.spring(response: 0.22, dampingFraction: 0.86, blendDuration: 0)

    static func shape(from old: IslandLayout, to new: IslandLayout) -> Animation {
        new.bodyWidth >= old.bodyWidth || new.bodyHeight > old.bodyHeight ? open : close
    }
}
