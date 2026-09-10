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

    func testAMacThatWillNotStayAwakeSaysSoInWordsAPersonCanActOn() {
        let refused = KeepAwake.announcement(for: .refused)
        XCTAssertEqual(refused.title, "Keep Awake didn't turn on")
        XCTAssertEqual(refused.subtitle, "macOS would not hold the Mac awake. Try again in a moment.")
        XCTAssertFalse(refused.subtitle?.contains(where: { $0.isNumber }) ?? true,
                       "the IOReturn goes to the log; a number in the pill tells nobody anything")
        XCTAssertEqual(refused.tint, "orange", "a refusal must not look like the pill that says it worked")
        XCTAssertNil(refused.trailingText, "there is no state to put in the slot: nothing was switched on")
    }

    func testThePillStillSaysOnAndOffTheWayItAlwaysDid() {
        XCTAssertEqual(KeepAwake.announcement(for: .on).title, "Keep Awake")
        XCTAssertEqual(KeepAwake.announcement(for: .on).subtitle, "On")
        XCTAssertEqual(KeepAwake.announcement(for: .on).trailingText, "On")
        XCTAssertEqual(KeepAwake.announcement(for: .on).symbol, "cup.and.saucer.fill")
        XCTAssertEqual(KeepAwake.announcement(for: .off).subtitle, "Off")
        XCTAssertEqual(KeepAwake.announcement(for: .off).trailingText, "Off")
        XCTAssertNotEqual(KeepAwake.announcement(for: .refused), KeepAwake.announcement(for: .off),
                          "a Mac that refused is not a Mac that was switched off")
    }

    func testAPressThatChangesNothingStillSaysWhereTheSwitchIs() {
        XCTAssertEqual(KeepAwake.shared.set(false), .off, "already off, so nothing is held and nothing is said")
    }
}
