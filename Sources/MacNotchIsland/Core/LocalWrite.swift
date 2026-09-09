import Foundation

/// "Did the island itself set this a moment ago?"
///
/// Both the volume and the brightness paths ask it before deciding whether to put a display
/// up. A slider you are holding is already telling you what it is doing, and a banner over it
/// says nothing you cannot see — but only for the change that slider made. Asking instead
/// whether *any* control anywhere was being dragged caught the music scrubber too, and
/// swallowed displays that had nothing to do with it.
enum LocalWrite {
    /// Long enough to cover a drag's stream of writes, short enough that the next thing the
    /// user does from somewhere else is answered.
    static let window: TimeInterval = 0.6

    static func isRecent(_ stamp: Date, within seconds: TimeInterval = window, now: Date = Date()) -> Bool {
        now.timeIntervalSince(stamp) < seconds
    }
}
