import AppKit
import XCTest
@testable import MacNotchIsland

/// Rules from the panel's sections that have no other home: when Today's hours give their room
/// back, what the Home grid's Today tile names, what the alert banner says for a track's sneak
/// peek, and how the favourite apps are sorted by what is on disk.
final class PanelRulesTests: XCTestCase {

    // MARK: - Today's hours

    /// Beside the hours the body has 60 pt, and the states that stand in for the list — the
    /// day's "Nothing left today" with tomorrow under it, the Allow Reminders pill, the
    /// calendar's refusal — come to between 63 and 107. They grew past the section, and the
    /// panel's clip cut the hours off. The hours go only under the list.
    func testTheHoursGoOnlyUnderTheList() {
        XCTAssertTrue(TodaySectionView.showsHours(forecast: true, showingList: true))
        XCTAssertFalse(TodaySectionView.showsHours(forecast: true, showingList: false), "an empty state takes the room")
        XCTAssertFalse(TodaySectionView.showsHours(forecast: false, showingList: true), "no forecast, no hours")
        XCTAssertFalse(TodaySectionView.showsHours(forecast: false, showingList: false))

        let refused = TodaySectionView.showsList(calendarOff: true, rows: 3)
        let empty = TodaySectionView.showsList(calendarOff: false, rows: 0)
        for list in [refused, empty] {
            let hours = TodaySectionView.showsHours(forecast: true, showingList: list)
            XCTAssertFalse(hours)
            XCTAssertEqual(TodaySectionView.listHeight(showingHours: hours), SectionMetrics.bodyHeight,
                           "the state has the whole body")
        }
        XCTAssertGreaterThanOrEqual(SectionMetrics.bodyHeight, 107, "which holds the tallest of the states")
        XCTAssertLessThan(TodaySectionView.listHeight(showingHours: true), 63,
                          "and the room beside the hours holds none of them")
    }

    // MARK: - The Home grid's Today tile

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    private func moment(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)))
    }

    private func event(_ title: String, from start: Date, to end: Date, allDay: Bool = false) -> AgendaStore.Event {
        AgendaStore.Event(id: title, title: title, start: start, end: end, isAllDay: allDay,
                          location: nil, joinURL: nil, tint: "blue")
    }

    private func reminder(_ title: String, completed: Bool = false) -> AgendaStore.Reminder {
        AgendaStore.Reminder(id: title, title: title, due: nil, isCompleted: completed, priority: 0, tint: "blue")
    }

    private func glimpse(_ events: [AgendaStore.Event], _ reminders: [AgendaStore.Reminder] = [], at now: Date) -> String {
        HomeGridView.agendaGlimpse(events: events, reminders: reminders, at: now, calendar: newYork)
    }

    /// The agenda reads the next twenty-four hours, timed events first. In the evening the
    /// tile named tomorrow morning's meeting while the Today section said "Nothing left today".
    func testTheTileDoesNotNameTomorrowInTheEvening() throws {
        let evening = try moment(25, 21)
        let tomorrow = event("Standup", from: try moment(26, 9), to: try moment(26, 9, 15))
        XCTAssertEqual(glimpse([tomorrow], at: evening), "Nothing today")
        XCTAssertEqual(glimpse([tomorrow], [reminder("Water the plants")], at: evening), "Water the plants",
                       "today's reminder, not tomorrow's meeting")
        XCTAssertTrue(TodaySectionView.day(events: [tomorrow], reminders: [], at: evening, calendar: newYork).events.isEmpty,
                      "the section's own day, which the tile now counts by")
    }

    /// Timed events come before all-day ones in the agenda's order, so tomorrow's 9 o'clock
    /// was named over today's all-day event.
    func testTodaysAllDayEventComesBeforeTomorrowsTimedOne() throws {
        let evening = try moment(25, 21)
        let allDay = event("Offsite", from: try moment(25, 0), to: try moment(26, 0), allDay: true)
        let tomorrow = event("Standup", from: try moment(26, 9), to: try moment(26, 9, 15))
        XCTAssertEqual(glimpse([tomorrow, allDay], at: evening), "Offsite")
    }

    func testTheTileSkipsWhatIsOverAndWhatIsTickedOff() throws {
        let evening = try moment(25, 19)
        let ended = event("Review", from: try moment(25, 17), to: try moment(25, 18))
        let later = event("Dinner", from: try moment(25, 20), to: try moment(25, 21))
        XCTAssertEqual(glimpse([ended, later], at: evening), "Dinner", "a list only as fresh as its last reading")
        XCTAssertEqual(glimpse([ended], [reminder("Ticked", completed: true), reminder("Open")], at: evening), "Open",
                       "a reminder just ticked off is not what is next")
        XCTAssertEqual(glimpse([], [reminder("Ticked", completed: true)], at: evening), "Nothing today")
    }

    // MARK: - The banner for a track's sneak peek

    private func track(_ title: String) -> NowPlayingInfo {
        NowPlayingInfo(title: title, artist: "Kendrick Lamar", album: "", duration: 200, elapsed: 0, timestamp: Date(),
                       isPlaying: true, bundleID: nil, artwork: nil, artworkID: 0, accent: .white)
    }

    /// The slot at the banner's far end already carries the title and the artist, and the
    /// section under it may be Now Playing showing the same track: the title said it again.
    func testTheSneakPeeksBannerSaysWhatHappenedRatherThanTheTitleAgain() {
        let peek = IslandActivity(id: NowPlayingService.peekAlertID, kind: .nowPlaying,
                                  content: .nowPlaying(track("Alright")), priority: 60)
        XCTAssertEqual(AlertBanner.title(for: peek), AlertBanner.peekTitle)
        XCTAssertFalse(AlertBanner.title(for: peek).contains("Alright"))

        let other = IslandActivity(id: "nowplaying", kind: .nowPlaying, content: .nowPlaying(track("Alright")), priority: 10)
        XCTAssertEqual(AlertBanner.title(for: other), IslandAccessibility.compactLabel(for: other.content),
                       "anything else from Now Playing is as it was")
        let unlock = IslandActivity(id: "unlock", kind: .unlock, content: .unlock, priority: 50)
        XCTAssertEqual(AlertBanner.title(for: unlock), "Unlocked")
    }

    // MARK: - Favourite apps, as the disk has them

    /// Sorted once, when something may have moved them, rather than asked about on every read:
    /// an app that is there once, an app that is missing once more for its folder.
    func testTheFavouriteAppsAreSortedByOneLookAtTheDisk() {
        let disk: Set<String> = ["/Applications", "/Applications/Music.app"]
        var asked: [String] = []
        let found = FavoriteApps.check(["/Applications/Music.app", "/Applications/Deleted.app",
                                        "/Volumes/Backup/Apps/Thing.app"]) { path in
            asked.append(path)
            return disk.contains(path)
        }
        XCTAssertEqual(found.live, ["/Applications/Music.app"])
        XCTAssertEqual(found.away, ["/Volumes/Backup/Apps/Thing.app"], "its whole folder is gone: a disk not plugged in")
        XCTAssertEqual(found.gone, ["/Applications/Deleted.app"], "its folder is there and it is not: deleted")
        XCTAssertEqual(asked.count, 5, "one look for the app that is there, two for each that is not")
    }

    func testTheSortAgreesWithWhatIsWorthKeeping() {
        let disk: Set<String> = ["/Applications", "/Applications/Music.app", "/Users/me/Apps"]
        let exists: (String) -> Bool = { disk.contains($0) }
        let paths = ["/Applications/Music.app", "/Applications/Deleted.app", "/Volumes/Backup/Thing.app",
                     "/Users/me/Apps/Gone.app"]
        let found = FavoriteApps.check(paths, exists: exists)
        let kept = paths.filter { path in FavoriteApps.worthKeeping(path, exists: exists) }
        XCTAssertEqual(Set(found.live + found.away), Set(kept), "kept is exactly what is there or away")
        XCTAssertEqual(Set(found.gone), Set(paths).subtracting(kept), "and gone is the rest")
        XCTAssertEqual(found.live.count + found.away.count + found.gone.count, paths.count, "nothing lost, nothing twice")
        XCTAssertEqual(found.gone, ["/Applications/Deleted.app", "/Users/me/Apps/Gone.app"], "in the stored order")
    }

    // MARK: - The Home grid's Notes tile

    /// The tile split the whole scratchpad at every line break, twice a pass, to keep the first
    /// piece. It reads only as far as the end of that piece now, and the piece is the same one:
    /// blank lines before it passed over, a line break inside a character left alone.
    func testTheNotesTileReadsOnlyItsFirstLine() {
        let texts = ["", "\n", "\n\n\n", "Milk", "Milk\n", "Milk\nEggs", "\n\nMilk\nEggs\n", "  \nMilk",
                     "Line\r\nNext", "\r\n\r\nx", "e\u{301}\nb", "\n\u{301}a", "שלום\nעולם"]
        for text in texts {
            let split = text.split(separator: "\n").first.map(String.init) ?? ""
            XCTAssertEqual(HomeGridView.notesGlimpse(text), split.isEmpty ? "Jot it down" : split,
                           "the same line as the split gave for \(text.debugDescription)")
        }
        XCTAssertEqual(HomeGridView.notesGlimpse("\n\nShopping\nMilk"), "Shopping", "blank lines before it are passed over")
        XCTAssertEqual(HomeGridView.notesGlimpse(""), "Jot it down")
        XCTAssertEqual(HomeGridView.notesGlimpse("\n\n"), "Jot it down", "nothing but blank lines is nothing")
        let long = "Heading\n" + String(repeating: "and a great deal more\n", count: 50_000)
        XCTAssertEqual(HomeGridView.notesGlimpse(long), "Heading")
    }

    // MARK: - The call card's icon

    /// Looked up once per app: the card asked LaunchServices and the disk for it on every pass,
    /// and passes come with every change of the microphone's mute. The same image comes back,
    /// and an app that is nowhere to be found has none, as it had none.
    func testTheCallCardLooksItsAppUpOnce() throws {
        XCTAssertNil(CallAppIcon.icon(for: "invalid.notch-island.no-such-app"))
        XCTAssertNil(CallAppIcon.icon(for: "invalid.notch-island.no-such-app"), "not found is asked again, and is still nothing")
        guard let finder = CallAppIcon.icon(for: "com.apple.finder") else {
            throw XCTSkip("LaunchServices cannot find Finder in this session")
        }
        XCTAssertTrue(CallAppIcon.icon(for: "com.apple.finder") === finder, "the second pass draws the first one's image")
    }

    // MARK: - The press-in

    /// The press-in is drawn only on the collapsed island, and so it is published only there:
    /// in an open panel every click on the rail, the switcher, a slider or the scrubber set it
    /// and cleared it, and the whole island was drawn twice for a change nothing drew.
    func testThePressInIsPublishedOnlyWhileTheIslandIsCollapsed() {
        XCTAssertTrue(IslandPress.publishes(expanded: false))
        XCTAssertFalse(IslandPress.publishes(expanded: true), "an open panel, a card or a peek")
    }
}
