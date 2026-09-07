import AppKit
import SwiftUI

/// Spring curves tuned to feel like the iPhone's Dynamic Island: a slightly overshooting
/// open, a firmer close, and a soft settle for content swaps.
enum IslandMotion {
    /// Honour the system "Reduce motion" setting with short fades instead of springs.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var open: Animation { reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.50, dampingFraction: 0.72, blendDuration: 0) }
    static var close: Animation { reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.40, dampingFraction: 0.86, blendDuration: 0) }
    static var content: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.30, dampingFraction: 0.80, blendDuration: 0) }
    static var bubble: Animation { reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.48, dampingFraction: 0.66, blendDuration: 0) }
    static var quick: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.86, blendDuration: 0) }

    /// Growing (a new activity popping out of the notch, expanding) gets the bouncy open
    /// spring; shrinking gets the firmer close spring.
    static func shape(from old: IslandLayout, to new: IslandLayout) -> Animation {
        (new.bodyWidth > old.bodyWidth || new.bodyHeight > old.bodyHeight) ? open : close
    }
}
