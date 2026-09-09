import XCTest
@testable import MacNotchIsland

/// External disks: what a drive's card says, which of them a Focus holds back, and which
/// volumes are worth mentioning at all.
final class VolumeMonitorTests: XCTestCase {
    private func drive(_ event: DriveState.Event = .connected,
                       total: Int64 = 1_000_000_000_000,
                       free: Int64 = 238_000_000_000) -> DriveState {
        DriveState(name: "Backup", path: "/Volumes/Backup", total: total, free: free, event: event)
    }

    // MARK: - What the card says

    func testAConnectedDiskSaysHowMuchRoomIsLeft() {
        let state = drive()
        XCTAssertNotNil(state.sizeText)
        XCTAssertTrue(state.subtitle.contains("free of"), state.subtitle)
        XCTAssertEqual(state.symbol, "externaldrive.fill")
    }

    func testADiskWhoseSizeCannotBeReadSaysSoRatherThanZero() {
        let state = drive(total: 0, free: 0)
        XCTAssertNil(state.sizeText, "nothing is known, so nothing is claimed")
        XCTAssertEqual(state.subtitle, "Connected")
        XCTAssertNil(state.fill, "and no bar is drawn for a disk of unknown size")
        XCTAssertEqual(ActivityContent.drive(state).cardHeight, ActivityContent.cardRow)
    }

    func testHowFullItIsIsUsedOverTotal() {
        let state = drive(total: 100, free: 25)
        XCTAssertEqual(state.used, 75)
        XCTAssertEqual(state.fill ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertTrue(state.showsFill)
        XCTAssertEqual(ActivityContent.drive(state).cardHeight, ActivityContent.cardRowWithBar)
    }

    func testADiskThatHasGoneDrawsNoBar() {
        // How full a disk *was* is not news, and a bar under "Safe to unplug" with no buttons
        // beside it reads as a card that has not finished loading.
        for event in [DriveState.Event.ejected, .surprise] {
            let state = drive(event, total: 100, free: 25)
            XCTAssertFalse(state.showsFill, "\(event)")
            XCTAssertEqual(ActivityContent.drive(state).cardHeight, ActivityContent.cardRow)
        }
        XCTAssertTrue(drive(.busy, total: 100, free: 25).showsFill, "it is still plugged in")
    }

    func testFreeSpaceIsNeverNegativeWhateverTheDiskReports() {
        // A volume can report more free than total while it is being written to.
        let state = drive(total: 100, free: 400)
        XCTAssertEqual(state.used, 0)
        XCTAssertEqual(state.fill ?? -1, 0, accuracy: 0.0001)
    }

    func testEachThingThatCanHappenToADiskHasItsOwnWords() {
        XCTAssertEqual(drive(.ejected).subtitle, "Safe to unplug")
        XCTAssertEqual(drive(.ejected).symbol, "eject.fill")
        XCTAssertEqual(drive(.ejected).tint, "green")
        XCTAssertEqual(drive(.surprise).subtitle, "Unplugged before it was ejected")
        XCTAssertEqual(drive(.busy).subtitle, "Something is still using it")
        // The trailing half of the pill has room for a word or two, not a sentence.
        for event in [DriveState.Event.connected, .ejected, .surprise, .busy] {
            XCTAssertLessThanOrEqual(drive(event).trailingText.count, 12, "\(event)")
        }
        // And it says what the figure is, since a size on its own could as easily be the
        // size of the disk as the room left on it.
        XCTAssertTrue(drive().trailingText.hasSuffix(" free"), drive().trailingText)
    }

    // MARK: - How it behaves as an activity

    func testAFocusHoldsADiskArrivingAndNeverOneLeaving() {
        func activity(_ event: DriveState.Event) -> IslandActivity {
            IslandActivity(id: "drive", kind: .drive, content: .drive(drive(event)), priority: 80)
        }
        XCTAssertTrue(ActivityCenter.focusHolds(activity(.connected)), "nobody asked for it")
        // These three answer something the person is doing with their hands right now, and the
        // warning that a disk was pulled out early is the one thing a Focus must not swallow.
        XCTAssertFalse(ActivityCenter.focusHolds(activity(.ejected)))
        XCTAssertFalse(ActivityCenter.focusHolds(activity(.surprise)))
        XCTAssertFalse(ActivityCenter.focusHolds(activity(.busy)))
    }

    func testADiskDoesNotCutOffALowBattery() {
        let disk = IslandActivity(id: "drive", kind: .drive, content: .drive(drive()), priority: 80)
        let flat = IslandActivity(id: "battery", kind: .battery,
                                  content: .battery(BatteryState(percent: 5, isCharging: false,
                                                                 isPluggedIn: false, event: .critical)),
                                  priority: 90)
        XCTAssertLessThan(ActivityCenter.alertRank(disk), ActivityCenter.alertRank(flat))
    }

    func testTheMenuOffersEjectOnADiskAndNothingOnAPlainAlert() {
        XCTAssertTrue(IslandMenu.hasCommands(.drive(drive())))
        XCTAssertFalse(IslandMenu.hasCommands(.custom(CustomActivity(title: "Anything"))))
    }

    // MARK: - Which volumes are worth mentioning

    func testTheBootDiskIsNotADriveAnybodyPluggedIn() {
        // Internal, not removable, not ejectable: the volume the Mac boots from, which is not
        // going anywhere and is not news.
        XCTAssertFalse(VolumeMonitor.isWorthMentioning(internalDisk: true, ejectable: false,
                                                       removable: false, browsable: true))
    }

    func testAnythingSomebodyPluggedInIs() {
        // An external SSD, a card reader's card, and an internal slot that still ejects.
        XCTAssertTrue(VolumeMonitor.isWorthMentioning(internalDisk: false, ejectable: true,
                                                      removable: false, browsable: true))
        XCTAssertTrue(VolumeMonitor.isWorthMentioning(internalDisk: false, ejectable: false,
                                                      removable: true, browsable: true))
        XCTAssertTrue(VolumeMonitor.isWorthMentioning(internalDisk: true, ejectable: true,
                                                      removable: false, browsable: true))
    }

    func testTheMountsNothingCanOpenAreNeverMentioned() {
        // A Mac carries dozens of them, and not one is a drive.
        XCTAssertFalse(VolumeMonitor.isWorthMentioning(internalDisk: false, ejectable: true,
                                                       removable: true, browsable: false))
    }
}
