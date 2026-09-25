import Foundation

/// What a few keys typed on the Actions section ask for: a number is a timer of that many
/// minutes, a time on the clock is an alarm for the next time the clock reads it.
///
///   5, 25, 90, 25m, 25 min      a timer, in minutes
///   7:30, 07:30, 19:05, 7.30    an alarm, on the 24-hour clock
///   7:30pm, 7:30 PM, 7pm, 7 a.m. an alarm, on the 12-hour clock
///
/// Hung on `TimerEntry`, the timer the minutes turn into; the alarms join it in `IslandTimer`.
/// The URL scheme's `alarm?at=` is read with the same rule, so a script and the keyboard can
/// never disagree about what "7:30" means.
extension TimerEntry {
    enum Typed: Equatable {
        case minutes(Int)
        case alarm(Date)
    }

    /// A day. Anything longer is a typing slip, not a timer.
    static let maxTypedMinutes = 24 * 60

    /// Pure, so it is tested with a fixed clock and calendar. Nil is anything else: the field
    /// stays open and says nothing will happen.
    static func parse(_ text: String, now: Date, calendar: Calendar) -> Typed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let minutes = typedMinutes(trimmed) { return .minutes(minutes) }
        guard let time = clockTime(trimmed),
              let date = IslandAlarm.nextFire(hour: time.hour, minute: time.minute, after: now, calendar: calendar) else { return nil }
        return .alarm(date)
    }

    /// Digits, and optionally "m" or "min" after them.
    static func typedMinutes(_ text: String) -> Int? {
        var body = text
        for suffix in ["minutes", "minute", "mins", "min", "m"] where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard isDigits(body), body.count <= 4, let minutes = Int(body),
              (1...maxTypedMinutes).contains(minutes) else { return nil }
        return minutes
    }

    /// Hours and minutes on the clock, 24-hour unless it ends in am or pm. A bare number is not
    /// a time — it is minutes — unless am or pm says it is: "7pm" is seven in the evening.
    static func clockTime(_ text: String) -> (hour: Int, minute: Int)? {
        var body = text
        var meridiem: Character?
        let marks: [(suffix: String, mark: Character)] = [("a.m.", "a"), ("p.m.", "p"), ("am", "a"), ("pm", "p"), ("a", "a"), ("p", "p")]
        for (suffix, mark) in marks where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            meridiem = mark
            break
        }
        let hourText: Substring
        let minuteText: Substring?
        if let separator = body.firstIndex(where: { $0 == ":" || $0 == "." }) {
            hourText = body[..<separator]
            minuteText = body[body.index(after: separator)...]
        } else {
            hourText = body[...]
            minuteText = nil
        }
        guard isDigits(hourText), hourText.count <= 2, let hour = Int(hourText) else { return nil }
        var minute = 0
        if let minuteText {
            guard isDigits(minuteText), minuteText.count == 2, let m = Int(minuteText), m < 60 else { return nil }
            minute = m
        } else if meridiem == nil {
            return nil
        }
        if let meridiem {
            // Twelve o'clock is the start of its half of the day: 12am is midnight, 12pm noon.
            guard (1...12).contains(hour) else { return nil }
            return (meridiem == "p" ? hour % 12 + 12 : hour % 12, minute)
        }
        guard hour < 24 else { return nil }
        return (hour, minute)
    }

    /// Western digits and nothing else. `Int("")` is nil anyway, but `Int` also takes a sign,
    /// and "-5" is not five minutes of anything.
    private static func isDigits<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
