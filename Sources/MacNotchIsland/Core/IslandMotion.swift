import AppKit
import SwiftUI

/// The island's motion vocabulary.
///
/// Every curve here is either a spring or an ease, and which one it is says what it is for.
/// Springs move things — the outline growing, a slot arriving, a thumb taking hold of a
/// slider — because a spring carries momentum and settles the way a real thing does. Eases
/// change how something looks without moving it — a highlight coming up under the pointer,
/// one line of text replacing another — because a spring on an opacity is a wobble you can
/// see and cannot explain. Mixing the two is what makes an interface feel almost right.
///
/// The springs are written as a duration and a bounce rather than a response and a damping
/// fraction. They are the same curves either way, but bounce is the number that says how the
/// motion will feel: 0 never overshoots, 0.3 is as far as anything here goes, and only two
/// things in the whole island are allowed that much.
enum IslandMotion {

    // MARK: - Reduce Motion

    /// Whether the user has asked the system for less movement.
    ///
    /// Read from a cached answer rather than from `NSWorkspace` each time: a curve is asked
    /// for many times in a frame, and this only changes when the user changes it.
    static var reduceMotion: Bool { ReduceMotionWatcher.shared.isOn }

    /// Reduce Motion asks for a change of state, not a journey to it, so every spring becomes
    /// a short fade of its own length.
    private static func moving(_ spring: Animation, still: Double) -> Animation {
        moving(spring, still: still, reduced: reduceMotion)
    }

    /// The same choice with the setting handed in, so both halves of it can be tested. The
    /// live answer comes from a cached watcher with nothing to inject.
    static func moving(_ spring: Animation, still: Double, reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: still) : spring
    }

    // MARK: - Springs: things that move

    /// The island growing — an activity coming out of the notch, a panel opening. The one
    /// curve with real bounce in it, and what makes the shape read as pushed out rather than
    /// resized.
    static var open: Animation { moving(.spring(duration: 0.44, bounce: 0.28), still: 0.18) }

    /// The island shrinking. No bounce at all: an outline that overshoots on the way back in
    /// reads as a wobble, and the one in the phone never does it.
    static var close: Animation { moving(.spring(duration: 0.32, bounce: 0), still: 0.16) }

    /// Stepping sideways between views. Almost no bounce, so a run of keypresses reads as
    /// paging rather than as a stack of springs landing on each other.
    static var navigate: Animation { moving(.spring(duration: 0.34, bounce: 0.06), still: 0.16) }

    /// The detached bubble, the one element allowed to be playful: it pops out on its own,
    /// with nothing else moving, so it can afford the overshoot.
    static var bubble: Animation { moving(.spring(duration: 0.42, bounce: 0.32), still: 0.18) }

    /// Something arriving in or leaving the island: a shelf tile, a privacy dot, a banner, a
    /// slot in the switcher.
    static var content: Animation { moving(.spring(duration: 0.28, bounce: 0.12), still: 0.15) }

    /// A number changing where it stands. Rolling digits are movement, so this is a spring —
    /// but a number that overshoots its own value and comes back is a number you cannot read,
    /// so it is the one spring with no bounce in it at all.
    static var digits: Animation { moving(.spring(duration: 0.35, bounce: 0), still: 0.15) }

    /// A control taking hold — a slider's thumb growing under the pointer, a meter answering
    /// a keypress. Short, and only just springy.
    static var control: Animation { moving(.spring(duration: 0.24, bounce: 0.1), still: 0.12) }

    // MARK: - Eases: things that only change how they look

    /// A highlight coming up under the pointer. Never a spring: hover is a change of colour,
    /// not a movement, and a spring on an alpha ripples.
    static let hover = Animation.easeOut(duration: 0.12)

    /// One thing replacing another where it stands: a line of lyrics, a name, a glyph, a
    /// preview taking over from the section under it.
    static let fade = Animation.easeInOut(duration: 0.18)

    /// Press feedback, which is not symmetric. The press has to land the instant the mouse
    /// goes down or the button feels late; the release is the half that springs back. Every
    /// button Apple ships does this, and it is most of why they feel physical.
    static func press(down: Bool) -> Animation {
        down ? .easeOut(duration: 0.07) : moving(.spring(duration: 0.3, bounce: 0.3), still: 0.12)
    }

    /// A value that arrives on a clock: a timer's ring, a download's bar. Sweeping to it in
    /// exactly the time the next one takes to arrive is what makes a ring that is really
    /// redrawn once a second look like it never stops moving.
    static func meter(cadence: Double) -> Animation { .linear(duration: max(0.05, cadence)) }

    // MARK: - Transitions

    /// How far a view slides in when stepping sideways. Small on purpose: Apple's pushes
    /// suggest a direction, they do not travel the whole width.
    static let slideDistance: CGFloat = 36

    /// The content swap for a change of view: a directional push when the user stepped
    /// sideways (keyboard, switcher), a blur cross-fade otherwise. Only the incoming view
    /// moves; the outgoing one fades where it is. A view's removal transition is fixed when
    /// it arrives, so moving it too would send it the wrong way after a reversal.
    static func contentTransition(direction: Int) -> AnyTransition {
        guard direction != 0, !reduceMotion else { return AnyTransition(BlurReplaceTransition.blurReplace) }
        let distance = direction > 0 ? slideDistance : -slideDistance
        return .asymmetric(insertion: .offset(x: distance).combined(with: .opacity), removal: .opacity)
    }

    /// A scale-and-fade pop for things that appear inside the island (a bubble, artwork, a
    /// shelf item); a plain fade under Reduce Motion.
    static func pop(scale: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: scale).combined(with: .opacity)
    }

    // MARK: - The outline

    /// The curve for a change of the island's outline: the navigate spring while the user is
    /// stepping sideways (so the outline and the pushed content move together), otherwise the
    /// open or close spring for growth or shrinkage.
    static func shape(from old: IslandLayout, to new: IslandLayout, direction: Int) -> Animation {
        direction != 0 ? navigate : shape(from: old, to: new)
    }

    /// Growing (a new activity popping out of the notch, expanding) gets the bouncy open
    /// spring; shrinking gets the firmer close spring.
    static func shape(from old: IslandLayout, to new: IslandLayout) -> Animation {
        (new.bodyWidth > old.bodyWidth || new.bodyHeight > old.bodyHeight) ? open : close
    }
}

/// Holds the Reduce Motion answer and keeps it current, so asking for a curve never costs a
/// trip to the workspace.
private final class ReduceMotionWatcher {
    static let shared = ReduceMotionWatcher()

    private(set) var isOn: Bool

    private init() {
        isOn = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.isOn = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}
