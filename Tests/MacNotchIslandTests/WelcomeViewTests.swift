import XCTest
@testable import MacNotchIsland

/// The tour's second page offers seven things, and all seven have to be on the screen at
/// once. They only are while the line under each name is a single line.
final class WelcomeViewTests: XCTestCase {
    func testEveryChoiceIsOfferedOnPageTwo() {
        XCTAssertEqual(WelcomeView.ChoiceLine.all.count, 7)
        XCTAssertEqual(Set(WelcomeView.ChoiceLine.all).count, 7, "two choices are explained the same way")
    }

    func testTheChoicesThatAskMacOSForSomethingSaySo() {
        // Today asks for the calendar and the last one asks for Accessibility, both the
        // moment the tour is done: the tour is where a person is told that, or nowhere.
        XCTAssertTrue(WelcomeView.ChoiceLine.today.hasSuffix("Asks for access."))
        XCTAssertTrue(WelcomeView.ChoiceLine.keys.hasSuffix("Asks for access."),
                      "the volume and brightness keys are answered by an event tap, which needs Accessibility")
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

    // MARK: - A slider that governed almost nothing

    func testAtItsShippingFigureTheAlertSliderChangesNothing() {
        // Every caller names its own length, and at the shipping figure each is exactly what
        // it asked for — which is also what keeps the rest of the suite's timings honest.
        XCTAssertEqual(ActivityCenter.standardAlertDuration, 1.8, "the figure Preferences ships with; the two must agree")
        XCTAssertEqual(ActivityCenter.alertDuration(requested: 4, preference: 1.8), 4)
        XCTAssertEqual(ActivityCenter.alertDuration(requested: 1.0, preference: 1.8), 1.0)
        XCTAssertEqual(ActivityCenter.alertDuration(requested: 0.15, preference: 1.8), 0.15)
    }

    func testMovingTheSliderMovesEveryAlertInProportion() {
        // Dragging it to six seconds used to change nothing anybody could see, because the
        // preference was only the fallback for a caller that named no length.
        XCTAssertEqual(ActivityCenter.alertDuration(requested: 4, preference: 3.6), 8, accuracy: 0.001,
                       "double the slider, double the download banner")
        XCTAssertEqual(ActivityCenter.alertDuration(requested: 1.5, preference: 0.9), 0.75, accuracy: 0.001,
                       "and halving it halves a HUD")
        XCTAssertEqual(ActivityCenter.alertDuration(requested: nil, preference: 6), 6,
                       "an alert with no length of its own gets the slider's figure, as it always did")
        XCTAssertGreaterThan(ActivityCenter.alertDuration(requested: 4, preference: 6), 4,
                             "the download banner does stay longer at six")
    }

    func testTheSliderIsAScaleNotAFloorSoTheCallersOrderSurvivesIt() {
        // A copied line is briefer than a finished download at every point on the slider; a
        // floor would have made them the same length the moment it was raised.
        for preference in [1.0, 1.8, 3.0, 6.0] {
            let copied = ActivityCenter.alertDuration(requested: 1.0, preference: preference)
            let hud = ActivityCenter.alertDuration(requested: 1.5, preference: preference)
            let download = ActivityCenter.alertDuration(requested: 4, preference: preference)
            XCTAssertLessThan(copied, hud, "at \(preference)")
            XCTAssertLessThan(hud, download, "at \(preference)")
        }
    }

    func testAFigureNobodyCouldHaveSetOnTheSliderIsIgnored() {
        // A defaults entry edited by hand to nought would dismiss everything on arrival.
        XCTAssertEqual(ActivityCenter.alertDuration(requested: 4, preference: 0), 4)
        XCTAssertEqual(ActivityCenter.alertDuration(requested: nil, preference: -1), ActivityCenter.standardAlertDuration)
        XCTAssertEqual(ActivityCenter.alertDuration(requested: 2, preference: .nan), 2)
        XCTAssertEqual(ActivityCenter.alertDuration(requested: 2, preference: .infinity), 2)
    }
}
