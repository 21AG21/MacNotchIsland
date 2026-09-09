import XCTest
@testable import MacNotchIsland

/// The tour's second page offers seven things, and all seven have to be on the screen at
/// once. They only are while the line under each name is a single line.
final class WelcomeViewTests: XCTestCase {
    func testEveryChoiceIsOfferedOnPageTwo() {
        XCTAssertEqual(WelcomeView.ChoiceLine.all.count, 7)
        XCTAssertEqual(Set(WelcomeView.ChoiceLine.all).count, 7, "two choices are explained the same way")
    }

    func testEveryChoiceFitsOnOneLine() {
        // Three of these used to run to two lines, which pushed the seventh under the bottom
        // of the list — and on a Mac with overlay scrollbars there is nothing there to say so
        // until somebody happens to scroll.
        for line in WelcomeView.ChoiceLine.all {
            XCTAssertFalse(line.isEmpty)
            XCTAssertLessThanOrEqual(line.count, WelcomeView.ChoiceLine.limit,
                                     "\"\(line)\" is \(line.count) characters and will wrap")
            XCTAssertTrue(line.hasSuffix("."), "\"\(line)\" should read as a sentence")
        }
    }
}
