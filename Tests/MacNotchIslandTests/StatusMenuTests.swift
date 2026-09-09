import XCTest
@testable import MacNotchIsland

final class StatusMenuTests: XCTestCase {
    func testPresetTitlesUseAppleWording() {
        XCTAssertEqual(StatusItemController.presetTitle(minutes: 1), "1 Minute")
        XCTAssertEqual(StatusItemController.presetTitle(minutes: 5), "5 Minutes")
        XCTAssertEqual(StatusItemController.presetTitle(minutes: 45), "45 Minutes")
        XCTAssertEqual(StatusItemController.presetTitle(minutes: 60), "1 Hour")
        XCTAssertEqual(StatusItemController.presetTitle(minutes: 120), "2 Hours")
    }

    // MARK: - What a right-click on the island offers

    func testTheMenuLeadsWithWhatTheIslandIsShowing() {
        let info = NowPlayingInfo(title: "Song", artist: "Artist", album: "", duration: 200, elapsed: 10,
                                  timestamp: Date(), isPlaying: true, bundleID: nil, artwork: nil,
                                  artworkID: 0, accent: .white)
        XCTAssertTrue(IslandMenu.hasCommands(.nowPlaying(info)))
        XCTAssertTrue(IslandMenu.hasCommands(.timer(TimerState(label: "Tea", total: 60, endDate: Date()))))
        XCTAssertTrue(IslandMenu.hasCommands(.stopwatch(StopwatchState(startedAt: Date()))))
        XCTAssertTrue(IslandMenu.hasCommands(.shelf(ShelfState(count: 2))))
        XCTAssertTrue(IslandMenu.hasCommands(.call(CallState(appName: "FaceTime", bundleID: "x", startedAt: Date()))))
    }

    func testAnActivityWithNothingToCommandAddsNothingToTheMenu() {
        // A battery percentage is a thing to look at, not a thing to tell to do something —
        // and a separator over an empty list is worse than no separator.
        XCTAssertFalse(IslandMenu.hasCommands(.unlock))
        XCTAssertFalse(IslandMenu.hasCommands(.focus(FocusState(name: "Work", symbol: "moon.fill", isOn: true, tint: "indigo"))))
        XCTAssertFalse(IslandMenu.hasCommands(.hud(LevelHUD(kind: .volume, level: 0.4))))
    }

    // MARK: - Hidden by the clock, or by the app in front

    func testTheIslandIsHiddenOnlyWhileTheClockSaysSo() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(IslandMenu.isPaused(until: 0, now: now), "nothing was asked for")
        XCTAssertTrue(IslandMenu.isPaused(until: 1_000_060, now: now))
        XCTAssertFalse(IslandMenu.isPaused(until: 999_999, now: now), "that hour is over")
        XCTAssertFalse(IslandMenu.isPaused(until: 1_000_000, now: now), "to the second, it is over")
    }
}
