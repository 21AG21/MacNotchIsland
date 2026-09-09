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

    func testTheSameNameIsNeverListedTwice() {
        // The name is the identity of a row, a favourite and the argument `shortcuts run`
        // gets. Two of them would be two rows SwiftUI cannot tell apart.
        XCTAssertEqual(ShortcutsRunner.parseList("Tea\nTea\nCoffee\n  Tea  \n"), ["Tea", "Coffee"])
    }

    func testParseListEmptyOutput() {
        XCTAssertEqual(ShortcutsRunner.parseList(""), [])
        XCTAssertEqual(ShortcutsRunner.parseList("\n\n   \n"), [])
    }

    // MARK: - What a failed shortcut says

    func testAFailureWithNothingToSayStillSaysSomething() {
        XCTAssertFalse(ShortcutsRunner.reason(from: nil).isEmpty)
        XCTAssertFalse(ShortcutsRunner.reason(from: "   \n ").isEmpty)
        XCTAssertEqual(ShortcutsRunner.reason(from: nil), ShortcutsRunner.reason(from: ""))
    }

    func testAReasonIsTrimmedAndKeptToOneReadableLine() {
        XCTAssertEqual(ShortcutsRunner.reason(from: "  No such shortcut.  "), "No such shortcut.")
        let long = "The operation could not be completed because the shortcut asked for something this Mac does not have"
        let short = ShortcutsRunner.reason(from: long)
        XCTAssertLessThanOrEqual(short.count, 66, short)
        XCTAssertTrue(short.hasSuffix("…"), short)
        // Cut at a space, so the line never ends mid-word.
        XCTAssertFalse(short.dropLast().hasSuffix(" "), short)
        XCTAssertTrue(long.hasPrefix(String(short.dropLast())), short)
    }

    func testAReasonThatAlreadyFitsIsLeftAlone() {
        let text = "Shortcut “Morning” was not found."
        XCTAssertEqual(ShortcutsRunner.reason(from: text), text)
    }
}
