import Combine
import CoreAudio
import CoreGraphics
import XCTest
@testable import MacNotchIsland

/// The island shows a volume or brightness display only when it has actually taken the media
/// keys over. Two heads-up displays for one keypress is worse than either alone, and it is
/// the first thing anyone notices about an app that lives in the notch.
final class SystemHUDTests: XCTestCase {
    /// The takeover is one object the whole app shares, and the tests below switch it on. Each
    /// of them is given back exactly what it found, whether it got to the end or not, so a
    /// test that runs afterwards never reads a tap this file left standing.
    private var savedActive = false
    private var savedCapabilities = SystemHUDReplacement.Capabilities()

    override func setUp() {
        super.setUp()
        let hud = SystemHUDReplacement.shared
        savedActive = hud.isActive
        savedCapabilities = SystemHUDReplacement.Capabilities(volume: hud.can(\.volume),
                                                             mute: hud.can(\.mute),
                                                             brightness: hud.can(\.brightness))
    }

    override func tearDown() {
        let hud = SystemHUDReplacement.shared
        hud.setCapabilities(savedCapabilities)
        hud.set(savedActive)
        super.tearDown()
    }

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

    /// The banner has one line of room. It spends it on the thing the system's bezel cannot
    /// say, not on the half of the state the figure beside it is already showing.
    func testTheBannerNamesTheOutputRatherThanRepeatingTheState() {
        let pods = AudioOutputs.Device(id: 2, name: "AirPods Pro",
                                       transport: kAudioDeviceTransportTypeBluetooth)
        XCTAssertEqual(LevelHUD.volume(level: 0.6, isMuted: false, output: pods).label, "AirPods Pro")
        let mutedPods = LevelHUD.volume(level: 0, isMuted: true, output: pods)
        XCTAssertEqual(mutedPods.label, "AirPods Pro")
        XCTAssertEqual(LevelHUD.readout(mutedPods), "Muted", "which is where the state is said")

        let built = AudioOutputs.Device(id: 1, name: "MacBook Air Speakers",
                                        transport: kAudioDeviceTransportTypeBuiltIn)
        XCTAssertEqual(LevelHUD.volume(level: 0.6, isMuted: false, output: built).label, "Volume",
                       "naming the Mac's own speakers every time is clutter")
        XCTAssertEqual(LevelHUD(kind: .brightness, level: 0.4).label, "Brightness")
    }

    /// Taking the media key away takes the system's click with it, so the island plays it —
    /// under the user's own setting, with the same Shift gesture the system honours.
    func testTheVolumeClickFollowsTheSettingAndShiftFlipsItForOnePress() {
        XCTAssertTrue(VolumeFeedbackSound.shouldPlay(flags: [], setting: true))
        XCTAssertFalse(VolumeFeedbackSound.shouldPlay(flags: [.maskShift], setting: true))
        XCTAssertFalse(VolumeFeedbackSound.shouldPlay(flags: [], setting: false))
        XCTAssertTrue(VolumeFeedbackSound.shouldPlay(flags: [.maskShift], setting: false))
    }

    /// A tap that is momentarily down is not a Mac that has lost its volume control.
    ///
    /// macOS disables a tap that timed out and the island turns it straight back on. Throwing
    /// the hardware's answers away in between meant that for the seconds until the next probe
    /// every media key went back to the system — bezel and all — which is the doubling this
    /// whole arrangement exists to avoid. `answersVolume` already requires an active tap, so
    /// there is nothing for the answers underneath to say while it is down.
    func testATapGoingDownDoesNotThrowAwayWhatTheHardwareCanDo() {
        // What this leaves behind is put back by `tearDown`, which does it for every test here.
        let hud = SystemHUDReplacement.shared
        hud.set(true)
        hud.setCapabilities(SystemHUDReplacement.Capabilities(volume: true, mute: true, brightness: true))
        XCTAssertTrue(hud.answersVolume)

        hud.set(false)
        XCTAssertTrue(hud.can(\.volume), "the output still has a level; only the tap went away")
        XCTAssertFalse(hud.answersVolume, "and with no tap the island says nothing regardless")

        hud.set(true)
        XCTAssertTrue(hud.answersVolume, "so the keys are answered again the moment it is back")

        hud.forgetCapabilities()
        XCTAssertFalse(hud.can(\.volume), "a real teardown takes the answers with it")
        XCTAssertFalse(hud.isActive)
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
        let now: TimeInterval = 0
        XCTAssertTrue(LocalWrite.isRecent(now - 0.1, now: now),
                      "a write a tenth of a second ago is a slider under the finger")
        XCTAssertFalse(LocalWrite.isRecent(now - 5, now: now),
                       "one from five seconds ago is not")
        XCTAssertFalse(LocalWrite.isRecent(LocalWrite.never, now: now),
                       "and never having written is not either")
    }

    /// Two sliders, two stamps. Wiring one of these to the other's would suppress the wrong
    /// display, and would do it silently.
    func testEachDisplayAsksAboutItsOwnSlider() {
        // Zero, so every stamp written below is older than any real reading of the clock the
        // app uses: these statics are process-wide and shared with the live singletons, and a
        // stamp from the future would have a running listener believe a slider was under the
        // finger for as long as this test took.
        let now: TimeInterval = 0
        // Restored to what was found rather than to "never", for the same reason: a test that
        // tidies up to the wrong value makes the next one order-dependent.
        let savedAudio = AudioOutputs.lastLocalWrite
        let savedBrightness = BrightnessControl.lastLocalWrite
        defer {
            AudioOutputs.markLocalWriteForTesting(savedAudio)
            BrightnessControl.markLocalWriteForTesting(savedBrightness)
        }

        AudioOutputs.markLocalWriteForTesting(now - 0.1)
        BrightnessControl.markLocalWriteForTesting(LocalWrite.never)
        XCTAssertTrue(AudioOutputs.wroteRecently(now: now))
        XCTAssertFalse(BrightnessControl.wroteRecently(now: now),
                       "the volume slider having just moved says nothing about the brightness one")

        AudioOutputs.markLocalWriteForTesting(LocalWrite.never)
        BrightnessControl.markLocalWriteForTesting(now - 0.1)
        XCTAssertFalse(AudioOutputs.wroteRecently(now: now))
        XCTAssertTrue(BrightnessControl.wroteRecently(now: now))
    }

    /// The rail is mounted before it knows what it holds, and everything it holds lands a turn
    /// or two later. Sliding the whole row sideways to make room for those first readings, while
    /// the panel is still growing, is the panel appearing to stumble — but a device plugged in a
    /// minute afterwards is a change like any other, and a change slides.
    func testTheRailAssemblesItselfWithoutAnimatingIntoPlace() {
        let mounted: TimeInterval = 0
        XCTAssertFalse(RailAssembly.slides(mountedAt: nil, now: mounted),
                       "a rail that is not on screen yet has read nothing, so it has nothing to slide")
        XCTAssertFalse(RailAssembly.slides(mountedAt: mounted, now: mounted + RailAssembly.window / 2),
                       "the readings landing while the panel is still opening is the rail filling in")
        XCTAssertTrue(RailAssembly.slides(mountedAt: mounted, now: mounted + RailAssembly.window + 1),
                      "and headphones plugged into a rail that is already there still slide it over")
    }

    /// Which screen the brightness means, and so whether this Mac has a brightness to show a
    /// slider for at all. The window server's list is in no order worth relying on, and an
    /// external-only desk is not a dim built-in display.
    func testTheBrightnessMeansTheBuiltInScreenRatherThanWhicheverIsListedFirst() {
        let ids: [CGDirectDisplayID] = [4, 7, 2]
        XCTAssertEqual(BrightnessMonitor.builtInDisplay(in: ids, isBuiltIn: { $0 == 7 }), 7,
                       "the built-in panel, wherever in the list it turned up")
        XCTAssertNil(BrightnessMonitor.builtInDisplay(in: ids, isBuiltIn: { _ in false }),
                     "a desk with nothing built into it has no brightness of its own to set")
        XCTAssertNil(BrightnessMonitor.builtInDisplay(in: [], isBuiltIn: { _ in true }),
                     "and neither has one with the lid shut and nothing plugged in")
    }

    /// The tap is probed over and over — every few seconds, and again after every wake — and
    /// `set(_:)` is told the answer each time, whether it is the same answer or not. Every
    /// view that draws a volume or a brightness display watches this, so an announcement for a
    /// change that did not happen is the whole island laid out again for nothing.
    func testTheTakeoverIsAnnouncedOnlyWhenItHasActuallyChanged() {
        let hud = SystemHUDReplacement.shared
        hud.set(false)
        var announced = 0
        let watching = hud.objectWillChange.sink { _ in announced += 1 }
        defer { watching.cancel() }

        hud.set(true)
        XCTAssertTrue(hud.isActive, "the tap is up, so the island is standing in for the bezel")
        XCTAssertEqual(announced, 1)
        hud.set(true)
        hud.set(true)
        XCTAssertEqual(announced, 1, "a probe finding the tap still up is not news")

        hud.set(false)
        XCTAssertFalse(hud.isActive, "and with the tap gone the system's own bezel is back")
        XCTAssertEqual(announced, 2)
        hud.set(false)
        XCTAssertEqual(announced, 2, "nor is finding it still down")
    }
}
