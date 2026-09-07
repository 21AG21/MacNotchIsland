import XCTest
@testable import MacNotchIsland

final class ShortcutsRunnerTests: XCTestCase {
    func testDefaultSymbolKeywordMapping() {
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "Focus Mode"), "moon.fill")
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "Toggle WiFi"), "wifi")
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "Bluetooth Off"), "bolt.horizontal")
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "Dark Mode"), "circle.lefthalf.filled")
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "Light Mode"), "circle.lefthalf.filled")
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "Take Screenshot"), "camera.viewfinder")
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "Do Something Else"), "bolt.fill")
    }

    func testDefaultSymbolIsCaseInsensitive() {
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "FOCUS TIME"), "moon.fill")
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "wifi toggle"), "wifi")
        XCTAssertEqual(ShortcutsRunner.defaultSymbol(for: "SCREENSHOT area"), "camera.viewfinder")
    }

    func testParseListTrimsAndDropsEmpties() {
        let output = "Morning Routine\n  Focus On  \n\nScreenshot\n   \nDark Mode\n"
        XCTAssertEqual(ShortcutsRunner.parseList(output), ["Morning Routine", "Focus On", "Screenshot", "Dark Mode"])
    }

    func testParseListEmptyOutput() {
        XCTAssertEqual(ShortcutsRunner.parseList(""), [])
        XCTAssertEqual(ShortcutsRunner.parseList("\n\n   \n"), [])
    }
}
