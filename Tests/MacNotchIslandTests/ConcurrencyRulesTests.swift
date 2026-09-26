import XCTest
@testable import MacNotchIsland

/// The rules that decide what an answer coming back from another thread may still do once it
/// lands on the main one: whose weather it is, which Now Playing report goes out, whether the
/// camera list, a capture or a Bluetooth card is still wanted, which half of a level a reading of
/// the sound devices may set, whether the network list's next pass sweeps, and when the AirPods'
/// route and the paired list are read again.
final class ConcurrencyRulesTests: XCTestCase {

    // MARK: - The weather

    /// A forecast asked for before Location was refused, or before a newer one, is not shown.
    func testOnlyTheForecastAskedForLastIsShown() {
        XCTAssertTrue(WeatherService.takesForecast(request: 4, current: 4, state: .loading))
        XCTAssertTrue(WeatherService.takesForecast(request: 4, current: 4, state: .ready), "a refresh over a reading")
        XCTAssertFalse(WeatherService.takesForecast(request: 3, current: 4, state: .loading),
                       "cancelled by the fetch after it, and landed anyway")
    }

    func testNoForecastIsShownWhileLocationIsRefused() {
        XCTAssertFalse(WeatherService.takesForecast(request: 4, current: 4, state: .denied),
                       "the weather must not come back over the Allow Location offer")
        XCTAssertFalse(WeatherService.takesForecast(request: 3, current: 4, state: .denied))
    }

    // MARK: - Now Playing

    func testAReportGoesOutOnlyIfNewerThanTheLastThatDid() {
        XCTAssertTrue(MediaRemoteBackend.delivers(1, after: 0), "the first")
        XCTAssertTrue(MediaRemoteBackend.delivers(5, after: 3), "a gap is reports still on their way")
        XCTAssertFalse(MediaRemoteBackend.delivers(3, after: 3), "never twice")
        XCTAssertFalse(MediaRemoteBackend.delivers(2, after: 3), "overtaken")
    }

    /// Quitting a player: its last track report waits on two more answers, and the empty report
    /// behind it goes out first. The track, landing after, stays out, so the card does not come
    /// back for the player that has gone.
    func testTheTrackOfAPlayerThatQuitDoesNotLandOnTopOfNothingPlaying() {
        var delivered = 0
        var shown: [String] = []
        func land(_ number: Int, _ what: String) {
            guard MediaRemoteBackend.delivers(number, after: delivered) else { return }
            delivered = number
            shown.append(what)
        }
        land(2, "nothing")
        land(1, "track")
        XCTAssertEqual(shown, ["nothing"])
    }

    // MARK: - The mirror

    func testTheCameraListIsActedOnOnlyForTheLatestStartWithAViewAwake() {
        XCTAssertTrue(CameraPreview.listingStillWanted(asked: 2, current: 2, clients: 1, asleep: false))
        XCTAssertFalse(CameraPreview.listingStillWanted(asked: 2, current: 3, clients: 1, asleep: false),
                       "stopped, or stopped and started again, while the list was being taken")
        XCTAssertFalse(CameraPreview.listingStillWanted(asked: 2, current: 2, clients: 0, asleep: false),
                       "nobody left looking")
        XCTAssertFalse(CameraPreview.listingStillWanted(asked: 2, current: 2, clients: 1, asleep: true),
                       "the Mac went to sleep")
    }

    // MARK: - The network list

    /// The timer asks for a sweep while a pass for a change of network is out: the pass after it
    /// sweeps, rather than reading the cache and saying "Nothing in range" without "Looking…".
    func testASweepAskedForWhileAPlainReadIsOutIsTheNextPass() {
        var pass = SweepPass()
        XCTAssertTrue(pass.start(scan: false), "the change of network goes first")
        XCTAssertFalse(pass.start(scan: true), "the timer stands down")
        XCTAssertEqual(pass.finish(), true, "and its sweep is the next pass")
        XCTAssertTrue(pass.start(scan: true))
        XCTAssertNil(pass.finish(), "with nobody behind it")
    }

    func testOneAskForASweepAmongSeveralMakesTheNextPassASweep() {
        var pass = SweepPass()
        XCTAssertTrue(pass.start(scan: false))
        XCTAssertFalse(pass.start(scan: false))
        XCTAssertFalse(pass.start(scan: true))
        XCTAssertFalse(pass.start(scan: false), "a plain read after it does not take the sweep back")
        XCTAssertEqual(pass.finish(), true)
    }

    func testPlainReadsAskedForBehindAPassAreAPlainRead() {
        var pass = SweepPass()
        XCTAssertTrue(pass.start(scan: true), "a sweep out")
        XCTAssertFalse(pass.start(scan: false))
        XCTAssertEqual(pass.finish(), false, "a read of what that sweep found")
        XCTAssertTrue(pass.start(scan: false))
        XCTAssertNil(pass.finish())
        XCTAssertTrue(pass.start(scan: false), "and a sweep asked for once is not carried into later passes")
        XCTAssertNil(pass.finish())
    }

    // MARK: - The sound devices

    private let nothing: AudioOutputs.LevelParts = []

    /// The output was switched, and the level moved on the new one while the reading that moved
    /// the listeners was on its way back: its listener showed the new level first, and the
    /// reading must not put the older one back.
    func testANewOutputsLevelHeardSinceTheReadingWasAskedForIsKept() {
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: true, wroteRecently: false, shownVolume: 0.4, shownHasMute: true,
                                               readVolume: 0.7, readMute: false, movedSinceAsked: .all),
                       nothing)
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: true, wroteRecently: true, shownVolume: 0.4, shownHasMute: true,
                                               readVolume: 0.7, readMute: false, movedSinceAsked: .volume),
                       AudioOutputs.LevelParts.mute,
                       "the slider's write stays; the mute is still the old output's, and the reading's to set")
    }

    func testNothingSetSinceTheAskLeavesTheReadingAsItWas() {
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: true, wroteRecently: false, shownVolume: 0.4, shownHasMute: true,
                                               readVolume: 0.7, readMute: false, movedSinceAsked: nothing),
                       AudioOutputs.LevelParts.all)
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: false, wroteRecently: false, shownVolume: 0.4, shownHasMute: true,
                                               readVolume: 0.7, readMute: false, movedSinceAsked: nothing),
                       nothing)
    }

    /// AirPods picked as the output with no level yet: the listener heard nothing to show, and
    /// the reading still fills in what it has.
    func testAHalfStillMissingIsFilledInWhateverWasSetSince() {
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: true, wroteRecently: false, shownVolume: nil, shownHasMute: false,
                                               readVolume: 0.5, readMute: false, movedSinceAsked: .all),
                       AudioOutputs.LevelParts.all)
        XCTAssertEqual(AudioOutputs.showsLevel(rebound: false, wroteRecently: false, shownVolume: nil, shownHasMute: true,
                                               readVolume: 0.5, readMute: false, movedSinceAsked: .all),
                       AudioOutputs.LevelParts.volume, "the same output fills in as it always did")
    }

    /// Only a set for the output the reading found counts. A listener still on the old output,
    /// heard as the switch was made, is older than the reading of the new one.
    func testOnlyASetForTheOutputTheReadingFoundHoldsItBack() {
        XCTAssertTrue(AudioOutputs.setSinceAsked(sets: 5, atAsk: 4, setFor: 70, output: 70))
        XCTAssertFalse(AudioOutputs.setSinceAsked(sets: 5, atAsk: 4, setFor: 61, output: 70),
                       "the old output's level, not the new one's")
        XCTAssertFalse(AudioOutputs.setSinceAsked(sets: 4, atAsk: 4, setFor: 70, output: 70), "nothing since")
    }

    // MARK: - The AirPods' route

    /// A card for a pair that connects answers from the route on screen only when that route
    /// already has the pair, and was read within a beat of the poll.
    func testTheCardAnswersFromAFreshReadingThatHasThePair() {
        let beat = AirPodsControl.pollInterval
        XCTAssertTrue(AirPodsControl.answersFromShown(drives: true, shownAt: 100, now: 100 + beat / 2))
        XCTAssertFalse(AirPodsControl.answersFromShown(drives: true, shownAt: 100, now: 100 + beat),
                       "a beat old: read again")
        XCTAssertFalse(AirPodsControl.answersFromShown(drives: false, shownAt: 100, now: 100.1),
                       "a reading without the pair may be from before it joined the route")
        XCTAssertFalse(AirPodsControl.answersFromShown(drives: true, shownAt: LocalWrite.never, now: 100),
                       "nothing read yet")
        XCTAssertFalse(AirPodsControl.answersFromShown(drives: true, shownAt: 100, now: 99),
                       "a stamp from ahead of now is not taken as fresh")
    }

    // MARK: - The paired list

    /// The island's menu reads the list at most once a poll, never before the tour, and never
    /// while a read is out.
    func testTheMenuReadsThePairedListOnlyWhenItIsAPollOld() {
        let poll = PairedDevices.pollInterval
        XCTAssertTrue(PairedDevices.wantsOneShot(hasSeenWelcome: true, running: false, readAt: LocalWrite.never, now: 50),
                      "never read")
        XCTAssertTrue(PairedDevices.wantsOneShot(hasSeenWelcome: true, running: false, readAt: 50, now: 50 + poll))
        XCTAssertFalse(PairedDevices.wantsOneShot(hasSeenWelcome: true, running: false, readAt: 50, now: 50 + poll / 2),
                       "the list on hand is new enough")
        XCTAssertFalse(PairedDevices.wantsOneShot(hasSeenWelcome: true, running: true, readAt: LocalWrite.never, now: 50),
                       "one is out already")
        XCTAssertFalse(PairedDevices.wantsOneShot(hasSeenWelcome: false, running: false, readAt: LocalWrite.never, now: 50),
                       "nothing Bluetooth before the tour")
    }

    // MARK: - Switched off while an answer was on its way

    func testACaptureIsAnnouncedOnlyInTheRunThatReadIt() {
        XCTAssertTrue(ScreenshotMonitor.announces(run: 3, current: 3, announcing: true))
        XCTAssertFalse(ScreenshotMonitor.announces(run: 3, current: 4, announcing: false), "switched off")
        XCTAssertFalse(ScreenshotMonitor.announces(run: 3, current: 5, announcing: true), "off and on again")
    }

    func testABluetoothCardGoesUpOnlyInTheRunThatHeardTheConnection() {
        XCTAssertTrue(BluetoothMonitor.stillShows(heardIn: 1, run: 1, running: true))
        XCTAssertFalse(BluetoothMonitor.stillShows(heardIn: 1, run: 2, running: false), "stopped")
        XCTAssertFalse(BluetoothMonitor.stillShows(heardIn: 1, run: 3, running: true), "stopped and started again")
    }
}
