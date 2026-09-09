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

    // MARK: - Hidden by the clock, or by the app in front

    func testTheIslandIsHiddenOnlyWhileTheClockSaysSo() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(IslandMenu.isPaused(until: 0, now: now), "nothing was asked for")
        XCTAssertTrue(IslandMenu.isPaused(until: 1_000_060, now: now))
        XCTAssertFalse(IslandMenu.isPaused(until: 999_999, now: now), "that hour is over")
        XCTAssertFalse(IslandMenu.isPaused(until: 1_000_000, now: now), "to the second, it is over")
    }
}
