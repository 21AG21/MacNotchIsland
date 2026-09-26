import AppKit

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

    // MARK: - Said out loud

    /// Has VoiceOver say `text` now, wherever the user is: for something the island shows for a
    /// moment and takes away again — "Text copied" in place of a file name — which a screen
    /// reader never lands on in time, or at all.
    ///
    /// Only while VoiceOver is running, and on the main thread whichever thread asks. `high` is
    /// said over whatever VoiceOver is in the middle of; medium waits its turn.
    static func announce(_ text: String, high: Bool = true) {
        let post: () -> Void = {
            guard NSWorkspace.shared.isVoiceOverEnabled, let app = NSApp else { return }
            NSAccessibility.post(element: app, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: Self.announcementPriority(high: high).rawValue])
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    /// How urgently an announcement is made. Pure, so the choice is tested.
    static func announcementPriority(high: Bool) -> NSAccessibilityPriorityLevel {
        high ? .high : .medium
    }

    /// A line drawn with "·" between its facts, as it should be said: VoiceOver reads the
    /// separator out as a symbol of its own, so each one becomes the pause a comma makes.
    static func spokenLine(_ line: String) -> String {
        line.replacingOccurrences(of: " · ", with: ", ")
    }
}
