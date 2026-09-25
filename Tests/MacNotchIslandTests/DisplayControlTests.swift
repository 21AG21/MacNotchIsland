import CoreGraphics
import XCTest
@testable import MacNotchIsland

/// The Display popover's rules, without a display to ask: which displays get a slider, and how
/// Night Shift's switch is read out of the status the private client fills in.
final class DisplayControlTests: XCTestCase {
    private let builtIn: CGDirectDisplayID = 1
    private let studio: CGDirectDisplayID = 5
    private let projector: CGDirectDisplayID = 9

    private func sliders(_ online: [CGDirectDisplayID], builtInAnswers: Bool = true,
                         status: [CGDirectDisplayID: Int32]) -> [CGDirectDisplayID] {
        DisplayControl.sliderDisplays(online: online, isBuiltIn: { $0 == self.builtIn },
                                      builtInAnswers: builtInAnswers, status: { status[$0] })
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
        XCTAssertEqual(sliders([builtIn, studio], builtInAnswers: false, status: [builtIn: 0, studio: 0]), [studio])
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
}
