import CoreAudio
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

    func testTheIslandStartsOutLeavingTheSystemBezelAlone() {
        XCTAssertFalse(SystemHUDReplacement.shared.isActive,
                       "nothing has installed an event tap in a test run, so the island must not "
                       + "be claiming it has taken the media keys over")
    }
}
