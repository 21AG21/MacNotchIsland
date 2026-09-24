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
}
