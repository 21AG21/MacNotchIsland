import Foundation

/// What a few keys typed on the Actions section ask for: a number is a timer of that many
/// minutes, a time on the clock is an alarm for the next time the clock reads it.
///
///   5, 25, 90, 25m, 25 min      a timer, in minutes
///   7:30, 07:30, 19:05, 7.30    an alarm, on the 24-hour clock
///   19h30, 7h                   the same, the French and Portuguese way
///   7:30pm, 7:30 PM, 7pm, 7 a.m. an alarm, on the 12-hour clock
///
/// Any decimal figures will do — a full-width ７ from a Japanese or Chinese input method, an
/// Arabic ٧ — and on a keyboard whose number row types letters without Shift, as a French or a
/// Czech one does, those letters are read as the figures printed on their keys.
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
    ///
    /// `numberRow` is what the keys of the number row type without Shift, where that is not
    /// their figure, mapped back to the figure (`numberRowFold`). A French keyboard types an é
    /// on the 2 and an ( on the 5, and the figures only with Shift, so 25 typed the way the keys
    /// are usually pressed arrived as é(, and the field said it was neither minutes nor a time.
    /// The key that opened the field is read by the figure printed on it the same way
    /// (`HotKeyService.keyRole`), so the first figure and the rest agree. Empty on a layout
    /// whose number row types figures, which is most of them and every American one.
    static func parse(_ text: String, now: Date, calendar: Calendar,
                      numberRow: [Character: Character] = TimerEntry.numberRowOnThisMac) -> Typed? {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmed = String(lowered.map { numberRow[$0] ?? $0 })
        guard !trimmed.isEmpty else { return nil }
        if let minutes = typedMinutes(trimmed) { return .minutes(minutes) }
        guard let time = clockTime(trimmed),
              let date = IslandAlarm.nextFire(hour: time.hour, minute: time.minute, after: now, calendar: calendar) else { return nil }
        return .alarm(date)
    }

    /// Digits, and optionally "m" or "min" after them.
    static func typedMinutes(_ text: String) -> Int? {
        var body = westernFigures(text)
        for suffix in ["minutes", "minute", "mins", "min", "m"] where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard isDigits(body), body.count <= 4, let minutes = Int(body),
              (1...maxTypedMinutes).contains(minutes) else { return nil }
        return minutes
    }

    /// Hours and minutes on the clock, 24-hour unless it ends in am or pm. A bare number is not
    /// a time — it is minutes — unless am or pm says it is: "7pm" is seven in the evening — or
    /// an h does: "7h" is seven in the morning, the way "19h30" is half past seven at night.
    static func clockTime(_ text: String) -> (hour: Int, minute: Int)? {
        var body = westernFigures(text)
        var meridiem: Character?
        let marks: [(suffix: String, mark: Character)] = [("a.m.", "a"), ("p.m.", "p"), ("am", "a"), ("pm", "p"), ("a", "a"), ("p", "p")]
        for (suffix, mark) in marks where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            meridiem = mark
            break
        }
        let hourText: Substring
        let minuteText: Substring?
        if let separator = body.firstIndex(where: { hourSeparators.contains($0) }) {
            hourText = body[..<separator]
            let rest = body[body.index(after: separator)...]
            // "7h" is on the hour, as "7:" is not: an h ends a time where a colon only
            // interrupts one.
            minuteText = body[separator] == "h" && rest.isEmpty ? "00" : rest
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

    /// What goes between the hours and the minutes: a colon, a full stop the way half of
    /// Europe writes a time, or an h the way French and Portuguese do.
    static let hourSeparators: Set<Character> = [":", ".", "h"]

    /// Western digits and nothing else. `Int("")` is nil anyway, but `Int` also takes a sign,
    /// and "-5" is not five minutes of anything. Anything else that is a figure has been made
    /// a Western one by then (`westernFigures`).
    private static func isDigits<S: StringProtocol>(_ text: S) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Every decimal figure as the Western one it stands for, and the full-width colon an input
    /// method types beside full-width figures as a colon.
    ///
    /// Only ASCII figures used to count, so "５" typed with a Japanese or Chinese input method
    /// still on, or "٥" on an Arabic layout, was neither minutes nor a time. Only decimal
    /// figures are folded: a superscript ² or a Roman Ⅻ is a number, not a figure anybody
    /// typed a timer with, and stays what it is.
    static func westernFigures(_ text: String) -> String {
        String(text.map { character -> Character in
            if character == "：" { return ":" }
            guard character.unicodeScalars.count == 1,
                  character.unicodeScalars.first?.properties.numericType == .decimal,
                  let value = character.wholeNumberValue, (0...9).contains(value) else { return character }
            return Character(Unicode.Scalar(UInt8(48 + value)))
        })
    }

    // MARK: - The number row

    /// What the number row types without Shift where that is not its figure, mapped back to
    /// the figure printed on the key: & é and the rest to 1 to 0 on a French keyboard, and
    /// + ě š č ř ž ý á í é on a Czech one; nothing on an American, German or Dvorak one, whose
    /// number row types its figures. `keys` are the row's key codes with their figures, and
    /// `character` what the layout types on each.
    ///
    /// A key that types a figure is left out, and so is one that types something the entry
    /// reads for itself — a letter of "min" or "pm", a separator, a space — so that folding can
    /// only turn what would have been nothing into a number. Pure, so any layout can be put to it.
    static func numberRowFold(keys: [(keyCode: Int, digit: Int)], character: (Int) -> String?) -> [Character: Character] {
        var fold: [Character: Character] = [:]
        for key in keys {
            guard let typed = character(key.keyCode)?.lowercased(), typed.count == 1, let first = typed.first,
                  !first.isNumber, !first.isWhitespace, !(first.isASCII && first.isLetter),
                  !hourSeparators.contains(first), (0...9).contains(key.digit) else { continue }
            fold[first] = Character(Unicode.Scalar(UInt8(48 + key.digit)))
        }
        return fold
    }

    /// The same, for the layout in force, which is how the Actions field reads what is typed
    /// into it. Main thread only, as the layout is; empty from any other, or where the layout
    /// cannot be asked.
    static var numberRowOnThisMac: [Character: Character] {
        let typed = KeyLayout.characters(for: HotKeyService.numberRowKeyCodes)
        // The row runs 1 to 9 and then 0.
        let keys: [(keyCode: Int, digit: Int)] = HotKeyService.numberRowKeyCodes.enumerated().map { index, code in
            (keyCode: code, digit: (index + 1) % 10)
        }
        return numberRowFold(keys: keys, character: { typed[$0] })
    }
}
