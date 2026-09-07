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
}
