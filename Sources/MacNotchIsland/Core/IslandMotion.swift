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
///
/// The numbers are the phone's, and they ship untouched. But the one thing users of every
/// notch app keep asking for, and none of them offers, is a hand on the curve — so the two
/// numbers that decide how a spring feels each have a multiplier the user can turn, and every
/// spring goes through the one door that applies them. At 1 and 1 nothing here is any
/// different from before, and a test holds that door shut.
enum IslandMotion {

    // MARK: - Reduce Motion

    /// Whether the user has asked the system for less movement.
    ///
    /// Read from a cached answer rather than from `NSWorkspace` each time: a curve is asked
    /// for many times in a frame, and this only changes when the user changes it.
    static var reduceMotion: Bool { ReduceMotionWatcher.shared.isOn }

    /// Reduce Motion asks for a change of state, not a journey to it, so every spring becomes
    /// a short fade of its own length. The setting is handed in so both halves of the choice
    /// can be tested; the live answer comes from a cached watcher with nothing to inject.
    static func moving(_ spring: Animation, still: Double, reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: still) : spring
    }

    // MARK: - Tuning: the user's hand on every spring

    /// A spring's two numbers, before or after the user's tuning. A struct rather than a tuple
    /// so it keeps its labels through a ternary and can be compared in a test.
    struct SpringParameters: Equatable {
        var duration: Double
        var bounce: Double
    }

    /// A multiplier on every spring's duration and one on its bounce.
    ///
    /// Multipliers rather than numbers of their own, so that the springs keep their proportions
    /// to each other however far the whole set is turned: the open spring stays livelier than
    /// the close, the digits stay dead, and a preset is nothing more than a pair of these.
    struct Tuning: Equatable {
        var duration: Double
        var bounce: Double

        /// How far each can be turned. Below 0.4 a spring is a cut rather than a movement;
        /// above 2 the island takes the better part of a second to settle and reads as
        /// broken. Bounce past 1.5 would put the bubble close to half an undamped
        /// oscillation, which is further than anything should be asked to wobble.
        static let durationRange: ClosedRange<Double> = 0.4...2.0
        static let bounceRange: ClosedRange<Double> = 0...1.5

        /// The same tuning held inside those ranges. A slider cannot be dragged past them, but
        /// a defaults file can be edited to anything, and a number that got in that way is
        /// held here rather than trusted.
        var clamped: Tuning {
            Tuning(duration: min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound),
                   bounce: min(max(bounce, Self.bounceRange.lowerBound), Self.bounceRange.upperBound))
        }
    }

    /// The three tunings worth a name. Picking one writes both numbers, and a pane showing the
    /// numbers can tell which preset, if any, they add up to — so a preset is never a state of
    /// its own that the sliders could disagree with.
    enum Preset: String, CaseIterable, Identifiable {
        /// What ships: the phone's own timing, untouched.
        case faithful
        /// The phone's timing with the overshoot taken out of everything — the "no wobble"
        /// that users of every notch app keep asking for.
        case calm
        /// Half the time and no overshoot: a change of size rather than a journey to it, for
        /// anyone who finds the island slow.
        case instant

        var id: String { rawValue }

        var title: String {
            switch self {
            case .faithful: return "Faithful"
            case .calm: return "Calm"
            case .instant: return "Instant"
            }
        }

        var tuning: Tuning {
            switch self {
            case .faithful: return Tuning(duration: 1, bounce: 1)
            case .calm: return Tuning(duration: 1, bounce: 0)
            case .instant: return Tuning(duration: 0.5, bounce: 0)
            }
        }

        /// The preset a pair of numbers is, if it is one.
        static func matching(_ tuning: Tuning) -> Preset? {
            allCases.first { $0.tuning == tuning }
        }
    }

    /// What the user has set, read live and held within range. Live so that a slider is felt
    /// on the next spring rather than the next launch — which is why no spring below is a
    /// cached `let`.
    static var tuning: Tuning {
        Tuning(duration: Preferences.shared.motionDuration, bounce: Preferences.shared.motionBounce).clamped
    }

    /// The arithmetic on its own: what a spring is given, from its base numbers and the tuning.
    /// Bounce is capped at 1, which SwiftUI takes as undamped oscillation and the most it
    /// accepts. No base bounce times any allowed multiplier gets near it; the cap is there so
    /// that the promise does not rest on the ranges above staying what they are.
    static func scaled(duration: Double, bounce: Double, by tuning: Tuning) -> SpringParameters {
        SpringParameters(duration: duration * tuning.duration, bounce: min(1, bounce * tuning.bounce))
    }

    // MARK: - Springs: things that move

    /// A named spring: its base numbers, which are the phone's, and the length of the fade
    /// that stands in for it under Reduce Motion.
    ///
    /// A table rather than eight literals in eight places, so that the tuning has a single door
    /// to come in through and cannot be forgotten on one curve — and so a test can read the
    /// shipped numbers back and hold them.
    struct Spring: Equatable {
        let base: SpringParameters
        let still: Double

        init(duration: Double, bounce: Double, still: Double) {
            base = SpringParameters(duration: duration, bounce: bounce)
            self.still = still
        }

        /// The island growing — an activity coming out of the notch, a panel opening. The one
        /// curve with real bounce in it, and what makes the shape read as pushed out rather
        /// than resized.
        static let open = Spring(duration: 0.44, bounce: 0.28, still: 0.18)

        /// The island shrinking. No bounce at all: an outline that overshoots on the way back
        /// in reads as a wobble, and the one in the phone never does it.
        static let close = Spring(duration: 0.32, bounce: 0, still: 0.16)

        /// Stepping sideways between views. Almost no bounce, so a run of keypresses reads as
        /// paging rather than as a stack of springs landing on each other.
        static let navigate = Spring(duration: 0.34, bounce: 0.06, still: 0.16)

        /// The detached bubble, the one element allowed to be playful: it pops out on its own,
        /// with nothing else moving, so it can afford the overshoot.
        static let bubble = Spring(duration: 0.42, bounce: 0.32, still: 0.18)

        /// Something arriving in or leaving the island: a shelf tile, a privacy dot, a banner,
        /// a slot in the switcher.
        static let content = Spring(duration: 0.28, bounce: 0.12, still: 0.15)

        /// A number changing where it stands. Rolling digits are movement, so this is a spring
        /// — but a number that overshoots its own value and comes back is a number you cannot
        /// read, so it is the one spring with no bounce in it at all.
        static let digits = Spring(duration: 0.35, bounce: 0, still: 0.15)

        /// A control taking hold — a slider's thumb growing under the pointer, a meter
        /// answering a keypress. Short, and only just springy.
        static let control = Spring(duration: 0.24, bounce: 0.1, still: 0.12)

        /// The release half of a press, the half that springs back. Every button Apple ships
        /// does this, and it is most of why they feel physical.
        static let release = Spring(duration: 0.3, bounce: 0.3, still: 0.12)

        /// Every spring the island has, for a test that wants to hold all of them at once.
        static let all: [Spring] = [open, close, navigate, bubble, content, digits, control, release]
    }

    /// The one door. A spring's numbers go through the tuning, and then through Reduce
    /// Motion, which still wins over everything: a tuned spring under Reduce Motion is the same
    /// fade as an untuned one, because the user who asked the system for less movement did
    /// not ask this pane for more.
    static func spring(_ spring: Spring) -> Animation {
        IslandMotion.spring(spring, tuning: tuning, reduced: reduceMotion)
    }

    /// The same door with both settings handed in, so what comes out of it can be tested.
    static func spring(_ spring: Spring, tuning: Tuning, reduced: Bool) -> Animation {
        let tuned = scaled(duration: spring.base.duration, bounce: spring.base.bounce, by: tuning)
        return moving(.spring(duration: tuned.duration, bounce: tuned.bounce), still: spring.still, reduced: reduced)
    }

    /// The island growing. See `Spring.open`.
    static var open: Animation { spring(.open) }

    /// The island shrinking. See `Spring.close`.
    static var close: Animation { spring(.close) }

    /// Stepping sideways between views. See `Spring.navigate`.
    static var navigate: Animation { spring(.navigate) }

    /// The detached bubble popping out. See `Spring.bubble`.
    static var bubble: Animation { spring(.bubble) }

    /// Something arriving in or leaving the island. See `Spring.content`.
    static var content: Animation { spring(.content) }

    /// A number changing where it stands. See `Spring.digits`.
    static var digits: Animation { spring(.digits) }

    /// A control taking hold. See `Spring.control`.
    static var control: Animation { spring(.control) }

    // MARK: - Eases: things that only change how they look

    /// A highlight coming up under the pointer. Never a spring: hover is a change of colour,
    /// not a movement, and a spring on an alpha ripples.
    static let hover = Animation.easeOut(duration: 0.12)

    /// One thing replacing another where it stands: a line of lyrics, a name, a glyph, a
    /// preview taking over from the section under it.
    static let fade = Animation.easeInOut(duration: 0.18)

    /// Press feedback, which is not symmetric. The press has to land the instant the mouse
    /// goes down or the button feels late; the release is the half that springs back. The
    /// press is an ease and stays out of the tuning: it is not a movement to be slowed, it is
    /// the button acknowledging the click.
    static func press(down: Bool) -> Animation {
        down ? .easeOut(duration: 0.07) : spring(.release)
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
