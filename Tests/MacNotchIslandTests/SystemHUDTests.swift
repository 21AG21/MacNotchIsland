import CoreAudio
import CoreGraphics
import XCTest
@testable import MacNotchIsland

/// The island shows a volume or brightness display only when it has actually taken the media
/// keys over. Two heads-up displays for one keypress is worse than either alone, and it is
/// the first thing anyone notices about an app that lives in the notch.
final class SystemHUDTests: XCTestCase {

    /// The volume display names where the sound is going, which the system's bezel never
    /// does — but only when that is worth saying.
    func testTheVolumeDisplayNamesAnythingButTheMacsOwnSpeakers() {
        let built = AudioOutputs.Device(id: 1, name: "MacBook Air Speakers",
                                        transport: kAudioDeviceTransportTypeBuiltIn)
        XCTAssertNil(LevelHUD.volume(level: 0.5, isMuted: false, output: built).device,
                     "pointing at the built-in speakers every time you touch the volume is clutter")

        let pods = AudioOutputs.Device(id: 2, name: "AirPods Pro",
                                       transport: kAudioDeviceTransportTypeBluetooth)
        let hud = LevelHUD.volume(level: 0.5, isMuted: false, output: pods)
        XCTAssertEqual(hud.device, "AirPods Pro")
        XCTAssertEqual(hud.deviceSymbol, "airpodspro")

        XCTAssertNil(LevelHUD.volume(level: 0.5, isMuted: false, output: nil).device,
                     "a device that cannot be read is not a device worth naming")
    }

    /// Taking the media key away takes the system's click with it, so the island plays it —
    /// under the user's own setting, with the same Shift gesture the system honours.
    func testTheVolumeClickFollowsTheSettingAndShiftFlipsItForOnePress() {
        XCTAssertTrue(VolumeFeedbackSound.shouldPlay(flags: [], setting: true))
        XCTAssertFalse(VolumeFeedbackSound.shouldPlay(flags: [.maskShift], setting: true))
        XCTAssertFalse(VolumeFeedbackSound.shouldPlay(flags: [], setting: false))
        XCTAssertTrue(VolumeFeedbackSound.shouldPlay(flags: [.maskShift], setting: false))
    }

    func testShiftWithOptionIsAQuarterStepRatherThanAskingForSilence() {
        XCTAssertTrue(VolumeFeedbackSound.shouldPlay(flags: [.maskShift, .maskAlternate], setting: true))
        XCTAssertFalse(VolumeFeedbackSound.shouldPlay(flags: [.maskShift, .maskAlternate], setting: false))
    }

    func testAMacThatHasNeverBeenAskedStillClicks() {
        XCTAssertTrue(VolumeFeedbackSound.shouldPlay(flags: [], setting: nil))
    }

    /// A key that cannot do anything says so, rather than being swallowed into silence.
    func testAnOutputWithNoLevelOfItsOwnStillGetsAnAnswer() {
        let display = AudioOutputs.Device(id: 3, name: "Studio Display",
                                          transport: kAudioDeviceTransportTypeDisplayPort)
        let hud = LevelHUD.unavailableVolume(output: display)
        XCTAssertTrue(hud.isUnavailable)
        XCTAssertEqual(hud.device, "Studio Display", "and says which output it is talking about")
        XCTAssertFalse(hud.isMuted, "not being settable is not the same as being off")
    }

    /// A slider you are holding is its own feedback, so the island does not put a display
    /// over it — but only for a change the island itself just made, and only for as long as
    /// the hand is plausibly still on it.
    func testTheIslandKnowsWhenItWasTheOneThatSetTheLevel() {
        let now = Date()
        XCTAssertTrue(LocalWrite.isRecent(now.addingTimeInterval(-0.1), now: now),
                      "a write a tenth of a second ago is a slider under the finger")
        XCTAssertFalse(LocalWrite.isRecent(now.addingTimeInterval(-5), now: now),
                       "one from five seconds ago is not")
        XCTAssertFalse(LocalWrite.isRecent(.distantPast, now: now),
                       "and never having written is not either")
        XCTAssertFalse(LocalWrite.isRecent(now.addingTimeInterval(60), now: now),
                       "nor is one from the future, which is what a clock stepping backwards "
                       + "leaves behind — unbounded, it would swallow every display until the "
                       + "clock caught up")
    }

    /// Two sliders, two stamps. Wiring one of these to the other's would suppress the wrong
    /// display, and would do it silently.
    func testEachDisplayAsksAboutItsOwnSlider() {
        let now = Date()
        defer {
            AudioOutputs.markLocalWriteForTesting(.distantPast)
            BrightnessControl.markLocalWriteForTesting(.distantPast)
        }

        AudioOutputs.markLocalWriteForTesting(now.addingTimeInterval(-0.1))
        BrightnessControl.markLocalWriteForTesting(.distantPast)
        XCTAssertTrue(AudioOutputs.wroteRecently(now: now))
        XCTAssertFalse(BrightnessControl.wroteRecently(now: now),
                       "the volume slider having just moved says nothing about the brightness one")

        AudioOutputs.markLocalWriteForTesting(.distantPast)
        BrightnessControl.markLocalWriteForTesting(now.addingTimeInterval(-0.1))
        XCTAssertFalse(AudioOutputs.wroteRecently(now: now))
        XCTAssertTrue(BrightnessControl.wroteRecently(now: now))
    }

    func testTheIslandStartsOutLeavingTheSystemBezelAlone() {
        XCTAssertFalse(SystemHUDReplacement.shared.isActive,
                       "nothing has installed an event tap in a test run, so the island must not "
                       + "be claiming it has taken the media keys over")
    }
}
