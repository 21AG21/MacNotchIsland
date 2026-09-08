import XCTest
@testable import MacNotchIsland

final class KeepAwakeTests: XCTestCase {
    override func tearDown() {
        KeepAwake.shared.set(false)
        ActivityCenter.shared.resetForTesting()
        super.tearDown()
    }

    func testTogglingHoldsAndReleasesTheAssertionAndSaysSoInThePill() {
        let keep = KeepAwake.shared
        XCTAssertFalse(keep.isOn)
        keep.toggle()
        XCTAssertTrue(keep.isOn, "the assertion was created")
        XCTAssertEqual(ActivityCenter.shared.alert?.id, "keepawake", "the pill announces it")
        keep.toggle()
        XCTAssertFalse(keep.isOn)
        keep.set(false)
        XCTAssertFalse(keep.isOn, "setting the same state twice is a no-op")
    }
}
