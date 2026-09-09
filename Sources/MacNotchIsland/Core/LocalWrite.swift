import Foundation

/// "Did the island itself set this a moment ago?"
///
/// Both the volume and the brightness paths ask it before deciding whether to put a display
/// up. A slider you are holding is already telling you what it is doing, and a banner over it
/// says nothing you cannot see — but only for the change that slider made. Asking instead
/// whether *any* control anywhere was being dragged caught the music scrubber too, and
/// swallowed displays that had nothing to do with it.
///
/// Measured on the clock that only counts forwards, not on the wall clock. This is a duration
/// — how long ago — and the wall clock is a poor way to keep one: an NTP correction or a wake
/// with a bad real-time clock steps it, and a stamp that lands in the future then reads as
/// "just now" for as long as the offset lasts, silencing every display until it catches up.
/// Guarding against that with a lower bound only turns the same step into the opposite fault.
/// A monotonic source has neither.
enum LocalWrite {
    /// Long enough to cover a drag's stream of writes, short enough that the next thing the
    /// user does from somewhere else is answered.
    static let window: TimeInterval = 0.6

    /// The reading to store when something is written, and to compare against later.
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Nothing has ever been written.
    static let never: TimeInterval = -.greatestFiniteMagnitude

    static func isRecent(_ stamp: TimeInterval, within seconds: TimeInterval = window,
                         now: TimeInterval = LocalWrite.now()) -> Bool {
        now - stamp < seconds
    }
}
