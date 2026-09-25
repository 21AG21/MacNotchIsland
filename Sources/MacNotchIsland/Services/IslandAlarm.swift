import Foundation

/// An alarm: a time on the clock and a name, waiting in `IslandTimer` until the clock reads it.
///
/// Not a countdown, and not on the island while it waits. An alarm is usually hours away, and
/// a live activity counting down to seven in the morning would hold the island all night over
/// whatever is playing. It waits in a list — the timer row, the menu bar, the island's menu —
/// and when its time comes it becomes a timer that has just rung, and rings the way a timer
/// does: the sound, the card, and a banner when the island cannot be seen.
///
/// It rings only while the Mac is awake. Waking a sleeping Mac at a time of its own choosing
/// is a power-management schedule (`pmset schedule wake`), and that needs root.
struct IslandAlarm: Identifiable, Equatable, Codable {
    let id: String
    var label: String
    var fireDate: Date
    var createdAt: Date

    init(id: String = UUID().uuidString, label: String = IslandAlarm.defaultLabel, fireDate: Date, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.fireDate = fireDate
        self.createdAt = createdAt
    }

    static let defaultLabel = "Alarm"

    /// What the card that says an alarm is set, and the field that sets one, also say.
    static let awakeNote = "It rings only while the Mac is awake: waking a sleeping Mac needs root."

    /// The id the alarm's timer carries once it rings, so it can be told from the countdowns.
    static func ringingID(_ id: String) -> String { "alarm-" + id }

    /// Whether this label is one somebody gave it, rather than the word every alarm wears.
    var hasOwnLabel: Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != Self.defaultLabel
    }

    // MARK: - When

    /// The next moment the clock reads `hour:minute`, strictly after `now`: later today if that
    /// is still to come, tomorrow if it has gone — and tomorrow as well if it is that minute
    /// right now, because the clock has already read it. Where a change to summer time skips
    /// the hour, the first moment after the gap. Pure, so it is tested.
    static func nextFire(hour: Int, minute: Int, after now: Date, calendar: Calendar) -> Date? {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    /// Soonest first, and the older of two set for the same moment first.
    static func sorted(_ alarms: [IslandAlarm]) -> [IslandAlarm] {
        alarms.sorted { a, b in
            if a.fireDate != b.fireDate { return a.fireDate < b.fireDate }
            return a.createdAt < b.createdAt
        }
    }

    /// The alarms sorted into the ones to ring now, the ones whose time went by too long ago to
    /// ring for, and the ones still to come.
    ///
    /// An alarm that came due while the Mac was asleep, or while the app was not running, still
    /// rings when it is noticed if that is within `grace` of its time — a relaunch after an
    /// update, a lid opened a minute late. Any later and ringing would be a lie about what time
    /// it is, so it is reported as missed instead. Pure, so it is tested.
    struct Triage: Equatable {
        var ring: [IslandAlarm] = []
        var missed: [IslandAlarm] = []
        var pending: [IslandAlarm] = []
    }

    static func triage(_ alarms: [IslandAlarm], now: Date, grace: TimeInterval) -> Triage {
        var result = Triage()
        for alarm in sorted(alarms) {
            if alarm.fireDate > now {
                result.pending.append(alarm)
            } else if now.timeIntervalSince(alarm.fireDate) <= grace {
                result.ring.append(alarm)
            } else {
                result.missed.append(alarm)
            }
        }
        return result
    }

    // MARK: - Kept across a relaunch

    /// The list as it is written down: JSON, dates as seconds.
    static func encode(_ alarms: [IslandAlarm]) -> Data? {
        try? JSONEncoder().encode(alarms)
    }

    /// The list read back. Anything unreadable — nothing written yet, a file from a build that
    /// wrote something else — is no alarms, rather than a launch that stops on it.
    static func decode(_ data: Data?) -> [IslandAlarm] {
        guard let data, let alarms = try? JSONDecoder().decode([IslandAlarm].self, from: data) else { return [] }
        return sorted(alarms.filter { !$0.id.isEmpty && $0.fireDate.timeIntervalSinceReferenceDate.isFinite })
    }

    // MARK: - Words

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "7:30 AM" or "07:30", as the Mac's own clock writes a time.
    static func clock(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// "7:30 AM", or "7:30 AM tomorrow" when it is not today — in the Mac's own clock format.
    static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = clock(date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return time + " tomorrow"
        }
        let day = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        return time + ", " + day
    }

    /// How a menu lists it: the time, and the name when it has one of its own.
    func menuTitle(now: Date = Date()) -> String {
        let time = Self.describe(fireDate, now: now)
        return hasOwnLabel ? "\(time) — \(label)" : time
    }
}
