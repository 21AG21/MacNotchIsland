import XCTest
@testable import MacNotchIsland

/// The rules behind work that moved off the main thread: which window pictures a beat retakes,
/// what the calendar's reading decides once it has come back from its queue, and when a reading
/// of the sound devices may set the level the rail shows.
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

    /// A reading of the devices is taken on a queue and lands later; the listeners on the output
    /// report the level on the main thread the moment it moves. A reading's level is taken only
    /// when the listeners have just moved to a new output with it.
    func testADeviceReadingSetsTheLevelOnlyWhenItBringsANewOutput() {
        XCTAssertTrue(AudioOutputs.showsLevel(rebound: true, wroteRecently: false),
                      "a new output: the level shown was another device's")
        XCTAssertFalse(AudioOutputs.showsLevel(rebound: false, wroteRecently: false),
                       "the same output: its listener already said, and later than this reading could")
    }

    func testTheSlidersOwnWriteIsNeverPulledBackByAReading() {
        XCTAssertFalse(AudioOutputs.showsLevel(rebound: true, wroteRecently: true))
        XCTAssertFalse(AudioOutputs.showsLevel(rebound: false, wroteRecently: true))
    }
}
