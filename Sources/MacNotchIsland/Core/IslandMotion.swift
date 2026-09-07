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
    /// Stepping between views with the keyboard: settled enough that a run of Tab presses
    /// reads as paging, not as a series of bounces.
    static var navigate: Animation { reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.38, dampingFraction: 0.84, blendDuration: 0) }
    /// How far a view slides in or out when stepping sideways. Small on purpose: Apple's
    /// pushes suggest direction, they do not travel the whole width.
    static let slideDistance: CGFloat = 36

    /// The content swap for a change of view: a directional push when the user stepped
    /// sideways (keyboard, tab bar), a blur cross-fade otherwise.
    static func contentTransition(direction: Int) -> AnyTransition {
        guard direction != 0, !reduceMotion else { return .blurReplace }
        let distance = direction > 0 ? slideDistance : -slideDistance
        return .asymmetric(insertion: .offset(x: distance).combined(with: .opacity),
                           removal: .offset(x: -distance).combined(with: .opacity))
    }

    /// Growing (a new activity popping out of the notch, expanding) gets the bouncy open
    /// spring; shrinking gets the firmer close spring.
    static func shape(from old: IslandLayout, to new: IslandLayout) -> Animation {
        (new.bodyWidth > old.bodyWidth || new.bodyHeight > old.bodyHeight) ? open : close
    }
}
