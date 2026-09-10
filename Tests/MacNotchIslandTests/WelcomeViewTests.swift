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
    // MARK: - A menu that states a figure the app is not using

    func testAFigureLeftBehindByAnOlderBuildIsBroughtIntoLine() {
        // The menus snapped a stored value to the nearest option for display only, so the pane
        // could read "70%" while the battery went on alerting at 50 — a pane stating a number
        // the app is not using is worse than one offering no number at all.
        let options: [Double] = [0, 70, 80, 85, 90]
        var stored = 50.0
        SettingsFormat.snap(&stored, to: options)
        XCTAssertEqual(stored, 70, "snapped in the store, not just on screen")
    }

    func testAFigureThatIsAlreadyOneOfTheChoicesIsLeftAlone() {
        let options: [Double] = [0, 70, 80, 85, 90]
        var stored = 85.0
        SettingsFormat.snap(&stored, to: options)
        XCTAssertEqual(stored, 85)
        var off = 0.0
        SettingsFormat.snap(&off, to: options)
        XCTAssertEqual(off, 0, "and off is a choice like any other")
    }
}
