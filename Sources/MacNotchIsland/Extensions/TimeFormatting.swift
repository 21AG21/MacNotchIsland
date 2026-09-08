import Foundation

extension TimeInterval {
    /// 3:07 / 1:02:09 — floors to the second (playback position, call duration).
    var mmss: String { Self.clock(wholeSeconds(.down)) }

    /// Countdown formatting that rounds up so a 5:00 timer starts at 5:00, not 4:59.
    var timerString: String { Self.clock(wholeSeconds(.up)) }

    /// The longest interval the clock shows: 99:59:59.
    static let clockLimit: TimeInterval = 359_999

    /// Whole seconds for display. `Int(Double)` traps on anything infinite, NaN or beyond
    /// Int's range, and a player can report any of those for a live stream or a track it has
    /// not measured yet, so the value is made finite and clamped before it is converted.
    private func wholeSeconds(_ rule: FloatingPointRoundingRule) -> Int {
        guard isFinite else { return 0 }
        return Int(max(0, min(self, Self.clockLimit)).rounded(rule))
    }

    private static func clock(_ t: Int) -> String {
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
