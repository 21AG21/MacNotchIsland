import SwiftUI

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 3
    var tint: Color = .white
    /// How the ring travels to a new value. A timer's arrives on a one-second clock, and
    /// sweeping for exactly that long is what makes a ring redrawn once a second read as one
    /// that never stops moving — but a download's arrives whenever the poll happens to be,
    /// and a live activity's whenever it is pushed, and for those a spring that lands is
    /// right. Linear everywhere would leave those two permanently a second behind. Nil steps
    /// straight to the value: see `TimerRing`, for a step too small to be worth a sweep.
    var animation: Animation? = IslandMotion.control
    /// The timer the ring measures, when it measures one. Its state changes only when
    /// something other than the clock moves the ring — a minute added, a timer repeated, the
    /// next Pomodoro phase — and that move gets the control spring even when the clock's
    /// steps get nothing, because it is a move the user made, or is told about, and it can be
    /// several points: stepped, it would read as a glitch. A tick never changes it.
    var timer: TimerState? = nil

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        // The modifier nearer the view has the last word on the transaction, so when the timer
        // itself changed its spring is what the ring gets, whatever the step would have had.
        .animation(IslandMotion.control, value: timer)
        .animation(animation, value: progress)
    }
}

/// A timer's ring, drawn from inside the `TimelineView` that redraws it once a second.
///
/// The one place the ring's size and the timer's length meet, which is what it takes to know
/// how far the ring's end moves in a step, and so whether that step is worth sweeping — see
/// `IslandMotion.meter(cadence:travel:paused:)`. The size is the frame it sets for itself, so
/// the figure it works from cannot drift from the ring that is drawn.
struct TimerRing: View {
    let state: TimerState
    /// The timeline's date, which is what the ring's value is read at.
    let date: Date
    let diameter: CGFloat
    var lineWidth: CGFloat = 2.5
    @ObservedObject private var energy = EnergyPolicy.shared

    /// The clock every timer's timeline ticks on.
    static let cadence: Double = 1

    var body: some View {
        ProgressRing(progress: state.isFinished ? 1 : state.progress(at: date), lineWidth: lineWidth, tint: .orange,
                     animation: Self.curve(for: state, diameter: diameter, paused: energy.animationsPaused),
                     timer: state)
            .frame(width: diameter, height: diameter)
    }

    /// How far the end of a ring `diameter` across moves in one tick of `state`'s clock. A
    /// timer that is paused, or has rung, is not moving at all.
    static func travel(for state: TimerState, diameter: CGFloat, cadence: Double = TimerRing.cadence) -> CGFloat {
        guard !state.isPaused, !state.isFinished, state.total > 0 else { return 0 }
        return IslandMotion.meterTravel(diameter: diameter, share: cadence / state.total)
    }

    /// The curve each tick of the ring gets: the meter's sweep when the step can be seen, and
    /// nothing when it cannot, or when animation is paused or Reduce Motion is on. Pure, with
    /// both settings handed in, so the choice is tested.
    static func curve(for state: TimerState, diameter: CGFloat, paused: Bool,
                      reduced: Bool = IslandMotion.reduceMotion) -> Animation? {
        IslandMotion.meter(cadence: cadence, travel: travel(for: state, diameter: diameter),
                           paused: paused, reduced: reduced)
    }
}
