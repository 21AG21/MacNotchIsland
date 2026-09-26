import Carbon.HIToolbox
import XCTest
@testable import MacNotchIsland

/// What a few keys typed on Actions ask for: minutes, or the next time the clock reads a time.
/// Every case runs on a fixed clock in a calendar with no summer time, so "today" and
/// "tomorrow" are the same on every machine that runs this.
final class TimerEntryParseTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Friday 25 September 2026, 10:15:30.
    private var now: Date { at(25, 10, 15, 30) }

    private func at(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    /// Read as on a keyboard whose number row types its figures, so the answer is the same on
    /// every Mac that runs this; the French and Czech rows are put to it below.
    private func parse(_ text: String, numberRow: [Character: Character] = [:]) -> TimerEntry.Typed? {
        TimerEntry.parse(text, now: now, calendar: calendar, numberRow: numberRow)
    }

    // MARK: - Minutes

    func testANumberIsThatManyMinutes() {
        XCTAssertEqual(parse("5"), .minutes(5))
        XCTAssertEqual(parse("25"), .minutes(25))
        XCTAssertEqual(parse("90"), .minutes(90))
        XCTAssertEqual(parse("007"), .minutes(7), "leading zeros are still seven")
        XCTAssertEqual(parse(" 12 "), .minutes(12), "the space either side is not part of it")
    }

    func testMinutesMayBeSaidAsMinutes() {
        XCTAssertEqual(parse("25m"), .minutes(25))
        XCTAssertEqual(parse("25 min"), .minutes(25))
        XCTAssertEqual(parse("5 minutes"), .minutes(5))
        XCTAssertEqual(parse("1 minute"), .minutes(1))
        XCTAssertEqual(parse("45MIN"), .minutes(45))
    }

    func testMinutesAreHeldToADay() {
        XCTAssertEqual(parse("1440"), .minutes(TimerEntry.maxTypedMinutes))
        XCTAssertNil(parse("1441"), "longer than a day is a slip of the finger")
        XCTAssertNil(parse("12345"))
        XCTAssertNil(parse("0"), "no timer is no timer")
        XCTAssertNil(parse("00"))
        XCTAssertNil(parse("0m"))
    }

    // MARK: - The 24-hour clock

    func testATimeStillToComeIsToday() {
        XCTAssertEqual(parse("19:05"), .alarm(at(25, 19, 5)))
        XCTAssertEqual(parse("23:59"), .alarm(at(25, 23, 59)))
        XCTAssertEqual(parse("10:16"), .alarm(at(25, 10, 16)), "the next minute is still today")
    }

    func testATimeThatHasGoneIsTomorrow() {
        XCTAssertEqual(parse("7:30"), .alarm(at(26, 7, 30)))
        XCTAssertEqual(parse("07:30"), .alarm(at(26, 7, 30)), "a leading zero is the same time")
        XCTAssertEqual(parse("0:00"), .alarm(at(26, 0, 0)))
        XCTAssertEqual(parse("00:00"), .alarm(at(26, 0, 0)))
        XCTAssertEqual(parse("10:14"), .alarm(at(26, 10, 14)))
    }

    func testTheMinuteTheClockIsOnIsTomorrow() {
        // It is 10:15:30: the clock has already read 10:15, so the next time it does is tomorrow.
        XCTAssertEqual(parse("10:15"), .alarm(at(26, 10, 15)))
    }

    func testTheWrapCrossesTheEndOfTheMonth() {
        let late = at(30, 23, 0)
        XCTAssertEqual(TimerEntry.parse("6:45", now: late, calendar: calendar, numberRow: [:]), .alarm(at(1, 6, 45, month: 10)))
    }

    func testAFullStopWorksAsTheSeparator() {
        XCTAssertEqual(parse("7.30"), .alarm(at(26, 7, 30)), "the way half of Europe writes a time")
        XCTAssertEqual(parse("19.30"), .alarm(at(25, 19, 30)))
    }

    /// "19h30" is how a time is written in French and Portuguese.
    func testAnHSeparatesTheHoursFromTheMinutes() {
        XCTAssertEqual(parse("19h30"), .alarm(at(25, 19, 30)))
        XCTAssertEqual(parse("7h30"), .alarm(at(26, 7, 30)))
        XCTAssertEqual(parse("19H30"), .alarm(at(25, 19, 30)), "in either case")
        XCTAssertEqual(parse("7h00"), .alarm(at(26, 7, 0)), "on the hour, with its minutes")
        XCTAssertEqual(parse("0h00"), .alarm(at(26, 0, 0)))
        XCTAssertEqual(TimerEntry.clockTime("19h30")?.hour, 19)
        XCTAssertEqual(TimerEntry.clockTime("19h30")?.minute, 30)
        XCTAssertNil(TimerEntry.clockTime("7:"), "a colon still wants its minutes")
        XCTAssertNil(TimerEntry.clockTime("7h"), "and so does an h: on its own it counts hours")
        XCTAssertEqual(parse("7"), .minutes(7), "and a bare number is still minutes")
    }

    /// A bare "2h" is two hours, as it is to `notchctl timer 2h`, and not two in the morning:
    /// the field and the command read the same keys the same way.
    func testABareHourCountIsATimer() {
        XCTAssertEqual(parse("2h"), .minutes(120))
        XCTAssertEqual(parse("7h"), .minutes(7 * 60), "seven hours, not seven o'clock")
        XCTAssertEqual(parse("19h"), .minutes(19 * 60))
        XCTAssertEqual(parse("1 hour"), .minutes(60))
        XCTAssertEqual(parse("2 hours"), .minutes(120))
        XCTAssertEqual(parse("3hrs"), .minutes(180))
        XCTAssertEqual(parse("24h"), .minutes(24 * 60), "a day, the most a typed timer can be")
        XCTAssertNil(parse("25h"), "and no longer")
        XCTAssertNil(parse("0h"))
        XCTAssertNil(parse("7h pm"), "hours have no afternoon")
        XCTAssertEqual(parse("2h", numberRow: ["é": "2"]), .minutes(120))
        XCTAssertEqual(parse("éh", numberRow: ["é": "2"]), .minutes(120), "from a French number row too")
    }

    // MARK: - Figures that are not Western ones

    /// A Japanese or Chinese input method left on types full-width figures, and an Arabic
    /// layout its own; each is the figure it stands for.
    func testAnyDecimalFigureCounts() {
        XCTAssertEqual(parse("１２"), .minutes(12), "full-width")
        XCTAssertEqual(parse("٣"), .minutes(3), "Arabic-Indic")
        XCTAssertEqual(parse("۲۵"), .minutes(25), "Persian")
        XCTAssertEqual(parse("१५"), .minutes(15), "Devanagari")
        XCTAssertEqual(parse("１９：３０"), .alarm(at(25, 19, 30)), "with the full-width colon that comes with them")
        XCTAssertEqual(parse("٧:٣٠pm"), .alarm(at(25, 19, 30)))
        XCTAssertEqual(parse("１９h３０"), .alarm(at(25, 19, 30)))
        XCTAssertEqual(TimerEntry.westernFigures("٠١٢٣٤٥٦٧٨٩"), "0123456789")
        XCTAssertEqual(TimerEntry.westernFigures("²Ⅻ½"), "²Ⅻ½", "numbers that are not figures stay as they are")
        XCTAssertEqual(LiveActivityAPI.alarmDate("１９:３０", now: now, calendar: calendar), at(25, 19, 30),
                       "and a script is read the same way")
    }

    // MARK: - A number row that types letters

    /// The number row's keys with the figures printed on them, as `numberRowFold` is given them.
    private let numberRowKeys: [(keyCode: Int, digit: Int)] =
        HotKeyService.numberRowKeyCodes.enumerated().map { index, code in (keyCode: code, digit: (index + 1) % 10) }

    /// A French keyboard types punctuation and é è ç à on 1 to 0 without Shift. The field opened
    /// on the figure printed on the first key, and everything typed after it was letters.
    func testAFrenchNumberRowIsReadAsItsFigures() {
        let fold = TimerEntry.numberRowFold(keys: numberRowKeys, character: TestLayout.azerty)
        XCTAssertEqual(fold["é"], "2")
        XCTAssertEqual(fold["à"], "0")
        XCTAssertEqual(fold["&"], "1")
        XCTAssertEqual(fold.count, 10)
        XCTAssertEqual(parse("é(", numberRow: fold), .minutes(25), "25, typed without Shift")
        XCTAssertEqual(parse("2(", numberRow: fold), .minutes(25), "the first figure from the key that opened the field")
        XCTAssertEqual(parse("&ç:\"à", numberRow: fold), .alarm(at(25, 19, 30)))
        XCTAssertEqual(parse("&çh\"à", numberRow: fold), .alarm(at(25, 19, 30)))
        XCTAssertEqual(parse("25", numberRow: fold), .minutes(25), "and Shift's figures are figures")
        XCTAssertNil(parse("é("), "not on a keyboard that types figures there")
    }

    func testACzechNumberRowIsReadAsItsFigures() {
        let czech: (Int) -> String? = { code in
            let row = ["+", "ě", "š", "č", "ř", "ž", "ý", "á", "í", "é"]
            return HotKeyService.numberRowKeyCodes.firstIndex(of: code).map { row[$0] }
        }
        let fold = TimerEntry.numberRowFold(keys: numberRowKeys, character: czech)
        XCTAssertEqual(parse("řé", numberRow: fold), .minutes(50))
        XCTAssertEqual(parse("+ž:šé", numberRow: fold), .alarm(at(25, 16, 30)))
    }

    func testANumberRowThatTypesFiguresFoldsNothing() {
        XCTAssertTrue(TimerEntry.numberRowFold(keys: numberRowKeys, character: TestLayout.us).isEmpty)
        XCTAssertTrue(TimerEntry.numberRowFold(keys: numberRowKeys, character: TestLayout.german).isEmpty)
        XCTAssertTrue(TimerEntry.numberRowFold(keys: numberRowKeys, character: TestLayout.dvorak).isEmpty)
        XCTAssertTrue(TimerEntry.numberRowFold(keys: numberRowKeys, character: TestLayout.unknown).isEmpty)
        // A key that types something the entry reads for itself keeps it: an m is minutes,
        // an h or a colon a time, whatever key it is on.
        let odd: (Int) -> String? = { code in
            [kVK_ANSI_1: "m", kVK_ANSI_2: "h", kVK_ANSI_3: ":", kVK_ANSI_4: ".", kVK_ANSI_5: " ", kVK_ANSI_6: "٦"][code]
        }
        XCTAssertTrue(TimerEntry.numberRowFold(keys: numberRowKeys, character: odd).isEmpty)
    }

    // MARK: - Morning and afternoon

    func testPMIsTheAfternoon() {
        XCTAssertEqual(parse("7:30pm"), .alarm(at(25, 19, 30)))
        XCTAssertEqual(parse("7:30 PM"), .alarm(at(25, 19, 30)))
        XCTAssertEqual(parse("7:30 p.m."), .alarm(at(25, 19, 30)))
        XCTAssertEqual(parse("7:30p"), .alarm(at(25, 19, 30)))
        XCTAssertEqual(parse("11:59pm"), .alarm(at(25, 23, 59)))
    }

    func testAMIsTheMorning() {
        XCTAssertEqual(parse("7:30am"), .alarm(at(26, 7, 30)))
        XCTAssertEqual(parse("7:30 A.M."), .alarm(at(26, 7, 30)))
        XCTAssertEqual(parse("11am"), .alarm(at(25, 11, 0)), "eleven this morning has not come yet")
        XCTAssertEqual(parse("9a"), .alarm(at(26, 9, 0)))
    }

    func testAnHourAloneIsATimeOnlyWithAMOrPM() {
        XCTAssertEqual(parse("7pm"), .alarm(at(25, 19, 0)))
        XCTAssertEqual(parse("7 pm"), .alarm(at(25, 19, 0)))
        XCTAssertEqual(parse("7"), .minutes(7), "without it, a bare number is minutes")
    }

    func testTwelveIsTheStartOfItsHalfOfTheDay() {
        XCTAssertEqual(parse("12am"), .alarm(at(26, 0, 0)), "midnight")
        XCTAssertEqual(parse("12:30am"), .alarm(at(26, 0, 30)))
        XCTAssertEqual(parse("12pm"), .alarm(at(25, 12, 0)), "noon")
        XCTAssertEqual(parse("12:45pm"), .alarm(at(25, 12, 45)))
    }

    // MARK: - Nothing

    func testGarbageIsNothing() {
        let garbage = ["", " ", "abc", "seven", "7:", ":30", "7:3", "7:300", "7:60", "24:00", "25:00",
                       "13pm", "0am", "0:30am", "13:00pm", "7:30:00", "7 30", "1e3", "-5", "+5", "5.5",
                       "7:30xm", "am", "pm", "m", "7:30 pmx", "7::30", "007:30", "²", "Ⅻ", "7h3", "7h60", "0h",
                       "h30", "h", "7.", "25h", "7h pm", "é"]
        for text in garbage {
            XCTAssertNil(parse(text), "\"\(text)\" is neither minutes nor a time")
        }
    }

    // MARK: - The pieces

    func testTheClockReaderAlone() {
        XCTAssertEqual(TimerEntry.clockTime("7:30")?.hour, 7)
        XCTAssertEqual(TimerEntry.clockTime("7:30")?.minute, 30)
        XCTAssertEqual(TimerEntry.clockTime("7:30pm")?.hour, 19)
        XCTAssertEqual(TimerEntry.clockTime("12am")?.hour, 0)
        XCTAssertNil(TimerEntry.clockTime("7"), "a bare number is not a time")
    }

    func testTheURLSchemeReadsTimesTheSameWay() {
        XCTAssertEqual(LiveActivityAPI.alarmDate("07:30", now: now, calendar: calendar), at(26, 7, 30))
        XCTAssertEqual(LiveActivityAPI.alarmDate("7:30pm", now: now, calendar: calendar), at(25, 19, 30))
        XCTAssertNil(LiveActivityAPI.alarmDate("5", now: now, calendar: calendar), "minutes are not an alarm")
        XCTAssertNil(LiveActivityAPI.alarmDate("soon", now: now, calendar: calendar))
        XCTAssertNil(LiveActivityAPI.alarmDate(nil, now: now, calendar: calendar))
    }

    // MARK: - What the field says Return would do

    func testTheFieldSaysWhatReturnWouldStart() {
        XCTAssertEqual(TimerEntryField.hint(for: .minutes(5), text: "5", now: now), "5 min timer")
        XCTAssertEqual(TimerEntryField.hint(for: .minutes(120), text: "2h", now: now), "2 h timer", "whole hours in hours")
        XCTAssertEqual(TimerEntryField.hint(for: .minutes(60), text: "60", now: now), "1 h timer")
        XCTAssertEqual(TimerEntryField.hint(for: .minutes(90), text: "90", now: now), "1 h 30 min timer")
        XCTAssertEqual(TimerEntryField.hint(for: .minutes(59), text: "59", now: now), "59 min timer")
        XCTAssertNil(TimerEntryField.hint(for: nil, text: "", now: now), "nothing typed, nothing said")
        XCTAssertEqual(TimerEntryField.hint(for: nil, text: "7:", now: now), "Minutes, or a time")
        XCTAssertTrue(TimerEntryField.hint(for: .alarm(at(26, 7, 30)), text: "7:30", now: now)?.hasPrefix("Alarm ") ?? false)
    }


    // MARK: - The same minutes from a script

    /// What the field takes as minutes, a script's `minutes=` takes as the same minutes
    /// (`LiveActivityAPI.length`), and the longest timer either will start is the same day.
    func testAScriptReadsMinutesTheWayTheFieldDoes() {
        for typed in ["5", "25m", "25 min", "90 minutes", "1440"] {
            guard case .minutes(let minutes)? = parse(typed) else { return XCTFail(typed) }
            XCTAssertEqual(LiveActivityAPI.timerStart(minutes: typed, seconds: nil), TimeInterval(minutes) * 60, typed)
        }
        XCTAssertNil(TimerEntry.typedMinutes("1441"))
        XCTAssertNil(LiveActivityAPI.timerStart(minutes: "1441", seconds: nil))
    }
}
