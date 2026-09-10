import SwiftUI

/// A slim capsule slider for the control rail: 4 pt at rest, 7 pt under the pointer, drag or
/// click anywhere on it. The value is written on every change and the caller decides what
/// that means (volume, brightness).
///
/// Two things make it feel like a system slider rather than a rectangle that reads a mouse:
///
/// - **What the user asked for wins.** The system takes a moment to report a new volume, and
///   the report that comes back mid-drag is the *old* value. Following it would drag the fill
///   backwards under the finger. So while the pointer is down, and for a moment after it
///   lifts, the slider shows the value the user set and ignores what is fed back to it; the
///   feed takes over again as soon as it agrees, or after `settleWindow`.
/// - **The panel stays open.** A drag may run past either end of the track and off the island
///   entirely. The island is told a control is being dragged, so nothing closes under the
///   pointer until the button comes up.
struct IslandSlider: View {
    var value: Double
    var onChange: (Double) -> Void
    /// Called once when the drag begins, before the first value: the volume slider unmutes here.
    var onBegin: (() -> Void)? = nil

    @State private var hovering = false
    @State private var dragging = false
    /// The value the user set, held against stale reports; see the note above.
    @State private var held: Double?
    @State private var releaseWork: DispatchWorkItem?

    /// How long a released slider keeps showing the value the user set before it trusts the
    /// feed again. Long enough for CoreAudio or DisplayServices to report back, short enough
    /// that a value changed elsewhere is never stuck on screen.
    static let settleWindow: TimeInterval = 0.7
    /// A report this close to what the user asked for is the same value: the feed has caught up.
    static let agreement: Double = 0.02
    /// One press of VoiceOver's increment or decrement. The volume keys move the Mac in
    /// sixteenths and a scroll on the island follows them, so a slider that moved by some
    /// number of its own would leave the same control answering to two ideas of a notch.
    static let adjustStep: Double = GestureRouter.keyStep

    private var shown: Double { min(1, max(0, held ?? value)) }
    private var active: Bool { hovering || dragging }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(Color.white.opacity(active ? 0.95 : 0.85))
                    .frame(width: max(0, geo.size.width * shown))
            }
            .frame(height: active ? 7 : 4)
            .frame(maxHeight: .infinity, alignment: .center)
            // The whole 20 pt row takes the click, not just the 4 pt of track in the middle.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging { begin() }
                        set(fraction(of: drag.location.x, in: geo.size.width))
                    }
                    .onEnded { drag in
                        set(fraction(of: drag.location.x, in: geo.size.width))
                        end()
                    }
            )
            .animation(IslandMotion.control, value: active)
            // Follow the feed again as soon as it agrees with what the user asked for.
            .onChange(of: value) { _, new in
                guard !dragging, let held, abs(new - held) < Self.agreement else { return }
                self.held = nil
                releaseWork?.cancel()
                releaseWork = nil
            }
        }
        .frame(height: 20)
        .onHover { hovering = $0 }
        // The track is drawn from shapes, which say nothing to a screen reader, and the rail
        // hangs the label and the value on this view from outside; one element is what both
        // of those need. The adjustable trait comes with the action below.
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(up: true)
            case .decrement: adjust(up: false)
            default: break
            }
        }
        .onDisappear {
            releaseWork?.cancel()
            releaseWork = nil
            // Never leave the island believing a drag is still in flight.
            if dragging { ActivityCenter.shared.setControlDragging(false) }
            dragging = false
            held = nil
        }
    }

    private func fraction(of x: CGFloat, in width: CGFloat) -> Double {
        min(1, max(0, Double(x / max(1, width))))
    }

    private func begin() {
        dragging = true
        releaseWork?.cancel()
        releaseWork = nil
        ActivityCenter.shared.setControlDragging(true)
        onBegin?()
    }

    private func set(_ value: Double) {
        held = value
        onChange(value)
    }

    private func end() {
        dragging = false
        ActivityCenter.shared.setControlDragging(false)
        settle()
    }

    /// A pointer that has lifted and a key that has been pressed are both "the user has
    /// finished asking for this value", and both have to hold it against the feed for the
    /// same moment afterwards; see the note at the top.
    private func settle() {
        releaseWork?.cancel()
        let work = DispatchWorkItem { self.held = nil }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleWindow, execute: work)
    }

    /// A press of VoiceOver's increment or decrement, which is a drag by another name: the
    /// same unmute at the start, the same value out through the same callback, and the same
    /// moment of holding it afterwards. Without this the volume and the brightness can only
    /// be set by somebody holding a pointer.
    private func adjust(up: Bool) {
        onBegin?()
        // From what is on screen, not from the feed: two presses in quick succession must
        // move twice, and the second one comes before the Mac has reported the first.
        set(Self.stepped(from: shown, up: up))
        settle()
    }

    /// Where a press lands. Kept pure so it can be checked without a screen: the ends are
    /// where a slider goes wrong, and a press at either one has to stop there rather than
    /// write a level that is off the track.
    static func stepped(from value: Double, up: Bool) -> Double {
        min(1, max(0, value + (up ? adjustStep : -adjustStep)))
    }
}
