import CoreGraphics
import XCTest
@testable import MacNotchIsland

/// The Display popover's rules, without a display to ask: which displays get a slider, and how
/// Night Shift's switch is read out of the status the private client fills in.
final class DisplayControlTests: XCTestCase {
    private let builtIn: CGDirectDisplayID = 1
    private let studio: CGDirectDisplayID = 5
    private let projector: CGDirectDisplayID = 9

    /// The rail's display is the built-in panel unless a test says otherwise.
    private func sliders(_ online: [CGDirectDisplayID], rail: CGDirectDisplayID? = nil, railAnswers: Bool = true,
                         status: [CGDirectDisplayID: Int32]) -> [CGDirectDisplayID] {
        DisplayControl.sliderDisplays(online: online, isBuiltIn: { $0 == self.builtIn },
                                      railDisplay: rail ?? builtIn, railAnswers: railAnswers, status: { status[$0] })
    }

    func testADisplayThatAnswersGetsASliderAndOneThatRefusesDoesNot() {
        // DisplayServices' status is zero for a display it can set, and anything else for one on
        // the far end of a cable it cannot.
        XCTAssertEqual(sliders([studio, projector], status: [studio: 0, projector: 7]), [studio])
        XCTAssertEqual(sliders([projector], status: [projector: -1]), [], "a slider that does nothing is not drawn")
        XCTAssertEqual(sliders([projector], status: [:]), [], "nor is one for a display that could not even be asked")
    }

    func testTheBuiltInPanelComesFirstAndOnlyWhenItsOwnServiceAnswers() {
        // The window server hands the list back in no particular order; the Mac's own panel is
        // the first slider wherever it is in it.
        XCTAssertEqual(sliders([studio, builtIn], status: [studio: 0]), [builtIn, studio])
        // Its level is `BrightnessControl`'s, so its own reading decides, not a status here.
        XCTAssertEqual(sliders([builtIn, studio], railAnswers: false, status: [builtIn: 0, studio: 0]), [studio])
    }

    /// With the lid shut there is no built-in panel, and the rail's slider drives the main
    /// display. The popover gave that display a slider of its own as well: two sliders and two
    /// pollers for one display.
    func testWithTheLidShutTheMainDisplayIsTheRailsAndGetsOneSlider() {
        let online = [projector, studio]
        let rail = BrightnessMonitor.drivenDisplay(in: online, isBuiltIn: { $0 == self.builtIn }, main: studio)
        XCTAssertEqual(rail, studio, "no built-in panel online: the rail drives the main display")
        let answers: [CGDirectDisplayID: Int32] = [studio: 0, projector: 0]
        var asked: [CGDirectDisplayID] = []
        let ids = DisplayControl.sliderDisplays(online: online, isBuiltIn: { $0 == self.builtIn }, railDisplay: rail,
                                                railAnswers: true, status: { id in
            asked.append(id)
            return answers[id]
        })
        XCTAssertEqual(ids, [studio, projector], "the rail's display first, and once")
        XCTAssertFalse(asked.contains(studio), "and never read here, where a second poller would argue with the rail's")
        XCTAssertEqual(sliders(online, rail: studio, railAnswers: false, status: answers), [projector],
                       "a display the rail cannot read is not handed to the popover to drive instead")
    }

    func testWithTheLidOpenTheRailDrivesTheBuiltInPanelWhereverItIsListed() {
        XCTAssertEqual(BrightnessMonitor.drivenDisplay(in: [studio, builtIn], isBuiltIn: { $0 == self.builtIn }, main: studio),
                       builtIn, "the built-in panel, even with the external display as the main one")
    }

    func testADisplayListedTwiceIsOneSlider() {
        XCTAssertEqual(sliders([studio, studio, builtIn, builtIn], status: [studio: 0]), [builtIn, studio])
    }

    func testNightShiftsSwitchIsTheStatusesSecondByte() {
        // `BOOL active; BOOL enabled; …` — on, whatever the schedule is doing.
        var status = [UInt8](repeating: 0, count: DisplayControl.statusSize)
        XCTAssertEqual(DisplayControl.nightShiftIsOn(status: status), false)
        status[1] = 1
        XCTAssertEqual(DisplayControl.nightShiftIsOn(status: status), true)
        // Active by the schedule but not switched on by hand is not the switch.
        status = [1, 0] + [UInt8](repeating: 0, count: DisplayControl.statusSize - 2)
        XCTAssertEqual(DisplayControl.nightShiftIsOn(status: status), false)
        XCTAssertNil(DisplayControl.nightShiftIsOn(status: [1]), "a buffer too short to hold it says nothing")
        XCTAssertGreaterThanOrEqual(DisplayControl.statusSize, 40, "room for the whole structure and then some")
    }

    // MARK: - The rail's slider, on a second display's island

    func testTheRailOnAMonitorThatAnswersDrivesThatMonitor() {
        XCTAssertEqual(BrightnessControl.railTarget(panelDisplay: studio, driven: builtIn, answering: [studio]), studio)
    }

    func testTheRailOnAMonitorThatDoesNotAnswerDrivesTheBuiltInPanel() {
        XCTAssertNil(BrightnessControl.railTarget(panelDisplay: projector, driven: builtIn, answering: [studio]),
                     "a display DisplayServices cannot set leaves the slider on the built-in panel")
        XCTAssertNil(BrightnessControl.railTarget(panelDisplay: builtIn, driven: builtIn, answering: [builtIn, studio]),
                     "the built-in panel's own island drives it, as it always did")
        XCTAssertNil(BrightnessControl.railTarget(panelDisplay: nil, driven: builtIn, answering: [studio]),
                     "a panel whose display is not known keeps the built-in panel")
        XCTAssertNil(BrightnessControl.railTarget(panelDisplay: studio, driven: nil, answering: []),
                     "and nothing is driven elsewhere before the first reading has landed")
    }

    func testTheSliderSaysWhichDisplayItDrivesWhenItIsNotTheOneUnderIt() {
        XCTAssertEqual(BrightnessControl.sliderLabel(drivenName: "Built-in Retina Display", drivesPanelsOwn: false,
                                                     displaysOnline: 2),
                       "Brightness of Built-in Retina Display")
        XCTAssertEqual(BrightnessControl.sliderLabel(drivenName: "Built-in Retina Display", drivesPanelsOwn: true,
                                                     displaysOnline: 2),
                       "Brightness", "the display under the slider needs no name")
        XCTAssertEqual(BrightnessControl.sliderLabel(drivenName: "Built-in Retina Display", drivesPanelsOwn: false,
                                                     displaysOnline: 1),
                       "Brightness", "nor does the only one there is")
        XCTAssertEqual(BrightnessControl.sliderLabel(drivenName: nil, drivesPanelsOwn: false, displaysOnline: 2), "Brightness")
    }

    /// A drag of a monitor's slider that rests with the button down, on a pass the monitor does
    /// not answer, is still that monitor's drag.
    func testAHoldOnAMonitorsSliderStandsForAsLongAsTheDragDoes() {
        XCTAssertTrue(BrightnessControl.holdStands(until: 10, now: 9, dragging: false), "inside the write's hold")
        XCTAssertFalse(BrightnessControl.holdStands(until: 10, now: 10, dragging: false), "and not a moment past it")
        XCTAssertTrue(BrightnessControl.holdStands(until: 10, now: 15, dragging: true),
                      "a drag resting with the button down keeps it")
        XCTAssertFalse(BrightnessControl.holdStands(until: 10, now: 15, dragging: false),
                       "let go, the monitor that stopped answering is let go too")
    }

    /// Twice a second, on battery and under a lock alike, while every other poller on the rail
    /// backed off.
    func testTheRailsBrightnessPollBacksOffWithTheEnergyPolicy() {
        XCTAssertEqual(BrightnessControl.scaledPollInterval(multiplier: 1), BrightnessControl.pollInterval)
        XCTAssertEqual(BrightnessControl.scaledPollInterval(multiplier: 8), BrightnessControl.pollInterval * 8)
        XCTAssertEqual(BrightnessControl.scaledPollInterval(multiplier: 0), BrightnessControl.pollInterval,
                       "never faster than the daytime rate")
        let locked = EnergyPolicy.pollingMultiplier(asleep: false, lowPower: false, onBattery: false, unattended: true)
        XCTAssertGreaterThanOrEqual(BrightnessControl.scaledPollInterval(multiplier: locked), 4)
    }
}
