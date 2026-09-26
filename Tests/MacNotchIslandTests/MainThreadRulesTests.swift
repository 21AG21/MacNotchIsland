import XCTest
@testable import MacNotchIsland

/// The rules behind work that moved off the main thread: which window pictures a beat retakes,
/// what the calendar's reading decides once it has come back from its queue, when a reading
/// of the sound devices may set the level the rail shows, how often the menu bar is measured and
/// the volume slider writes, and which reading of the AirPods' route is shown.
final class MainThreadRulesTests: XCTestCase {

    // MARK: - Window pictures

    private func window(_ id: CGWindowID, x: CGFloat = 0, away: IslandWindow.Away? = nil) -> IslandWindow {
        IslandWindow(id: id, title: "", appName: "App", pid: 1, frame: CGRect(x: x, y: 0, width: 400, height: 300),
                     icon: nil, thumbnail: nil, away: away)
    }

    private func frames(_ windows: [IslandWindow]) -> [CGWindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
    }

    /// A beat where nothing moved takes one picture — the front window's, since that is the
    /// one being worked in — where it used to take all eight.
    func testABeatWhereNothingMovedRetakesOnlyTheFrontWindow() {
        let listed = (1...8).map { window(CGWindowID($0)) }
        let wanted = WindowsMonitor.recaptures(listed, previousFrames: frames(listed), pictured: Set(listed.map(\.id)))
        XCTAssertEqual(wanted, [1])
    }

    func testAWindowThatMovedIsPicturedAgain() {
        let before = (1...4).map { window(CGWindowID($0)) }
        var after = before
        after[2].frame.origin.x = 120
        let wanted = WindowsMonitor.recaptures(after, previousFrames: frames(before), pictured: Set(before.map(\.id)))
        XCTAssertEqual(wanted, [1, 3], "the front window, and the one whose frame changed")
    }

    /// The first beat after the section opens has no frames to compare with, and a window that
    /// has only just appeared has no picture: both are taken.
    func testAWindowWithNoPictureYetIsAlwaysTaken() {
        let listed = (1...3).map { window(CGWindowID($0)) }
        XCTAssertEqual(WindowsMonitor.recaptures(listed, previousFrames: [:], pictured: []), [1, 2, 3])
        XCTAssertEqual(WindowsMonitor.recaptures(listed, previousFrames: frames(listed), pictured: [1, 2]), [1, 3])
    }

    /// Only what is on screen can be captured; a window put away keeps the picture it went
    /// with. And the front window is the front one on screen, not whatever heads the list.
    func testWindowsPutAwayAreNeverRetaken() {
        let listed = [window(1), window(2), window(3, away: .minimised), window(4, away: .hidden)]
        XCTAssertEqual(WindowsMonitor.recaptures(listed, previousFrames: [:], pictured: []), [1, 2])
        let behind = [window(5, away: .minimised), window(6)]
        XCTAssertEqual(WindowsMonitor.recaptures(behind, previousFrames: frames(behind), pictured: [5, 6]), [6])
    }

    func testNoMoreThanTheCapAreEverPictured() {
        let listed = (1...12).map { window(CGWindowID($0)) }
        let wanted = WindowsMonitor.recaptures(listed, previousFrames: [:], pictured: [])
        XCTAssertEqual(wanted.count, WindowsMonitor.maxCaptures)
        XCTAssertEqual(wanted, Array(listed.prefix(WindowsMonitor.maxCaptures)).map(\.id))
    }

    func testAnEmptyDesktopAsksForNothing() {
        XCTAssertEqual(WindowsMonitor.recaptures([], previousFrames: [:], pictured: []), [])
    }

    // MARK: - The calendar card

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testAnEventIsShownFromTenMinutesBeforeItStarts() {
        XCTAssertTrue(CalendarMonitor.isDue(start: now.addingTimeInterval(10 * 60), end: now.addingTimeInterval(40 * 60), at: now))
        XCTAssertFalse(CalendarMonitor.isDue(start: now.addingTimeInterval(10 * 60 + 1), end: now.addingTimeInterval(40 * 60), at: now))
    }

    func testAnEventLingersFiveMinutesAfterItStartsAndNotPastItsEnd() {
        XCTAssertTrue(CalendarMonitor.isDue(start: now.addingTimeInterval(-4 * 60), end: now.addingTimeInterval(30 * 60), at: now))
        XCTAssertFalse(CalendarMonitor.isDue(start: now.addingTimeInterval(-5 * 60), end: now.addingTimeInterval(30 * 60), at: now))
        XCTAssertFalse(CalendarMonitor.isDue(start: now.addingTimeInterval(-60), end: now, at: now),
                       "a two-minute stand-up that has ended is not up any more")
    }

    /// A reading that comes back after the monitor was stopped, or stopped and started again,
    /// is speaking to nobody.
    func testOnlyTheReadingStillWantedIsShown() {
        XCTAssertTrue(CalendarMonitor.answers(3, current: 3))
        XCTAssertFalse(CalendarMonitor.answers(2, current: 3))
    }

    func testAMeetingLinkIsFoundInTheTextAroundIt() {
        let notes = "Agenda\nJoin: https://us02web.zoom.us/j/123456?pwd=abc\nDial-in below"
        XCTAssertEqual(CalendarMonitor.meetingLink(in: notes)?.absoluteString, "https://us02web.zoom.us/j/123456?pwd=abc")
        XCTAssertNotNil(CalendarMonitor.meetingLink(in: "Call on HTTPS://MEET.GOOGLE.COM/abc-defg-hij"),
                        "whatever case the invitation was written in")
        XCTAssertNil(CalendarMonitor.meetingLink(in: "Room 4, https://example.com/agenda"), "a link is not a meeting")
        XCTAssertNil(CalendarMonitor.meetingLink(in: ""))
    }

    /// The pattern is compiled once and shared; asking twice, from two readers, gives the
    /// same answer.
    func testTheSamePatternAnswersEveryReader() {
        let text = "https://teams.microsoft.com/l/meetup-join/xyz"
        let answers = (0..<4).map { _ in CalendarMonitor.meetingLink(in: text) }
        XCTAssertEqual(Set(answers.compactMap { $0?.absoluteString }), [text])
    }

    // MARK: - The sound devices

    private let nothing: AudioOutputs.LevelParts = []

    /// A reading of the devices is taken on a queue and lands later; the listeners on the output
    /// report the level on the main thread the moment it moves. A reading's whole level is taken
    /// only when the listeners have just moved to a new output with it.
    func testADeviceReadingSetsTheLevelOnlyWhenItBringsANewOutput() {
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: true, wroteRecently: false, shownVolume: 0.4, shownHasMute: true,
                                               readVolume: 0.7, readMute: false),
                       AudioOutputs.LevelParts.all, "a new output: the level shown was another device's")
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: false, wroteRecently: false, shownVolume: 0.4, shownHasMute: true,
                                               readVolume: 0.7, readMute: false),
                       nothing, "the same output: its listener already said, and later than this reading could")
    }

    /// AirPods picked as the output: the reading that moved the listeners came before the level
    /// and the mute did, and the slider stayed disabled. A later reading of the same output fills
    /// in what is missing, and only that.
    func testALaterReadingFillsInALevelOrAMuteTheOutputHadNotPublishedYet() {
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: false, wroteRecently: false, shownVolume: nil, shownHasMute: true,
                                               readVolume: 0.5, readMute: false),
                       AudioOutputs.LevelParts.volume, "no level shown, one read: the slider comes alive")
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: false, wroteRecently: false, shownVolume: 0.5, shownHasMute: false,
                                               readVolume: 0.2, readMute: true),
                       AudioOutputs.LevelParts.mute, "the mute arrives; the level shown is its listener's and stays")
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: false, wroteRecently: false, shownVolume: nil, shownHasMute: false,
                                               readVolume: 0.5, readMute: false),
                       AudioOutputs.LevelParts.all)
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: false, wroteRecently: false, shownVolume: nil, shownHasMute: false,
                                               readVolume: nil, readMute: nil),
                       nothing, "an output with no level of its own is left showing none")
    }

    func testTheSlidersOwnWriteIsNeverPulledBackByAReadingOfTheSameOutput() {
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: false, wroteRecently: true, shownVolume: 0.4, shownHasMute: true,
                                               readVolume: 0.7, readMute: false), nothing)
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: false, wroteRecently: true, shownVolume: nil, shownHasMute: false,
                                               readVolume: 0.7, readMute: false), nothing)
    }

    /// The output switched within a moment of a write from the island: the level and mute shown
    /// are the old output's, and the slider's next write would step from them. A new output's
    /// level is never the one just written, so the reading that brings it is shown whole.
    func testANewOutputIsShownWholeEvenRightAfterTheIslandWroteTheLevel() {
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: true, wroteRecently: true, shownVolume: 0.4, shownHasMute: true,
                                               readVolume: 0.7, readMute: true),
                       AudioOutputs.LevelParts.all)
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: true, wroteRecently: true, shownVolume: 0.4, shownHasMute: true,
                                               readVolume: nil, readMute: nil),
                       AudioOutputs.LevelParts.all, "an output with no level shows none, not the last one's")
    }

    // MARK: - The menu bar's measurement

    /// The first ask is measured at once; an ask inside the hold on the last measurement waits
    /// for the end of it; an ask after it, or one whose own delay ends later, keeps its time.
    func testTheMenuBarIsMeasuredAtOnceAndThenNoSoonerThanAHoldAfterTheLast() {
        let hold = MenuBarClearance.hold
        XCTAssertEqual(MenuBarClearance.refreshDue(asked: 100, lastAt: LocalWrite.never), 100,
                       "nothing measured yet: at once")
        XCTAssertEqual(MenuBarClearance.refreshDue(asked: 100.25, lastAt: 100), 100 + hold,
                       "inside the hold: at its end")
        XCTAssertEqual(MenuBarClearance.refreshDue(asked: 100 + hold + 0.5, lastAt: 100), 100 + hold + 0.5,
                       "after it: when asked")
        XCTAssertEqual(MenuBarClearance.refreshDue(asked: 100.5, lastAt: 100, hold: 0.25), 100.5)
    }

    /// A measurement waiting to start answers every ask it starts no sooner than, and none it
    /// would start too soon for: an app just switched to wants its menus measured once they are
    /// laid out, and an alert straight after the switch used to measure them before.
    func testAMeasurementWaitingAnswersEveryAskItStartsNoSoonerThan() {
        XCTAssertFalse(MenuBarClearance.answered(due: 101, byPendingAt: nil), "nothing waiting")
        XCTAssertTrue(MenuBarClearance.answered(due: 101, byPendingAt: 101), "the end of the hold, shared")
        XCTAssertTrue(MenuBarClearance.answered(due: 100.5, byPendingAt: 101), "later measures it as well")
        XCTAssertFalse(MenuBarClearance.answered(due: 101.5, byPendingAt: 101), "sooner does not")
    }

    /// A scroll of the volume is an alert a turn — thirty-two a second here, for four seconds —
    /// and each alert asks. It was a measurement an ask; it is one at once, one at the end of
    /// each hold after it, and the last of them after the last ask.
    func testAScrollOfAlertsIsMeasuredOnceAHoldAndOnceMoreAfterTheLastAsk() {
        var lastAt = LocalWrite.never
        var pending: TimeInterval?
        var starts: [TimeInterval] = []
        func start(upTo now: TimeInterval) {
            guard let due = pending, due <= now else { return }
            starts.append(due)
            lastAt = due
            pending = nil
        }
        let asks = (0..<128).map { TimeInterval($0) / 32 }
        for now in asks {
            start(upTo: now)
            let due = MenuBarClearance.refreshDue(asked: now, lastAt: lastAt)
            if !MenuBarClearance.answered(due: due, byPendingAt: pending) { pending = due }
        }
        start(upTo: .greatestFiniteMagnitude)
        XCTAssertEqual(starts.first, 0, "the first at once")
        XCTAssertEqual(starts.count, 5, "at 0, 1, 2 and 3 seconds, and once after the last ask")
        XCTAssertGreaterThanOrEqual(starts.last ?? 0, asks.last ?? 0, "the last ask is answered")
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, MenuBarClearance.hold)
        }
    }

    // MARK: - The volume slider's writes

    /// The first move of a drag is written at once, as is one a whole interval after the last
    /// write; one inside the interval waits for the rest of it. The pace is the scroll's.
    func testTheSliderWritesAtOnceAndThenAtMostOnceAnInterval() {
        XCTAssertEqual(AudioOutputs.slideWait(lastWrite: LocalWrite.never, now: 50), 0, "the first move, at once")
        XCTAssertEqual(AudioOutputs.slideWait(lastWrite: 50, now: 50.5, interval: 0.25), 0, "long after, at once")
        XCTAssertEqual(AudioOutputs.slideWait(lastWrite: 50, now: 50, interval: 0.25), 0.25)
        XCTAssertEqual(AudioOutputs.slideWait(lastWrite: 50, now: 50.125, interval: 0.25), 0.125, "the rest of it")
        XCTAssertEqual(AudioOutputs.slideInterval, GestureRouter.volumeInterval, "the pace a scroll on the island keeps")
    }

    /// A drag reports a move a hundred and twenty-eight times a second here, for a second. The
    /// level is written about thirty times, never twice inside an interval, each time the
    /// latest level asked for — and the drag's last level always, after it has ended.
    func testADragWritesTheLatestLevelEachIntervalAndItsLastLevelAlways() {
        let interval = AudioOutputs.slideInterval
        var lastWrite = LocalWrite.never
        var waiting: (level: Float, at: TimeInterval)?
        var writes: [(level: Float, at: TimeInterval)] = []
        func flush(upTo now: TimeInterval) {
            guard let due = waiting, due.at <= now else { return }
            writes.append(due)
            lastWrite = due.at
            waiting = nil
        }
        let moves = (0..<128).map { (level: Float($0) / 127, at: TimeInterval($0) / 128) }
        for move in moves {
            flush(upTo: move.at)
            let wait = AudioOutputs.slideWait(lastWrite: lastWrite, now: move.at)
            if wait <= 0 {
                waiting = nil
                writes.append(move)
                lastWrite = move.at
            } else {
                waiting = (move.level, waiting?.at ?? move.at + wait)
            }
        }
        flush(upTo: .greatestFiniteMagnitude)
        XCTAssertLessThanOrEqual(writes.count, 32, "about thirty a second, where it was one a move")
        XCTAssertGreaterThanOrEqual(writes.count, 25)
        XCTAssertEqual(writes.first?.level, 0, "the first move at once")
        XCTAssertEqual(writes.last?.level, 1, "the drag's last level is written")
        for (earlier, later) in zip(writes, writes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.at - earlier.at, interval - 1e-9)
        }
    }

    // MARK: - The AirPods' route

    /// A Bluetooth card reads the route on the spot, ahead of a reading still on its way back
    /// from the queue; that one left first, and landing afterwards it must not put the older
    /// route back.
    func testAReadingTakenOnTheSpotIsNotUndoneByAnOlderOneLandingAfterIt() {
        XCTAssertTrue(AirPodsControl.showsReading(ticket: 1, shown: 0), "the first")
        XCTAssertTrue(AirPodsControl.showsReading(ticket: 3, shown: 2))
        XCTAssertFalse(AirPodsControl.showsReading(ticket: 2, shown: 3), "left before the card's reading, landed after it")
        XCTAssertFalse(AirPodsControl.showsReading(ticket: 3, shown: 3), "never shown twice")
    }
}
