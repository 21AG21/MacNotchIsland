import XCTest
@testable import MacNotchIsland

/// The buttons beside play: which four places are filled, how the row is laid out, which
/// buttons a player honours, and where a press goes.
final class TransportSlotTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func track(bundle: String? = "com.apple.Music", duration: TimeInterval = 200, elapsed: TimeInterval = 100,
                       playing: Bool = false, shuffle: Bool? = nil, repeatMode: NowPlayingInfo.RepeatMode? = nil,
                       remote: Set<NowPlayingInfo.Command>? = nil) -> NowPlayingInfo {
        var info = NowPlayingInfo(title: "Song", artist: "Band", album: "", duration: duration, elapsed: elapsed, timestamp: t0,
                                  isPlaying: playing, bundleID: bundle, artwork: nil, artworkID: 0, accent: .white)
        info.shuffle = shuffle
        info.repeatMode = repeatMode
        info.remoteSupports = remote
        return NowPlayingService.sanitized(info)
    }

    // MARK: - Four places

    func testOutOfTheBoxAllFourAreEmpty() {
        XCTAssertEqual(TransportSlot.defaults.map(\.rawValue), ["none", "none", "none", "none"])
        XCTAssertEqual(TransportSlot.resolved(stored: TransportSlot.defaults.map(\.rawValue)), TransportSlot.defaults)
    }

    func testWhatIsStoredBecomesExactlyFourPlaces() {
        XCTAssertEqual(TransportSlot.resolved(stored: []), TransportSlot.defaults, "nothing stored is nothing chosen")
        XCTAssertEqual(TransportSlot.resolved(stored: ["back15", "shuffle", "repeat", "forward15"]),
                       [.back15, .shuffle, .cycleRepeat, .forward15])
        XCTAssertEqual(TransportSlot.resolved(stored: ["favourite"]), [.favourite, .empty, .empty, .empty], "short is filled out")
        XCTAssertEqual(TransportSlot.resolved(stored: ["shuffle", "repeat", "back15", "forward15", "favourite", "none"]),
                       [.shuffle, .cycleRepeat, .back15, .forward15], "long is cut at four")
    }

    func testANameThisBuildDoesNotKnowIsAnEmptyPlace() {
        XCTAssertEqual(TransportSlot.resolved(stored: ["lyrics", "favourite", "", "SHUFFLE"]),
                       [.empty, .favourite, .empty, .empty])
    }

    func testTheSameButtonTwiceIsOneButton() {
        XCTAssertEqual(TransportSlot.resolved(stored: ["shuffle", "none", "shuffle", "repeat"]),
                       [.shuffle, .empty, .empty, .cycleRepeat], "the first place keeps it")
    }

    func testChoosingAButtonAlreadyInTheRowMovesIt() {
        let row: [TransportSlot] = [.shuffle, .empty, .empty, .cycleRepeat]
        XCTAssertEqual(TransportSlot.placing(.shuffle, at: 3, in: row), [.empty, .empty, .empty, .shuffle])
        XCTAssertEqual(TransportSlot.placing(.back15, at: 1, in: row), [.shuffle, .back15, .empty, .cycleRepeat])
        XCTAssertEqual(TransportSlot.placing(.empty, at: 0, in: row), [.empty, .empty, .empty, .cycleRepeat])
        XCTAssertEqual(TransportSlot.placing(.back15, at: 7, in: row), row, "there is no eighth place")
    }

    // MARK: - The row as drawn

    func testNothingChosenIsTheThreeButtonsAlone() {
        let sides = TransportSlot.sides(TransportSlot.defaults)
        XCTAssertEqual(sides.left, [])
        XCTAssertEqual(sides.right, [])
    }

    func testPlayStaysInTheMiddle() {
        let one = TransportSlot.sides([.shuffle, .empty, .empty, .empty])
        XCTAssertEqual(one.left, [.shuffle])
        XCTAssertEqual(one.right, [.empty], "a blank on the far side balances it")

        let podcast = TransportSlot.sides([.empty, .back15, .forward15, .empty])
        XCTAssertEqual(podcast.left, [.back15])
        XCTAssertEqual(podcast.right, [.forward15])

        let lopsided = TransportSlot.sides([.favourite, .shuffle, .empty, .cycleRepeat])
        XCTAssertEqual(lopsided.left, [.favourite, .shuffle])
        XCTAssertEqual(lopsided.right, [.cycleRepeat, .empty], "the blank goes on the outer edge")

        let rightOnly = TransportSlot.sides([.empty, .empty, .empty, .cycleRepeat])
        XCTAssertEqual(rightOnly.left, [.empty])
        XCTAssertEqual(rightOnly.right, [.cycleRepeat])
    }

    // MARK: - What a player honours

    func testABrowserTakesTheSkipsAndNothingElse() {
        let safari = track(bundle: "com.apple.Safari")
        XCTAssertEqual(safari.supports, [.back15, .forward15])
        XCTAssertFalse(TransportSlot.shuffle.isSupported(by: safari))
        XCTAssertTrue(TransportSlot.back15.isSupported(by: safari))
        XCTAssertFalse(TransportSlot.empty.isSupported(by: safari))
    }

    func testALiveStreamHasNoPlaceToSkipTo() {
        let radio = track(bundle: "com.apple.Safari", duration: .infinity)
        XCTAssertEqual(radio.duration, 0)
        XCTAssertFalse(radio.supports.contains(.forward15), "worked out after the infinite length was made nothing")
    }

    func testMusicAndSpotifyTakeWhatAppleScriptCanDo() {
        XCTAssertEqual(track(bundle: "com.apple.Music").supports, [.shuffle, .cycleRepeat, .like, .back15, .forward15])
        XCTAssertEqual(track(bundle: "com.spotify.client").supports, [.shuffle, .cycleRepeat, .back15, .forward15],
                       "Spotify's dictionary has no favourite")
    }

    func testAModeReportedIsAModeHonoured() {
        let other = track(bundle: "com.example.player", shuffle: false)
        XCTAssertTrue(other.supports.contains(.shuffle), "a player that says its shuffle is off has a shuffle")
        XCTAssertFalse(other.supports.contains(.cycleRepeat))
    }

    func testMediaRemotesListIsHonoured() {
        let podcasts = track(bundle: "com.apple.podcasts", remote: [.like])
        XCTAssertTrue(podcasts.supports.contains(.like))
        XCTAssertFalse(podcasts.supports.contains(.shuffle))
    }

    func testTheRuleOnItsOwn() {
        XCTAssertEqual(NowPlayingInfo.supportedCommands(remote: nil, shuffle: nil, repeatMode: nil, bundleID: nil, duration: 0), [])
        XCTAssertEqual(NowPlayingInfo.supportedCommands(remote: [.cycleRepeat], shuffle: nil, repeatMode: nil, bundleID: nil, duration: 0),
                       [.cycleRepeat])
        XCTAssertEqual(NowPlayingInfo.supportedCommands(remote: [], shuffle: nil, repeatMode: .off, bundleID: nil, duration: 30),
                       [.cycleRepeat, .back15, .forward15])
    }

    // MARK: - MediaRemote's numbers

    func testTheModesAsMediaRemoteReportsThem() {
        XCTAssertNil(NowPlayingInfo.shuffle(fromRemote: nil))
        XCTAssertNil(NowPlayingInfo.shuffle(fromRemote: 0), "zero is unknown")
        XCTAssertEqual(NowPlayingInfo.shuffle(fromRemote: 1), false)
        XCTAssertEqual(NowPlayingInfo.shuffle(fromRemote: 2), true, "albums")
        XCTAssertEqual(NowPlayingInfo.shuffle(fromRemote: 3), true, "songs")
        XCTAssertEqual(NowPlayingInfo.repeatMode(fromRemote: 1), .off)
        XCTAssertEqual(NowPlayingInfo.repeatMode(fromRemote: 2), .one)
        XCTAssertEqual(NowPlayingInfo.repeatMode(fromRemote: 3), .all)
        XCTAssertNil(NowPlayingInfo.repeatMode(fromRemote: 0))
        XCTAssertNil(NowPlayingInfo.repeatMode(fromRemote: 9))
        for mode in NowPlayingInfo.RepeatMode.allCases {
            XCTAssertEqual(NowPlayingInfo.repeatMode(fromRemote: NowPlayingInfo.remoteCode(repeat: mode)), mode)
        }
        XCTAssertEqual(NowPlayingInfo.shuffle(fromRemote: NowPlayingInfo.remoteCode(shuffle: true)), true)
        XCTAssertEqual(NowPlayingInfo.shuffle(fromRemote: NowPlayingInfo.remoteCode(shuffle: false)), false)
    }

    func testTheSupportedCommandList() {
        XCTAssertEqual(NowPlayingInfo.commands(fromRemote: [0, 1, 2, 4, 5, 6, 7, 21, 999]), [.shuffle, .cycleRepeat, .like])
        XCTAssertEqual(NowPlayingInfo.commands(fromRemote: [26]), [.shuffle])
        XCTAssertEqual(NowPlayingInfo.commands(fromRemote: [25]), [.cycleRepeat])
        XCTAssertEqual(NowPlayingInfo.commands(fromRemote: [0, 1, 2]), [], "play and pause are not buttons beside play")
    }

    func testTheHelpersPayloadIsReadAndAnOlderOneIsNot() {
        var info = track(bundle: nil)
        AdapterBackend.readModes(from: ["kMRMediaRemoteNowPlayingInfoShuffleMode": NSNumber(value: 3),
                                        "kMRMediaRemoteNowPlayingInfoRepeatMode": NSNumber(value: 2),
                                        "supportedCommands": [NSNumber(value: 6), NSNumber(value: 21)]], into: &info)
        XCTAssertEqual(info.shuffle, true)
        XCTAssertEqual(info.repeatMode, .one)
        XCTAssertEqual(info.remoteSupports, [.shuffle, .like])

        var older = track(bundle: nil)
        AdapterBackend.readModes(from: ["kMRMediaRemoteNowPlayingInfoTitle": "Song"], into: &older)
        XCTAssertNil(older.shuffle)
        XCTAssertNil(older.repeatMode)
        XCTAssertNil(older.remoteSupports, "no list is not an empty list")
    }

    func testWhatAppleScriptSays() {
        XCTAssertEqual(AppleScriptBackend.scriptedShuffle("true"), true)
        XCTAssertEqual(AppleScriptBackend.scriptedShuffle("false"), false)
        XCTAssertNil(AppleScriptBackend.scriptedShuffle(""))
        XCTAssertNil(AppleScriptBackend.scriptedShuffle("missing value"))
        XCTAssertEqual(AppleScriptBackend.scriptedRepeat("one", spotify: false), .one)
        XCTAssertEqual(AppleScriptBackend.scriptedRepeat("all", spotify: false), .all)
        XCTAssertEqual(AppleScriptBackend.scriptedRepeat("off", spotify: false), .off)
        XCTAssertEqual(AppleScriptBackend.scriptedRepeat("true", spotify: true), .all, "Spotify only says yes")
        XCTAssertEqual(AppleScriptBackend.scriptedRepeat("false", spotify: true), .off)
        XCTAssertNil(AppleScriptBackend.scriptedRepeat("", spotify: false))
    }

    // MARK: - Where a press goes

    func testRepeatStepsTheWayThePlayersDo() {
        XCTAssertEqual(NowPlayingInfo.RepeatMode.off.next, .all)
        XCTAssertEqual(NowPlayingInfo.RepeatMode.all.next, .one)
        XCTAssertEqual(NowPlayingInfo.RepeatMode.one.next, .off)
        XCTAssertEqual(NowPlayingService.nextRepeat(after: .off, bundleID: "com.apple.Music", via: .adapter), .all)
        XCTAssertEqual(NowPlayingService.nextRepeat(after: .off, bundleID: "com.spotify.client", via: .appleScript), .all)
        XCTAssertEqual(NowPlayingService.nextRepeat(after: .all, bundleID: "com.spotify.client", via: .appleScript), .off,
                       "Spotify's AppleScript knows only on and off")
    }

    func testAPressGoesWhereTheTrackCameFrom() {
        let known = track(bundle: "com.apple.Music", shuffle: true)
        XCTAssertEqual(NowPlayingService.route(.shuffle, active: .adapter, info: known), .adapter)
        XCTAssertEqual(NowPlayingService.route(.shuffle, active: .mediaRemote, info: known), .mediaRemote)
        XCTAssertEqual(NowPlayingService.route(.shuffle, active: .appleScript, info: known), .appleScript)
    }

    func testAppleScriptStepsInWhereTheHelperHasNothingToSay() {
        let silent = track(bundle: "com.apple.Music")
        XCTAssertEqual(NowPlayingService.route(.shuffle, active: .adapter, info: silent), .appleScript)
        XCTAssertEqual(NowPlayingService.route(.cycleRepeat, active: .adapter, info: silent), .appleScript)
        XCTAssertEqual(NowPlayingService.route(.like, active: .adapter, info: silent), .appleScript)
        let listed = track(bundle: "com.apple.Music", remote: [.like])
        XCTAssertEqual(NowPlayingService.route(.like, active: .adapter, info: listed), .adapter, "the helper said it can")
        let spotify = track(bundle: "com.spotify.client")
        XCTAssertEqual(NowPlayingService.route(.like, active: .adapter, info: spotify), .adapter,
                       "AppleScript cannot favourite in Spotify, so there is nowhere better to send it")
        let browser = track(bundle: "com.apple.Safari")
        XCTAssertEqual(NowPlayingService.route(.shuffle, active: .adapter, info: browser), .adapter)
        XCTAssertEqual(NowPlayingService.route(.forward15, active: .adapter, info: silent), .adapter)
    }

    // MARK: - The heart, both ways

    func testAnEmptyHeartFavouritesWhereEveryOtherPressGoes() {
        let music = track(bundle: "com.apple.Music")
        XCTAssertEqual(NowPlayingService.heartPress(liked: false, active: .adapter, info: music), .favourite(.appleScript))
        let listed = track(bundle: "com.apple.Music", remote: [.like])
        XCTAssertEqual(NowPlayingService.heartPress(liked: false, active: .adapter, info: listed), .favourite(.adapter))
        let spotify = track(bundle: "com.spotify.client", remote: [.like])
        XCTAssertEqual(NowPlayingService.heartPress(liked: false, active: .mediaRemote, info: spotify), .favourite(.mediaRemote))
    }

    func testALitHeartInMusicIsTakenBack() {
        // It could be filled and never emptied: a second press favourited the track again.
        let music = track(bundle: "com.apple.Music")
        XCTAssertEqual(NowPlayingService.heartPress(liked: true, active: .adapter, info: music), .unfavourite(.appleScript))
        let listed = track(bundle: "com.apple.Music", remote: [.like])
        XCTAssertEqual(NowPlayingService.heartPress(liked: true, active: .adapter, info: listed), .unfavourite(.appleScript),
                       "MediaRemote can like a track and cannot unlike one, so the way back is Music's own")
        XCTAssertTrue(NowPlayingInfo.canTakeBackFavourite(bundleID: "com.apple.Music"))
    }

    func testALitHeartNothingCanEmptyIsSettledRatherThanPressedAgain() {
        let spotify = track(bundle: "com.spotify.client", remote: [.like])
        XCTAssertEqual(NowPlayingService.heartPress(liked: true, active: .adapter, info: spotify), .settled,
                       "Spotify's dictionary cannot unsave a track")
        let podcasts = track(bundle: "com.apple.podcasts", remote: [.like])
        XCTAssertEqual(NowPlayingService.heartPress(liked: true, active: .mediaRemote, info: podcasts), .settled)
        XCTAssertFalse(NowPlayingInfo.canTakeBackFavourite(bundleID: nil))
    }

    // MARK: - A mode set by script

    func testAShuffleSetByScriptCanBeSwitchedOffAgain() {
        // The helper says nothing about Music's shuffle, so a press goes to AppleScript, and
        // nothing ever reports back what it set. Read as off, every press asked for on.
        let silent = track(bundle: "com.apple.Music")
        XCTAssertEqual(NowPlayingService.route(.shuffle, active: .adapter, info: silent), .appleScript)
        let memory = NowPlayingService.ScriptedModes.remembering(shuffle: true, in: nil, for: "com.apple.Music")
        guard let kept = memory.after(silent) else { return XCTFail("a report that says nothing forgets nothing") }
        let shown = kept.filling(silent)
        XCTAssertEqual(shown.shuffle, true, "so the next press reads on, and asks for off")
        XCTAssertTrue(TransportSlot.shuffle.isOn(in: shown, liked: false), "and the button stays lit after the press's moment")
        XCTAssertEqual(NowPlayingService.route(.shuffle, active: .adapter, info: shown, scripted: kept), .appleScript,
                       "the next press goes where the last one did, though the mode now looks reported")
        XCTAssertEqual(NowPlayingService.route(.shuffle, active: .adapter, info: shown), .adapter,
                       "which, without the memory, it would not")
    }

    func testRepeatSetByScriptStepsOnFromWhereItWasLeft() {
        func presses(_ bundle: String) -> [NowPlayingInfo.RepeatMode] {
            let silent = track(bundle: bundle)
            var memory: NowPlayingService.ScriptedModes?
            var shown = silent
            var steps: [NowPlayingInfo.RepeatMode] = []
            for _ in 0..<3 {
                // The press, as `cycleRepeat` makes it, then the helper's next report, which
                // still says nothing about repeat.
                let backend = NowPlayingService.route(.cycleRepeat, active: .adapter, info: shown, scripted: memory)
                XCTAssertEqual(backend, .appleScript)
                let target = NowPlayingService.nextRepeat(after: shown.repeatMode ?? .off, bundleID: bundle, via: backend)
                steps.append(target)
                memory = NowPlayingService.ScriptedModes.remembering(repeatMode: target, in: memory, for: bundle)
                memory = memory?.after(silent)
                shown = memory?.filling(silent) ?? silent
            }
            return steps
        }
        XCTAssertEqual(presses("com.apple.Music"), [.all, .one, .off], "not all, all, all")
        XCTAssertEqual(presses("com.spotify.client"), [.all, .off, .all], "Spotify's on and off, not on every time")
    }

    func testThePlayersOwnWordEndsTheMemory() {
        let memory = NowPlayingService.ScriptedModes.remembering(shuffle: true, repeatMode: .all, in: nil, for: "com.apple.Music")
        let saysShuffle = track(bundle: "com.apple.Music", shuffle: false)
        let left = memory.after(saysShuffle)
        XCTAssertNil(left?.shuffle, "a shuffle reported is the player's word")
        XCTAssertEqual(left?.repeatMode, .all, "a repeat it still says nothing about is kept")
        XCTAssertEqual(left?.filling(saysShuffle).shuffle, false, "and what a report does say is never written over")
        XCTAssertNil(memory.after(track(bundle: "com.apple.Music", shuffle: false, repeatMode: .off)), "nothing left is nothing")

        let spotify = track(bundle: "com.spotify.client")
        XCTAssertEqual(memory.after(spotify), memory, "another player's report leaves it alone")
        XCTAssertNil(memory.filling(spotify).shuffle, "and is not filled in from it")
        XCTAssertFalse(memory.holds(.shuffle, in: "com.spotify.client"))
        XCTAssertEqual(NowPlayingService.ScriptedModes.remembering(shuffle: false, in: memory, for: "com.spotify.client"),
                       NowPlayingService.ScriptedModes(bundleID: "com.spotify.client", shuffle: false),
                       "a press in another player starts afresh")
    }

    func testFifteenSecondsIsASeekFromWhereThePlayheadIs() {
        let paused = track(elapsed: 100)
        XCTAssertEqual(NowPlayingService.skipTarget(from: paused, by: 15, now: t0), 115, accuracy: 0.001)
        XCTAssertEqual(NowPlayingService.skipTarget(from: paused, by: -15, now: t0), 85, accuracy: 0.001)
        let playing = track(elapsed: 100, playing: true)
        XCTAssertEqual(NowPlayingService.skipTarget(from: playing, by: 15, now: t0.addingTimeInterval(10)), 125, accuracy: 0.001,
                       "from where it has got to, not where it was last reported")
        XCTAssertEqual(NowPlayingService.skipTarget(from: track(elapsed: 5), by: -15, now: t0), 0, "never before the start")
        XCTAssertEqual(NowPlayingService.skipTarget(from: track(elapsed: 195), by: 15, now: t0), 199, accuracy: 0.001,
                       "a second short of the end")
        let stream = track(bundle: "com.apple.Safari", duration: 0, elapsed: 50)
        XCTAssertEqual(NowPlayingService.skipTarget(from: stream, by: 15, now: t0), 65, accuracy: 0.001)
    }

    // MARK: - What is drawn

    func testTheGlyphsFollowTheModes() {
        XCTAssertEqual(TransportSlot.cycleRepeat.symbol(in: track(repeatMode: .one), liked: false), "repeat.1")
        XCTAssertEqual(TransportSlot.cycleRepeat.symbol(in: track(repeatMode: .all), liked: false), "repeat")
        XCTAssertEqual(TransportSlot.favourite.symbol(in: track(), liked: true), "heart.fill")
        XCTAssertEqual(TransportSlot.favourite.symbol(in: track(), liked: false), "heart")
        XCTAssertTrue(TransportSlot.shuffle.isOn(in: track(shuffle: true), liked: false))
        XCTAssertFalse(TransportSlot.shuffle.isOn(in: track(shuffle: false), liked: false))
        XCTAssertFalse(TransportSlot.cycleRepeat.isOn(in: track(repeatMode: .off), liked: false))
        XCTAssertTrue(TransportSlot.cycleRepeat.isOn(in: track(repeatMode: .one), liked: false))
        XCTAssertEqual(TransportSlot.cycleRepeat.spokenValue(in: track(repeatMode: .one), liked: false), "One track")
    }

    // MARK: - Held against a stale report

    func testAShuffleJustPressedHoldsAgainstTheReportBehindIt() {
        let current = track(shuffle: true)
        let stale = track(shuffle: false)
        let pending = NowPlayingService.Optimistic(isPlaying: nil, elapsed: nil, at: t0, until: t0 + 1.2, shuffle: true)
        XCTAssertEqual(NowPlayingService.reconcile(incoming: stale, current: current, optimistic: pending, now: t0 + 0.3).shuffle, true)
        XCTAssertFalse(NowPlayingService.agrees(stale, with: pending, now: t0 + 0.3))
        XCTAssertTrue(NowPlayingService.agrees(current, with: pending, now: t0 + 0.3))
        XCTAssertEqual(NowPlayingService.reconcile(incoming: stale, current: current, optimistic: pending, now: t0 + 2).shuffle, false,
                       "after the window the player is believed")
    }

    func testAChangedModeIsAChangedReport() {
        XCTAssertNotEqual(track(shuffle: true), track(shuffle: false), "or the button would never redraw")
        XCTAssertNotEqual(track(repeatMode: .one), track(repeatMode: .all))
    }
}
