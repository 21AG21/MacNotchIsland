import AppKit
import EventKit
import XCTest
@testable import MacNotchIsland

/// The agenda's rules, on a machine with no calendar: the gate that keeps two readings off one
/// store, the deadline that stops it waiting on one for ever, the tick that is shown before
/// Reminders has agreed to it, and the rectangle the tick box takes its click in. Nothing here
/// asks EventKit for anything, and nothing here should ever make a test run ask for a calendar
/// it does not have.
final class AgendaStoreTests: XCTestCase {

    private func reminder(_ id: String, completed: Bool = false) -> AgendaStore.Reminder {
        AgendaStore.Reminder(id: id, title: "Reminder \(id)", due: nil, isCompleted: completed,
                             priority: 0, tint: "blue")
    }

    private func tick(_ completed: Bool, at moment: Date) -> AgendaStore.Tick {
        AgendaStore.Tick(completed: completed, until: moment.addingTimeInterval(AgendaStore.tickSettle))
    }

    // MARK: - One reading of the day at a time

    func testTheMinutesPollDoesNotReadTheDayTwiceOver() {
        // A calendar on somebody's server answers in its own time, and the change notification
        // fires as often as it likes while it does. Two readings in flight are two round trips
        // for one answer, and the slower of them lands last carrying the older day.
        var pass = RadioPass()
        XCTAssertTrue(pass.start(), "the first reading goes")
        XCTAssertFalse(pass.start(), "the second finds one in the air and stands down")
        XCTAssertTrue(pass.isRunning)
    }

    func testATickMadeWhileTheDayIsBeingReadIsNotSwallowed() {
        // The whole point of remembering the ask: the reading that matters most is the one
        // straight after a reminder has been ticked off, and dropping it would leave the row
        // sitting there until the minute was up.
        var pass = RadioPass()
        XCTAssertTrue(pass.start(), "the poll goes")
        XCTAssertFalse(pass.start(), "the tick's own reading stands down behind it")
        XCTAssertTrue(pass.finish(), "and is handed back the moment the poll is done")
        XCTAssertTrue(pass.start(), "so it can go")
        XCTAssertFalse(pass.finish(), "with nobody waiting behind it")
    }

    // MARK: - A reading that never answers

    func testAFetchThatNeverAnswersDoesNotFreezeTheDay() {
        // Nothing obliges EventKit to call a completion back: access taken away mid-flight, or
        // an account that simply never comes round. The gate was held for the rest of the
        // session while the section sat on yesterday, so a reading is given up on in the end.
        let asked = Date()
        XCTAssertFalse(AgendaStore.abandons(startedAt: asked, at: asked.addingTimeInterval(1)),
                       "a reading a second old is slow, not lost")
        XCTAssertFalse(AgendaStore.abandons(startedAt: asked,
                                            at: asked.addingTimeInterval(AgendaStore.readingDeadline - 0.5)),
                       "and the account is given every second it was promised")
        XCTAssertTrue(AgendaStore.abandons(startedAt: asked,
                                           at: asked.addingTimeInterval(AgendaStore.readingDeadline)))
        // Which is worth nothing unless the gate comes back with it: this is what every later
        // ask was standing down behind.
        var pass = RadioPass()
        XCTAssertTrue(pass.start())
        XCTAssertFalse(pass.start(), "the poll, the notification and the tick all stand down")
        _ = pass.finish()
        XCTAssertTrue(pass.start(), "so giving up on the reading has to open the gate again")
    }

    func testTheDeadlineComesRoundBeforeThePollDoes() {
        // The poll is the only thing that comes back to look, so a deadline longer than it
        // would leave the day frozen for a whole minute more than it had to.
        XCTAssertLessThan(AgendaStore.readingDeadline, 60)
        XCTAssertGreaterThan(AgendaStore.readingDeadline, AgendaStore.tickSettle,
                             "and no reading is given up on before a tick it might settle")
    }

    func testAReadingThatWasGivenUpOnHasNothingLeftToSay() {
        // The fetch that went quiet may still answer, long after its gate was handed on. The
        // day it left with is hours old by then, and handing that gate back a second time would
        // let two readings run at once — which is the thing the gate exists to prevent.
        XCTAssertTrue(AgendaStore.answers(4, current: 4), "the reading in flight is the one that speaks")
        XCTAssertFalse(AgendaStore.answers(3, current: 4), "the one that was given up on is talking to nobody")
        XCTAssertFalse(AgendaStore.answers(0, current: 1))
        XCTAssertFalse(AgendaStore.answers(5, current: 4), "and nothing that has not been asked for yet")
    }

    // MARK: - A tick, before the store has agreed to it

    func testATickedReminderLooksTickedBeforeTheStoreHasAgreed() {
        let pressed = Date()
        let shown = AgendaStore.showing([reminder("r1"), reminder("r2")],
                                        ticked: ["r1": tick(true, at: pressed)], at: pressed)
        XCTAssertEqual(shown.count, 2)
        XCTAssertTrue(shown[0].isCompleted, "the tick is on the row before the write has left the Mac")
        XCTAssertFalse(shown[1].isCompleted, "and nothing else in the list has moved")
    }

    func testAReadingThatLeftBeforeTheTickDoesNotUndoIt() {
        let pressed = Date()
        // A reading in the air when the button went down lands after it, still listing the
        // reminder as outstanding. Believing it would put the row straight back.
        let shown = AgendaStore.showing([reminder("r1")], ticked: ["r1": tick(true, at: pressed)],
                                        at: pressed.addingTimeInterval(0.2))
        XCTAssertTrue(shown[0].isCompleted)
        XCTAssertTrue(AgendaStore.accepts(true, waitingFor: tick(true, at: pressed), at: pressed),
                      "the store agreeing settles the wait there and then")
        XCTAssertTrue(AgendaStore.accepts(false, waitingFor: nil, at: pressed),
                      "with nothing asked for, whatever the store says is the truth")
    }

    func testATickThatCouldNotBeSavedPutsTheReminderBack() {
        // A refused write forgets the tick, and what is shown is the store's own word again.
        // A row that quietly returns a second later with nothing said reads as the app being
        // broken rather than as the answer being no.
        let list = [reminder("r1")]
        let shown = AgendaStore.showing(list, ticked: [:], at: Date())
        XCTAssertEqual(shown, list)
        XCTAssertFalse(shown[0].isCompleted)
    }

    func testATickTheStoreNeverConfirmsIsGivenUpInTheEnd() {
        let pressed = Date()
        let waited = pressed.addingTimeInterval(AgendaStore.tickSettle)
        let shown = AgendaStore.showing([reminder("r1")], ticked: ["r1": tick(true, at: pressed)], at: waited)
        XCTAssertFalse(shown[0].isCompleted, "past the settle window the answer is no, and the row says so")
        XCTAssertTrue(AgendaStore.accepts(false, waitingFor: tick(true, at: pressed), at: waited))
        XCTAssertTrue(AgendaStore.settling(["r1": tick(true, at: pressed)],
                                           against: [reminder("r1")], at: waited).isEmpty,
                      "and the tick is not held over the next reading either")
    }

    // MARK: - When the store has agreed

    func testAReminderGoneFromTheListIsTheStoreAgreeingItIsDone() {
        // The fetch asks only for what is outstanding, so a reminder that has been ticked off
        // does not come back marked completed — it does not come back at all.
        let pressed = Date()
        let kept = AgendaStore.settling(["r1": tick(true, at: pressed)],
                                        against: [reminder("r2")], at: pressed)
        XCTAssertTrue(kept.isEmpty, "there is nothing left to hold once Reminders has caught up")
    }

    func testATickIsHeldUntilTheReadingThatConfirmsItComesBack() {
        let pressed = Date()
        let kept = AgendaStore.settling(["r1": tick(true, at: pressed)],
                                        against: [reminder("r1"), reminder("r2")], at: pressed)
        XCTAssertEqual(kept.count, 1, "the reading still lists it as outstanding, so the wait goes on")
        XCTAssertEqual(kept["r1"], tick(true, at: pressed))
    }

    func testTakingATickBackIsHeldTheSameWay() {
        let pressed = Date()
        // Unticking waits for the reminder to reappear in the list, which is the only way the
        // store has of saying it is outstanding again.
        XCTAssertEqual(AgendaStore.settling(["r1": tick(false, at: pressed)],
                                            against: [], at: pressed).count, 1)
        XCTAssertTrue(AgendaStore.settling(["r1": tick(false, at: pressed)],
                                           against: [reminder("r1")], at: pressed).isEmpty,
                      "and it is back, so there is nothing to hold")
    }

    func testAListWithNothingAskedOfItIsPassedStraightThrough() {
        let list = [reminder("r1"), reminder("r2", completed: true)]
        XCTAssertEqual(AgendaStore.showing(list, ticked: [:]), list)
        XCTAssertTrue(AgendaStore.settling([:], against: list).isEmpty)
    }

    // MARK: - The tick box's rectangle

    func testTheTickBoxTakesItsClickInTheRoomAPointerIsOwed() {
        // It was a 14 pt circle in a 16 pt box: under a third of Apple's floor by area, on the
        // one control here whose press cannot be taken back from the panel. The numbers are
        // written out rather than read back off the view: `tickHit` is built from `rail` and
        // `minHit`, so asking whether it clears `minHit` asks nothing.
        XCTAssertEqual(TodaySectionView.minHit, 28)
        XCTAssertEqual(TodaySectionView.rail, 16, "the circle is still drawn in the 16 pt gutter")
        // max(16, 28) wide, and min(max(16, 28), 28) tall: the floor, on both sides.
        XCTAssertEqual(TodaySectionView.tickHit, CGSize(width: 28, height: 28))
        // 28 × 28 = 784 against the 16 × 16 = 256 it was: three times the target, and then some.
        XCTAssertGreaterThan(TodaySectionView.tickHit.width * TodaySectionView.tickHit.height,
                             TodaySectionView.rail * TodaySectionView.rail * 3)
    }

    func testTheTickBoxNeverReachesIntoTheRowAboveOrBelow() {
        // Those rows open Calendar when they are clicked. A tick made in passing on the way to
        // one of them is the mistake this section must not invite. The rectangle is capped at
        // the row, and the row is exactly as tall as the floor, so the cap costs nothing:
        // min(28, 28) = 28, the whole row and not a point of the next.
        XCTAssertEqual(TodaySectionView.reminderRow, 28)
        XCTAssertEqual(TodaySectionView.tickHit.height, 28)
    }

    func testTheTickBoxStopsShortOfTheWordsBesideIt() {
        XCTAssertLessThan(TodaySectionView.tickInset.width, TodaySectionView.rowGap,
                          "half the gap before the title is spent, and the rest is left alone")
        XCTAssertEqual(TodaySectionView.rowGap - TodaySectionView.tickInset.width, 4)
    }

    func testNoneOfWhatTheTickBoxTakesItsClickInIsLaidOut() {
        // What is padded out is taken straight back off again, so the circle is drawn where it
        // always was and no title down the section moves a point. The two cancel only if what
        // is padded on is exactly half of what the rectangle adds to the circle: (28 − 16) / 2
        // is 6 a side, and 16 + 6 + 6 is the 28 the pointer was promised. Six, by hand — the
        // inset is defined as that difference halved, so asking the view to add it back up
        // would be true of any rail and any floor whatever.
        XCTAssertEqual(TodaySectionView.tickInset, CGSize(width: 6, height: 6))
        XCTAssertEqual(TodaySectionView.tickHit, CGSize(width: 16 + 2 * 6, height: 16 + 2 * 6))
    }

    // MARK: - Where today ends

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private func moment(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
    }

    private func event(_ id: String, at start: Date) -> AgendaStore.Event {
        AgendaStore.Event(id: id, title: "Event \(id)", start: start, end: start.addingTimeInterval(30 * 60),
                          isAllDay: false, location: nil, joinURL: nil, tint: "blue")
    }

    /// 1 November 2026 in New York is twenty-five hours long. Twenty-four hours after its
    /// midnight is eleven at night, so a meeting at half past eleven read as tomorrow's and the
    /// reminders due in the last hour were not asked for.
    func testTheDayTheClocksGoBackEndsAtMidnightNotAnHourBefore() throws {
        let evening = try moment(11, 1, 21)
        let midnight = try moment(11, 2, 0)
        XCTAssertEqual(midnight.timeIntervalSince(newYork.startOfDay(for: evening)), 25 * 3600,
                       "the day really is twenty-five hours")
        XCTAssertEqual(AgendaStore.endOfDay(for: evening, calendar: newYork), midnight)
        let late = event("late", at: try moment(11, 1, 23, 30))
        XCTAssertEqual(TodaySectionView.day(events: [late], reminders: [], at: evening, calendar: newYork).events.map(\.id),
                       ["late"], "half past eleven is still today")
    }

    /// 8 March 2026 is twenty-three hours long, and twenty-four hours counted the first hour of
    /// the next day as this one's.
    func testTheDayTheClocksGoForwardEndsAtMidnightNotAnHourAfter() throws {
        let evening = try moment(3, 8, 21)
        let midnight = try moment(3, 9, 0)
        XCTAssertEqual(AgendaStore.endOfDay(for: evening, calendar: newYork), midnight)
        let early = event("early", at: try moment(3, 9, 0, 30))
        XCTAssertTrue(TodaySectionView.day(events: [early], reminders: [], at: evening, calendar: newYork).events.isEmpty,
                      "half past midnight is tomorrow")
    }

    func testAnOrdinaryDayStillEndsAtTheNextMidnight() throws {
        let afternoon = try moment(9, 25, 15)
        XCTAssertEqual(AgendaStore.endOfDay(for: afternoon, calendar: newYork), try moment(9, 26, 0))
        XCTAssertEqual(AgendaStore.endOfDay(for: try moment(9, 25, 0), calendar: newYork), try moment(9, 26, 0),
                       "midnight itself belongs to the day it starts")
    }

    // MARK: - How far ahead the day is read

    /// Half past midnight on 1 November 2026 in New York: twenty-four hours on is half past
    /// eleven that night, the day being twenty-five hours long, and the last half hour of it was
    /// never read.
    func testTheLongDayIsReadToItsEnd() throws {
        let early = try moment(11, 1, 0, 30)
        let midnight = try moment(11, 2, 0)
        XCTAssertLessThan(early.addingTimeInterval(24 * 3600), midnight, "twenty-four hours stop short of it")
        XCTAssertEqual(AgendaStore.fetchEnd(for: early, calendar: newYork), midnight)
    }

    func testAnOrdinaryDayIsReadTwentyFourHoursAhead() throws {
        let afternoon = try moment(9, 25, 15)
        XCTAssertEqual(AgendaStore.fetchEnd(for: afternoon, calendar: newYork), afternoon.addingTimeInterval(24 * 3600),
                       "tomorrow's morning is still read, for the line that names it")
        let early = try moment(3, 8, 0, 30)
        XCTAssertEqual(AgendaStore.fetchEnd(for: early, calendar: newYork), early.addingTimeInterval(24 * 3600),
                       "the short day is read a day ahead too, past its end")
    }

    // MARK: - What the empty day says about tomorrow

    private func allDay(_ id: String, on day: Int, month: Int = 9) throws -> AgendaStore.Event {
        AgendaStore.Event(id: id, title: id, start: try moment(month, day, 0), end: try moment(month, day + 1, 0),
                          isAllDay: true, location: nil, joinURL: nil, tint: "blue")
    }

    /// A day with only an all-day event in it has no time for it to be at.
    func testTomorrowsAllDayEventIsSaidToBeAllDay() throws {
        let evening = try moment(9, 25, 21)
        let hint = TodaySectionView.tomorrowHint(events: [try allDay("Bank Holiday", on: 26)], at: evening, calendar: newYork)
        XCTAssertEqual(hint, "Tomorrow: Bank Holiday, all day")
    }

    func testTomorrowsFirstTimedEventIsSaidWithItsTime() throws {
        let evening = try moment(9, 25, 21)
        let standup = event("standup", at: try moment(9, 26, 9))
        XCTAssertEqual(TodaySectionView.tomorrowHint(events: [standup], at: evening, calendar: newYork),
                       "Tomorrow: Event standup at \(AgendaStore.timeLabel(for: standup, at: evening))")
        XCTAssertNil(TodaySectionView.tomorrowHint(events: [event("late", at: try moment(9, 25, 22))], at: evening,
                                                   calendar: newYork),
                     "tonight's is not tomorrow's")
        XCTAssertNil(TodaySectionView.tomorrowHint(events: [], at: evening, calendar: newYork))
    }

    // MARK: - Counting down to an event

    /// The countdown's timeline ticked from whenever the row appeared, so "in 1 min" could
    /// stand for thirty seconds after the meeting began. Counted from the start, every look
    /// lands a hair after one of the start's own minutes.
    func testACountdownIsCountedFromTheStart() throws {
        let start = try moment(9, 25, 10)
        let step = AgendaStore.countdownStep
        for offset in [-3600.0, -100, -61, -60, -30.5, -0.01, 0, 45, 1800] {
            let now = start.addingTimeInterval(offset)
            let phase = AgendaStore.countdownPhase(for: start, now: now)
            XCTAssertLessThanOrEqual(phase, now, "a look to give now, at \(offset)")
            XCTAssertGreaterThan(phase, now.addingTimeInterval(-3 * step), "and not long ago, at \(offset)")
            let steps = (start.timeIntervalSince(phase) + AgendaStore.countdownHair) / step
            XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-6, "on the start's own half minutes, at \(offset)")
        }
    }

    /// A hair after each of those moments, the words have already changed.
    func testALookAtTheStartSaysNow() throws {
        let start = try moment(9, 25, 10)
        let meeting = AgendaStore.Event(id: "m", title: "Meeting", start: start, end: start.addingTimeInterval(1800),
                                        isAllDay: false, location: nil, joinURL: nil, tint: "blue")
        let phase = AgendaStore.countdownPhase(for: start, now: start.addingTimeInterval(-100))
        let looks = (0..<8).map { phase.addingTimeInterval(Double($0) * AgendaStore.countdownStep) }
        let atStart = try XCTUnwrap(looks.first { $0 >= start })
        XCTAssertEqual(atStart.timeIntervalSince(start), AgendaStore.countdownHair, accuracy: 1e-6)
        XCTAssertEqual(TodaySectionView.countdown(meeting, at: atStart), "Now")
        let minuteBefore = try XCTUnwrap(looks.first { $0 >= start.addingTimeInterval(-60) })
        XCTAssertEqual(TodaySectionView.countdown(meeting, at: minuteBefore), "in 1 min")
    }

    // MARK: - A permission granted after launch

    func testAGrantMadeInSystemSettingsIsNoticed() {
        // Read once, a permission granted later left Today saying "Calendar access is off"
        // until a relaunch. A grant is what starts the store afresh.
        XCTAssertTrue(AgendaStore.newlyGranted(was: .denied, now: .fullAccess))
        XCTAssertTrue(AgendaStore.newlyGranted(was: .notDetermined, now: .fullAccess))
        XCTAssertTrue(AgendaStore.newlyGranted(was: .writeOnly, now: .fullAccess))
    }

    func testOnlyAGrantStartsTheStoreAfresh() {
        XCTAssertFalse(AgendaStore.newlyGranted(was: .fullAccess, now: .fullAccess), "nothing changed")
        XCTAssertFalse(AgendaStore.newlyGranted(was: .fullAccess, now: .denied), "taken away")
        XCTAssertFalse(AgendaStore.newlyGranted(was: .notDetermined, now: .writeOnly),
                       "write-only access still cannot read the day")
    }

    // MARK: - The Join button

    /// The name of a meeting service anywhere in a link was enough, and an invitation anybody
    /// can send put its own link behind the card's Join.
    func testAMeetingLinkIsOneWhoseHostIsTheServices() {
        XCTAssertNil(CalendarMonitor.meetingLink(in: "Join https://zoom.us.evil.example/j/1"))
        XCTAssertNil(CalendarMonitor.meetingLink(in: "Join https://evil.example/?x=zoom.us"))
        XCTAssertNil(CalendarMonitor.meetingLink(in: "Join https://evil.example/meet.google.com/abc"))
        XCTAssertNil(CalendarMonitor.meetingLink(in: "Join https://notzoom.us/j/1"))
        XCTAssertNil(CalendarMonitor.meetingLink(in: "Join https://zoom.us@evil.example/j/1"), "a user name is not the host")
    }

    /// Outlook's Safe Links and Google's redirects wrap the real address in a query on a host of
    /// their own; the Join button went missing from every invitation that came through either.
    /// The inner link is what comes back, so the click never goes through the wrapper.
    func testAMeetingLinkWrappedByASafeLinkOrARedirectIsUnwrapped() {
        let safe = "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%3Aabc&data=05"
        XCTAssertEqual(CalendarMonitor.meetingLink(in: "Join: \(safe)")?.absoluteString,
                       "https://teams.microsoft.com/l/meetup-join/19:abc")
        let redirect = "https://www.google.com/url?q=https://meet.google.com/abc-defg-hij&sa=D"
        XCTAssertEqual(CalendarMonitor.meetingLink(in: "Join \(redirect)")?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertNil(CalendarMonitor.meetingLink(in: "https://evil.example/?url=https://evil.example/zoom.us"),
                     "a wrapper around a link that is not a meeting's is still nothing")
        XCTAssertNil(CalendarMonitor.meetingLink(in: "https://evil.example/?url=zoom.us"), "and a bare word is not a link")
        XCTAssertEqual(CalendarMonitor.meetingLink(in: "Join https://zoom.us/j/1")?.absoluteString, "https://zoom.us/j/1")
        XCTAssertEqual(CalendarMonitor.meetingLink(in: "https://us02web.zoom.us/j/123?pwd=a")?.host, "us02web.zoom.us")
        XCTAssertNotNil(CalendarMonitor.meetingLink(in: "https://teams.microsoft.com/l/meetup-join/x"))
        XCTAssertNotNil(CalendarMonitor.meetingLink(in: "https://acme.webex.com/meet/pat"))
    }

    /// The inner link's scheme only had to start with "http", so a wrapper around
    /// "httpfoo://zoom.us/j/1" made Join open whatever app claims that scheme.
    func testAWrappedLinkIsOnlyUnwrappedToAWebLink() {
        XCTAssertNil(CalendarMonitor.meetingLink(in: "Join https://x.example/?url=httpfoo://zoom.us/j/1"))
        XCTAssertNil(CalendarMonitor.meetingLink(in: "Join https://x.example/?url=zoommtg://zoom.us/join?confno=1"))
        XCTAssertEqual(CalendarMonitor.meetingLink(in: "Join https://x.example/?url=http://zoom.us/j/1")?.absoluteString,
                       "http://zoom.us/j/1")
        XCTAssertEqual(CalendarMonitor.meetingLink(in: "Join https://x.example/?url=HTTPS://zoom.us/j/1")?.host, "zoom.us",
                       "the scheme in capitals is still the web's")
    }

    /// Any "%3A" in a wrapped link was taken for a second layer of encoding, so a Teams link —
    /// whose own path and query are full of escapes — was decoded once too often and its query
    /// split at its own "%26". Only a link encoded as a whole is decoded again.
    func testAWrappedLinkIsDecodedAgainOnlyWhenItIsEncodedAsAWhole() throws {
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3Ameeting_abc%40thread.v2/0?context=%7B%22Tid%22%3A%22a%26b%22%7D"
        let safe = "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253Ameeting_abc%2540thread.v2%2F0%3Fcontext%3D%257B%2522Tid%2522%253A%2522a%2526b%2522%257D&data=05"
        XCTAssertEqual(CalendarMonitor.meetingLink(in: "Join: \(safe)")?.absoluteString, teams,
                       "the meeting link comes back exactly as it was written")
        let lower = teams.replacingOccurrences(of: "%3A", with: "%3a")
        let wrapped = try XCTUnwrap(lower.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let safeLower = "https://eur01.safelinks.protection.outlook.com/?url=\(wrapped)&data=05"
        XCTAssertEqual(CalendarMonitor.meetingLink(in: safeLower)?.absoluteString, lower, "and so does one in small letters")

        let twice = "https://www.google.com/url?q=https%253A%252F%252Fzoom.us%252Fj%252F1&sa=D"
        XCTAssertEqual(CalendarMonitor.meetingLink(in: twice)?.absoluteString, "https://zoom.us/j/1",
                       "a link encoded as a whole once more is decoded once more")
        let twiceLower = "https://www.google.com/url?q=https%253a%252f%252fzoom.us%252fj%252f1&sa=D"
        XCTAssertEqual(CalendarMonitor.meetingLink(in: twiceLower)?.absoluteString, "https://zoom.us/j/1")

        XCTAssertTrue(CalendarMonitor.isEncodedOnceMore("https%3A%2F%2Fzoom.us%2Fj%2F1"))
        XCTAssertTrue(CalendarMonitor.isEncodedOnceMore("HTTP%3a%2f%2fzoom.us"))
        XCTAssertFalse(CalendarMonitor.isEncodedOnceMore(teams), "escapes inside a link are the link's own")
        XCTAssertFalse(CalendarMonitor.isEncodedOnceMore("zoom.us%2Fj%2F1"), "not a link at all")
        XCTAssertFalse(CalendarMonitor.isEncodedOnceMore("httpfoo%3A%2F%2Fzoom.us"))
    }

    func testTheFirstRealMeetingLinkWinsOverADecoyBeforeIt() {
        let notes = "Agenda: https://evil.example/?next=zoom.us\nJoin: https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(CalendarMonitor.meetingLink(in: notes)?.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testAMeetingHostIsTheDomainOrANameInsideIt() {
        XCTAssertTrue(CalendarMonitor.isMeetingHost("zoom.us"))
        XCTAssertTrue(CalendarMonitor.isMeetingHost("US02WEB.ZOOM.US"))
        XCTAssertTrue(CalendarMonitor.isMeetingHost("zoom.us."), "the closing dot of a full name")
        XCTAssertFalse(CalendarMonitor.isMeetingHost("zoom.us.evil.example"))
        XCTAssertFalse(CalendarMonitor.isMeetingHost("evilzoom.us"))
        XCTAssertFalse(CalendarMonitor.isMeetingHost(""))
    }

    // MARK: - Rows

    /// Every occurrence of a repeating event has the same identifier; two in one day were two
    /// rows with one id.
    func testTwoOccurrencesOfOneEventAreTwoRows() {
        let nine = Date(timeIntervalSince1970: 1_790_000_000)
        let five = nine.addingTimeInterval(8 * 3600)
        XCTAssertNotEqual(AgendaStore.rowID("standup", start: nine), AgendaStore.rowID("standup", start: five))
        XCTAssertEqual(AgendaStore.rowID("standup", start: nine), AgendaStore.rowID("standup", start: nine),
                       "and the same occurrence is the same row from one reading to the next")
        XCTAssertTrue(AgendaStore.rowID("standup", start: nine).hasPrefix("standup@"))
    }

    func testADueDateWithNoCalendarIsStillADate() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let bare = DateComponents(year: 2026, month: 9, day: 26, hour: 9, minute: 0)
        XCTAssertNil(bare.date, "what EventKit can hand over")
        XCTAssertEqual(AgendaStore.dueDate(bare, calendar: utc), utc.date(from: bare))
        var carried = bare
        carried.calendar = utc
        XCTAssertEqual(AgendaStore.dueDate(carried, calendar: Calendar(identifier: .buddhist)), carried.date,
                       "components that carry a calendar are read in it")
        XCTAssertNil(AgendaStore.dueDate(nil))
    }
}
