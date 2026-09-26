import Foundation

/// Durations spelled out for VoiceOver.
///
/// The island shows "4:12" and "01:05.3", which a screen reader would announce as a clock
/// time or a bare number; the expanded call, timer and stopwatch rows speak the same value
/// as "4 minutes 12 seconds" instead.
extension IslandAccessibility {
    /// "1 hour 2 minutes 5 seconds", "4 minutes 12 seconds", "1 minute", "0 seconds".
    ///
    /// Fractions are dropped, so hand a countdown its already rounded-up remainder (the
    /// same value `timerString` shows) rather than the raw interval.
    ///
    /// Held to what the clock shows (`TimeInterval.clockLimit`) before it becomes an `Int`, the
    /// way `wholeSeconds` is: `Int(Double)` traps past `Int.max`, and a timer a URL started for
    /// 1e300 minutes brought the app down the moment VoiceOver, or the pointer, reached its card.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0 seconds" }
        let total = Int(max(0, min(seconds, TimeInterval.clockLimit)).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if secs > 0 || parts.isEmpty { parts.append(unit(secs, "second")) }
        return parts.joined(separator: " ")
    }

    private static func unit(_ count: Int, _ name: String) -> String {
        count == 1 ? "1 \(name)" : "\(count) \(name)s"
    }
}
