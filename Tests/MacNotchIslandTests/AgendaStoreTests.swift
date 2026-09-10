import AppKit
import XCTest
@testable import MacNotchIsland

/// The agenda's rules, on a machine with no calendar: the gate that keeps two readings off one
/// store, the tick that is shown before Reminders has agreed to it, and the rectangle the tick
/// box takes its click in. Nothing here asks EventKit for anything, and nothing here should
/// ever make a test run ask for a calendar it does not have.
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
        // one control here whose press cannot be taken back from the panel.
        XCTAssertEqual(TodaySectionView.minHit, 28)
        XCTAssertGreaterThanOrEqual(TodaySectionView.tickHit.width, TodaySectionView.minHit)
        XCTAssertGreaterThanOrEqual(TodaySectionView.tickHit.height, TodaySectionView.minHit)
        let before = TodaySectionView.rail * TodaySectionView.rail
        XCTAssertGreaterThan(TodaySectionView.tickHit.width * TodaySectionView.tickHit.height,
                             before * 3, "three times the target it was, and then some")
    }

    func testTheTickBoxNeverReachesIntoTheRowAboveOrBelow() {
        // Those rows open Calendar when they are clicked. A tick made in passing on the way to
        // one of them is the mistake this section must not invite.
        XCTAssertLessThanOrEqual(TodaySectionView.tickHit.height, TodaySectionView.reminderRow)
    }

    func testTheTickBoxStopsShortOfTheWordsBesideIt() {
        XCTAssertLessThan(TodaySectionView.tickInset.width, TodaySectionView.rowGap,
                          "half the gap before the title is spent, and the rest is left alone")
        XCTAssertEqual(TodaySectionView.rowGap - TodaySectionView.tickInset.width, 4)
    }

    func testNoneOfWhatTheTickBoxTakesItsClickInIsLaidOut() {
        // What is padded out is taken straight back off again, so the circle is drawn where it
        // always was and no title down the section moves a point. The two have to cancel
        // exactly, and this is the arithmetic that says they do.
        XCTAssertEqual(TodaySectionView.rail + 2 * TodaySectionView.tickInset.width,
                       TodaySectionView.tickHit.width)
        XCTAssertEqual(TodaySectionView.rail + 2 * TodaySectionView.tickInset.height,
                       TodaySectionView.tickHit.height)
    }
}
