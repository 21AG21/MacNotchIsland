import XCTest
@testable import MacNotchIsland

/// Alarms: when the next one is, which ones ring, and that they are still there after a
/// relaunch. The timer's own store is pointed at a scratch suite for the whole class, so
/// nothing here touches the defaults of whoever runs it.
final class AlarmTests: XCTestCase {
    private var timer: IslandTimer { IslandTimer.shared }
    private var center: ActivityCenter { ActivityCenter.shared }
    private var suiteName = ""
    private var defaults: UserDefaults!

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0, month: Int = 9, in calendar: Calendar? = nil) -> Date {
        (calendar ?? utc).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    override func setUp() {
        super.setUp()
        suiteName = "MacNotchIslandTests.alarms.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        timer.alarmDefaults = defaults
        timer.cancelAll()
        timer.cancelAllAlarms()
        center.resetForTesting()
    }

    override func tearDown() {
        timer.cancelAll()
        timer.cancelAllAlarms()
        center.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        timer.alarmDefaults = .standard
        super.tearDown()
    }

    // MARK: - The next time the clock reads it

    func testLaterTodayIsToday() {
        XCTAssertEqual(IslandAlarm.nextFire(hour: 7, minute: 30, after: at(25, 6, 0), calendar: utc), at(25, 7, 30))
        XCTAssertEqual(IslandAlarm.nextFire(hour: 7, minute: 30, after: at(25, 7, 29, 59), calendar: utc), at(25, 7, 30))
    }

    func testGoneIsTomorrow() {
        XCTAssertEqual(IslandAlarm.nextFire(hour: 7, minute: 30, after: at(25, 8, 0), calendar: utc), at(26, 7, 30))
        XCTAssertEqual(IslandAlarm.nextFire(hour: 7, minute: 30, after: at(25, 7, 30), calendar: utc), at(26, 7, 30),
                       "the very moment it names has been read already")
        XCTAssertEqual(IslandAlarm.nextFire(hour: 0, minute: 0, after: at(25, 23, 59, 59), calendar: utc), at(26, 0, 0))
    }

    func testTheWrapCrossesMonthsAndYears() {
        XCTAssertEqual(IslandAlarm.nextFire(hour: 0, minute: 30, after: at(30, 23, 0), calendar: utc), at(1, 0, 30, month: 10))
        let newYearsEve = utc.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 22, minute: 0))!
        let newYear = utc.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 6, minute: 0))!
        XCTAssertEqual(IslandAlarm.nextFire(hour: 6, minute: 0, after: newYearsEve, calendar: utc), newYear)
    }

    func testATimeThatIsNotOnTheClockIsNothing() {
        XCTAssertNil(IslandAlarm.nextFire(hour: 24, minute: 0, after: at(25, 6, 0), calendar: utc))
        XCTAssertNil(IslandAlarm.nextFire(hour: 7, minute: 60, after: at(25, 6, 0), calendar: utc))
        XCTAssertNil(IslandAlarm.nextFire(hour: -1, minute: 0, after: at(25, 6, 0), calendar: utc))
    }

    func testAnHourThatSummerTimeSkipsStillGivesATimeThatDay() {
        // 8 March 2026: New York goes from 01:59:59 straight to 03:00, so 02:30 never happens.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let before = at(8, 1, 0, month: 3, in: newYork)
        guard let fire = IslandAlarm.nextFire(hour: 2, minute: 30, after: before, calendar: newYork) else {
            return XCTFail("a skipped hour still rings, at the first moment after it")
        }
        XCTAssertGreaterThan(fire, before)
        XCTAssertLessThanOrEqual(fire.timeIntervalSince(before), 3 * 3600)
        XCTAssertEqual(newYork.component(.day, from: fire), 8)
    }

    // MARK: - Which ones ring

    func testTriageRingsTheDueMissesTheStaleAndKeepsTheRest() {
        let now = at(25, 7, 30)
        let stale = IslandAlarm(label: "Stale", fireDate: now.addingTimeInterval(-IslandTimer.missedGrace - 60))
        let late = IslandAlarm(label: "Late", fireDate: now.addingTimeInterval(-120))
        let onTime = IslandAlarm(label: "On time", fireDate: now)
        let later = IslandAlarm(label: "Later", fireDate: now.addingTimeInterval(3600))
        let soon = IslandAlarm(label: "Soon", fireDate: now.addingTimeInterval(60))
        let due = IslandAlarm.triage([later, onTime, stale, soon, late], now: now, grace: IslandTimer.missedGrace)
        XCTAssertEqual(due.ring.map(\.label), ["Late", "On time"], "soonest first")
        XCTAssertEqual(due.missed.map(\.label), ["Stale"])
        XCTAssertEqual(due.pending.map(\.label), ["Soon", "Later"])
    }

    func testAnAlarmExactlyAtTheGraceStillRings() {
        let now = at(25, 7, 40)
        let edge = IslandAlarm(fireDate: now.addingTimeInterval(-IslandTimer.missedGrace))
        XCTAssertEqual(IslandAlarm.triage([edge], now: now, grace: IslandTimer.missedGrace).ring, [edge])
    }

    // MARK: - Written down

    func testTheListSurvivesBeingWrittenDown() {
        let alarms = [
            IslandAlarm(id: "a", label: "Wake", fireDate: at(26, 7, 30), createdAt: at(25, 22, 0)),
            IslandAlarm(id: "b", label: IslandAlarm.defaultLabel, fireDate: at(26, 9, 0, 30), createdAt: at(25, 22, 1)),
        ]
        let data = IslandAlarm.encode(alarms)
        XCTAssertNotNil(data)
        XCTAssertEqual(IslandAlarm.decode(data), alarms)
    }

    func testAnUnreadableListIsNoAlarms() {
        XCTAssertEqual(IslandAlarm.decode(nil), [])
        XCTAssertEqual(IslandAlarm.decode(Data("not json".utf8)), [])
        XCTAssertEqual(IslandAlarm.decode(Data("{\"id\":1}".utf8)), [])
    }

    func testSettingAnAlarmWritesItDown() {
        let now = Date()
        guard let alarm = timer.setAlarm(at: now.addingTimeInterval(3600), label: "Wake", announce: false, now: now) else {
            return XCTFail("an hour from now is still to come")
        }
        XCTAssertEqual(timer.alarms, [alarm])
        let written = IslandAlarm.decode(defaults.data(forKey: IslandTimer.alarmsKey))
        XCTAssertEqual(written.map(\.id), [alarm.id])
        XCTAssertEqual(written.first?.label, "Wake")
        XCTAssertEqual(written.first?.fireDate.timeIntervalSince1970 ?? 0, alarm.fireDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAlarmsComeBackAfterARelaunch() {
        let now = Date()
        let first = timer.setAlarm(at: now.addingTimeInterval(7200), label: "Train", announce: false, now: now)
        let second = timer.setAlarm(at: now.addingTimeInterval(3600), announce: false, now: now)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)

        timer.forgetAlarmsForTesting()
        XCTAssertTrue(timer.alarms.isEmpty, "the app has quit")

        timer.restoreAlarms(now: now)
        XCTAssertEqual(timer.alarms.map(\.id), [second?.id, first?.id].compactMap { $0 }, "soonest first, as they were")
        XCTAssertEqual(timer.alarms.last?.label, "Train")
        XCTAssertEqual(timer.alarms.first?.label, IslandAlarm.defaultLabel)
    }

    func testARestoreKeepsAnAlarmSetBeforeIt() {
        let now = Date()
        let saved = timer.setAlarm(at: now.addingTimeInterval(3600), label: "Saved", announce: false, now: now)
        timer.forgetAlarmsForTesting()
        // A URL that sets one before launch has read the list back must not write over it.
        let early = timer.setAlarm(at: now.addingTimeInterval(1800), label: "Early", announce: false, now: now)
        timer.restoreAlarms(now: now)
        XCTAssertEqual(Set(timer.alarms.map(\.id)), Set([saved?.id, early?.id].compactMap { $0 }))
    }

    func testAnAlarmLongGoneAtLaunchIsNotRungButReported() {
        let now = Date()
        let old = IslandAlarm(label: "Yesterday", fireDate: now.addingTimeInterval(-3 * 3600))
        defaults.set(IslandAlarm.encode([old]), forKey: IslandTimer.alarmsKey)
        timer.forgetAlarmsForTesting()
        timer.restoreAlarms(now: now)
        XCTAssertTrue(timer.alarms.isEmpty)
        XCTAssertTrue(timer.timers.isEmpty, "ringing three hours late would be a lie about the time")
        XCTAssertEqual(center.alert?.id, IslandTimer.alarmMissedAlertID)
        XCTAssertEqual(IslandAlarm.decode(defaults.data(forKey: IslandTimer.alarmsKey)), [], "and it is gone from the list")
    }

    func testATimeThatHasGoneIsNotAnAlarm() {
        let now = Date()
        XCTAssertNil(timer.setAlarm(at: now.addingTimeInterval(-1), announce: false, now: now))
        XCTAssertTrue(timer.alarms.isEmpty)
    }

    // MARK: - Ringing

    func testADueAlarmRingsAsATimerThatHasRung() {
        let now = Date()
        guard let alarm = timer.setAlarm(at: now.addingTimeInterval(60), label: "Tea", announce: false, now: now) else {
            return XCTFail("no alarm")
        }
        timer.checkAlarms(now: now.addingTimeInterval(61))
        XCTAssertTrue(timer.alarms.isEmpty, "it is not waiting any more")
        guard let ringing = timer.entry(id: IslandAlarm.ringingID(alarm.id)) else { return XCTFail("it rings as a timer") }
        XCTAssertTrue(ringing.state.isFinished)
        XCTAssertTrue(ringing.state.isAlarm)
        XCTAssertEqual(ringing.state.alarmAt, alarm.fireDate)
        XCTAssertEqual(ringing.label, "Tea")
        XCTAssertNotNil(center.activity(id: ringing.id), "with its own card, the way a timer rings")
        XCTAssertEqual(TimerExpandedView.headline(for: ringing.state), "Tea", "an alarm is going off, not done")
    }

    func testSnoozeGivesNineMinutes() {
        let now = Date()
        guard let alarm = timer.setAlarm(at: now.addingTimeInterval(60), label: "Wake", announce: false, now: now) else {
            return XCTFail("no alarm")
        }
        timer.checkAlarms(now: now.addingTimeInterval(60))
        let ringingID = IslandAlarm.ringingID(alarm.id)
        timer.snooze(id: ringingID)
        XCTAssertNil(timer.entry(id: ringingID), "the ringing stops")
        XCTAssertEqual(timer.alarms.count, 1)
        XCTAssertEqual(timer.alarms.first?.label, "Wake")
        XCTAssertEqual(timer.alarms.first?.fireDate.timeIntervalSinceNow ?? 0, IslandTimer.snoozeInterval, accuracy: 5)
    }

    func testCancellingTakesItOffTheListAndTheDisk() {
        let now = Date()
        let keep = timer.setAlarm(at: now.addingTimeInterval(7200), label: "Keep", announce: false, now: now)
        guard let drop = timer.setAlarm(at: now.addingTimeInterval(3600), label: "Drop", announce: false, now: now) else {
            return XCTFail("no alarm")
        }
        timer.cancelAlarm(id: drop.id)
        XCTAssertEqual(timer.alarms.map(\.label), ["Keep"])
        XCTAssertEqual(IslandAlarm.decode(defaults.data(forKey: IslandTimer.alarmsKey)).map(\.id), [keep?.id].compactMap { $0 })
    }

    func testSettingOneSaysSoAndOffersToTakeItBack() {
        let now = Date()
        guard let alarm = timer.setAlarm(at: now.addingTimeInterval(3600), now: now) else { return XCTFail("no alarm") }
        guard let shown = center.alert, case .custom(let card) = shown.content else { return XCTFail("the card that says so") }
        XCTAssertEqual(shown.id, IslandTimer.alarmSetAlertID)
        XCTAssertEqual(card.body, IslandAlarm.awakeNote, "and that the Mac has to be awake for it")
        XCTAssertEqual(card.actions.first?.command, .cancelAlarm(id: alarm.id))
        card.actions.first?.command?.perform()
        XCTAssertTrue(timer.alarms.isEmpty)
    }

    // MARK: - From a script

    func testTheURLSetsAnAlarmForTheNextTimeTheClockReadsIt() {
        LiveActivityAPI.shared.handle(URL(string: "notchisland://alarm?at=07:30&label=Wake")!)
        guard let alarm = timer.alarms.first else { return XCTFail("the alarm was not set") }
        XCTAssertEqual(alarm.label, "Wake")
        let parts = Calendar.current.dateComponents([.hour, .minute], from: alarm.fireDate)
        XCTAssertEqual(parts.hour, 7)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertGreaterThan(alarm.fireDate, Date())
        XCTAssertLessThanOrEqual(alarm.fireDate.timeIntervalSinceNow, 24 * 3600)

        LiveActivityAPI.shared.handle(URL(string: "notchisland://alarm/cancel?at=7:30")!)
        XCTAssertTrue(timer.alarms.isEmpty, "cancelled by the time it was set for")
    }

    func testTheURLTakesTheTwelveHourClockAndCancelsEverything() {
        LiveActivityAPI.shared.handle(URL(string: "notchisland://alarm?at=7:30pm")!)
        LiveActivityAPI.shared.handle(URL(string: "notchisland://alarm?time=6am")!)
        XCTAssertEqual(timer.alarms.count, 2)
        XCTAssertTrue(timer.alarms.allSatisfy { $0.label == IslandAlarm.defaultLabel }, "no label is the word Alarm")
        LiveActivityAPI.shared.handle(URL(string: "notchisland://alarm/cancel")!)
        XCTAssertTrue(timer.alarms.isEmpty)
    }

    func testTheURLRefusesWhatIsNotATime() {
        for bad in ["notchisland://alarm?at=soon", "notchisland://alarm?at=5", "notchisland://alarm?at=25:00", "notchisland://alarm"] {
            LiveActivityAPI.shared.handle(URL(string: bad)!)
        }
        XCTAssertTrue(timer.alarms.isEmpty)
    }
}
