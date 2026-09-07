import XCTest
@testable import MacNotchIsland

/// HiddenAppsMonitor's pure logic: whether a frontmost bundle ID matches the hidden list.
/// Doesn't touch NSWorkspace, ActivityCenter, or Preferences.
final class HiddenAppsMonitorTests: XCTestCase {
    func testExactMatchIsHidden() {
        XCTAssertTrue(HiddenAppsMonitor.isHidden(bundleID: "com.apple.keynote", hidden: ["com.apple.keynote"]))
    }

    func testCaseInsensitiveMatch() {
        XCTAssertTrue(HiddenAppsMonitor.isHidden(bundleID: "COM.APPLE.KEYNOTE", hidden: ["com.apple.keynote"]))
        XCTAssertTrue(HiddenAppsMonitor.isHidden(bundleID: "com.apple.keynote", hidden: ["Com.Apple.Keynote"]))
    }

    func testNoMatchWhenNotListed() {
        XCTAssertFalse(HiddenAppsMonitor.isHidden(bundleID: "com.apple.finder", hidden: ["com.apple.keynote"]))
    }

    func testNilBundleIDIsNeverHidden() {
        XCTAssertFalse(HiddenAppsMonitor.isHidden(bundleID: nil, hidden: ["com.apple.keynote"]))
    }

    func testEmptyHiddenListNeverHides() {
        XCTAssertFalse(HiddenAppsMonitor.isHidden(bundleID: "com.apple.keynote", hidden: []))
    }

    func testMatchAmongMultipleEntries() {
        let hidden = ["com.apple.finder", "com.apple.keynote", "com.some.game"]
        XCTAssertTrue(HiddenAppsMonitor.isHidden(bundleID: "com.some.game", hidden: hidden))
    }

    func testEmptyStringBundleIDDoesNotMatchNonEmptyEntries() {
        XCTAssertFalse(HiddenAppsMonitor.isHidden(bundleID: "", hidden: ["com.apple.keynote"]))
    }
}
