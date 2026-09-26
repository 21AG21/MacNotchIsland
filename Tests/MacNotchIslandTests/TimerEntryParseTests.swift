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

    private func parse(_ text: String) -> TimerEntry.Typed? {
        TimerEntry.parse(text, now: now, calendar: calendar)
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
        XCTAssertEqual(TimerEntry.parse("6:45", now: late, calendar: calendar), .alarm(at(1, 6, 45, month: 10)))
    }

    func testAFullStopWorksAsTheSeparator() {
        XCTAssertEqual(parse("7.30"), .alarm(at(26, 7, 30)), "the way half of Europe writes a time")
        XCTAssertEqual(parse("19.30"), .alarm(at(25, 19, 30)))
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
                       "7:30xm", "am", "pm", "m", "7:30 pmx", "１２", "٣", "7::30", "007:30"]
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
        XCTAssertNil(TimerEntryField.hint(for: nil, text: "", now: now), "nothing typed, nothing said")
        XCTAssertEqual(TimerEntryField.hint(for: nil, text: "7:", now: now), "Minutes, or a time")
        XCTAssertTrue(TimerEntryField.hint(for: .alarm(at(26, 7, 30)), text: "7:30", now: now)?.hasPrefix("Alarm ") ?? false)
    }


    // MARK: - The same minutes from a script

    /// What the field takes as minutes, a script's `minutes=` takes as the same minutes
    /// (`LiveActivityAPI.length`), and the longest timer either will start is the same day.
    func testAScriptReadsMinutesTheWayTheFieldDoes() {
        for typed in ["5", "25m", "25 min", "90 minutes", "1440"] {
            guard case .minutes(let minutes)? = TimerEntry.parse(typed, now: now, calendar: calendar) else { return XCTFail(typed) }
            XCTAssertEqual(LiveActivityAPI.timerStart(minutes: typed, seconds: nil), TimeInterval(minutes) * 60, typed)
        }
        XCTAssertNil(TimerEntry.typedMinutes("1441"))
        XCTAssertNil(LiveActivityAPI.timerStart(minutes: "1441", seconds: nil))
    }
}
