import XCTest
@testable import MacNotchIsland

/// A card forced up, and what it leaves behind when it goes: the pin that made it the main
/// activity, the alert on screen when the user starts a timer, and what VoiceOver is told
/// meanwhile.
final class ForcedCardRulesTests: XCTestCase {
    private var center: ActivityCenter { ActivityCenter.shared }

    override func setUp() {
        super.setUp()
        IslandTimer.shared.cancelAll()
        center.resetForTesting()
        let p = Preferences.shared
        p.hoverToExpand = true
        p.expandOnIdleHover = true
        p.hoverDelay = 0.01
    }

    override func tearDown() {
        IslandTimer.shared.cancelAll()
        center.resetForTesting()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval) {
        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }

    private func custom(_ id: String, priority: Int = 70, title: String = "X", kind: ActivityKind = .custom) -> IslandActivity {
        IslandActivity(id: id, kind: kind, content: .custom(CustomActivity(title: title)), priority: priority)
    }

    private func rungTimer() -> IslandActivity {
        IslandActivity(id: "timer", kind: .timer,
                       content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(), isFinished: true)), priority: 90)
    }

    private func call() -> IslandActivity {
        custom("call", priority: 100, title: "Call", kind: .call)
    }

    private func finishedDownload() -> IslandActivity {
        let done = DownloadState(name: "movie.mkv", bytes: 100, total: 100, app: "Safari", isComplete: true)
        return IslandActivity(id: "download-done", kind: .download, content: .download(done), priority: 85,
                              presentation: .expanded)
    }

    private func charging() -> IslandActivity {
        let charging = BatteryState(percent: 40, isCharging: true, isPluggedIn: true, event: .pluggedIn)
        return IslandActivity(id: "battery", kind: .battery, content: .battery(charging), priority: 90)
    }

    private func lowBattery() -> IslandActivity {
        let low = BatteryState(percent: 8, isCharging: false, isPluggedIn: false, event: .low)
        return IslandActivity(id: "battery", kind: .battery, content: .battery(low), priority: 90)
    }

    private func airPods() -> IslandActivity {
        IslandActivity(id: "bt", kind: .bluetooth,
                       content: .bluetooth(BluetoothState(name: "AirPods", address: "", symbol: "airpods", batteryLeft: 50)),
                       priority: 85)
    }

    private func volumeHUD() -> IslandActivity {
        IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: 0.5, isMuted: false)), priority: 85)
    }

    private func mute() -> IslandActivity {
        IslandActivity(id: "silent", kind: .silent, content: .silent(SilentState(isSilent: true)), priority: 85)
    }

    // MARK: - The pin a forced card made

    func testThePinAForcedCardMadeGoesWithIt() {
        XCTAssertNil(ActivityCenter.pinAfterForce(pinned: "timer", forcedPin: "timer"), "still the force's own pin")
        XCTAssertEqual(ActivityCenter.pinAfterForce(pinned: "music", forcedPin: "timer"), "music",
                       "the user pinned something else meanwhile, and that stays")
        XCTAssertEqual(ActivityCenter.pinAfterForce(pinned: "music", forcedPin: nil), "music", "the force made no pin")
        XCTAssertNil(ActivityCenter.pinAfterForce(pinned: nil, forcedPin: "timer"))
    }

    /// A timer that rang during a call kept the island for good: the pin its card was forced up
    /// with outlived the card, and ranks above a call.
    func testARingingTimerGivesTheIslandBackToTheCallWhenItsCardGoes() {
        center.upsert(call())
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 0.2)
        guard case .card(let shown) = center.presentation else { return XCTFail("the ringing card") }
        XCTAssertEqual(shown.id, "timer")
        settle(0.5)
        XCTAssertNil(center.forcedExpandedID)
        XCTAssertNil(center.pinnedID, "the pin went with the card")
        XCTAssertEqual(center.primary?.id, "call", "the call has the island again")
    }

    func testAPinTheUserMadeWhileTheCardWasUpStays() {
        center.upsert(custom("music", priority: 50, kind: .nowPlaying))
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 0.2)
        center.promote(id: "music")
        settle(0.5)
        XCTAssertEqual(center.pinnedID, "music", "a click on the bubble is the user's own pin")
    }

    func testAClosedCardTakesItsPinWithIt() {
        center.upsert(call())
        center.upsert(rungTimer())
        center.forceExpanded(id: "timer", for: 5)
        XCTAssertEqual(center.pinnedID, "timer")
        center.collapse()
        XCTAssertNil(center.pinnedID)
        XCTAssertEqual(center.primary?.id, "call")
    }

    // MARK: - The pointer on the card when it goes

    /// Stop pressed on a ringing card with the pointer on it: the Home peek grew under the
    /// pointer at once, and nothing counted it as growth, so the second click of a quick pair
    /// landed on a slot of the switcher. It goes as a close under the pointer does.
    func testACardEndedUnderThePointerLeavesNoPeekUntilThePointerComesBack() {
        center.upsert(rungTimer())
        center.setHovering(true, panel: "main")
        settle(0.1)
        center.forceExpanded(id: "timer", for: 5)
        guard case .card(let card) = center.presentation(for: "main") else { return XCTFail("the ringing card, under the pointer") }
        XCTAssertEqual(card.id, "timer")

        center.end(id: "timer")
        if case .panel = center.presentation(for: "main") { XCTFail("no peek grows where the card was") }
        XCTAssertNil(center.peekView, "and none is kept for later")

        // The pointer, still there, reports itself again: nothing opens.
        center.setHovering(true, panel: "main")
        settle(0.1)
        if case .panel = center.presentation(for: "main") { XCTFail("nor while the pointer stays") }

        center.setHovering(false, panel: "main")
        settle(ActivityCenter.hoverExitGrace + 0.1)
        center.setHovering(true, panel: "main")
        settle(0.1)
        guard case .panel = center.presentation(for: "main") else { return XCTFail("the peek, once it has left and come back") }
    }

    // MARK: - The alert on screen, when the user starts a timer

    func testOnlyABatteryAboutToRunOutKeepsTheIslandFromATimer() {
        XCTAssertTrue(ActivityCenter.alertYields(finishedDownload()))
        XCTAssertTrue(ActivityCenter.alertYields(charging()))
        XCTAssertTrue(ActivityCenter.alertYields(volumeHUD()))
        XCTAssertFalse(ActivityCenter.alertYields(lowBattery()))
    }

    /// `notchctl timer` took down a low-battery warning, and emptied the queue behind whatever
    /// was up.
    func testStartingATimerTakesDownOnlyTheAlertOnScreen() {
        center.showAlert(charging(), duration: 5, haptic: false)
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        XCTAssertEqual(center.pendingAlerts.map(\.activity.id), ["download-done"], "waiting behind the louder one")
        IslandTimer.shared.start(seconds: 600, label: "Tea")
        XCTAssertNil(center.alert, "the alert on screen gives way to the timer")
        XCTAssertEqual(center.pendingAlerts.map(\.activity.id), ["download-done"], "what waited keeps its place")
    }

    /// The alert that gave way was the one whose expiry would have looked at the queue: with it
    /// cancelled, what waited behind it was never shown, and was pruned unseen.
    func testWhatWaitedBehindAYieldedAlertGetsItsTurn() {
        center.showAlert(charging(), duration: 5, haptic: false)
        center.showAlert(finishedDownload(), duration: 5, haptic: false)
        XCTAssertEqual(center.alert?.id, "battery")
        XCTAssertEqual(center.pendingAlerts.map(\.activity.id), ["download-done"])
        center.yieldAlert()
        XCTAssertNil(center.alert, "the alert on screen gives way at once")
        settle(0.1)
        XCTAssertEqual(center.alert?.id, "download-done", "and what waited behind it is shown")
        XCTAssertTrue(center.pendingAlerts.isEmpty)
    }

    func testStartingATimerLeavesALowBatteryWarningUp() {
        center.showAlert(lowBattery(), duration: 5, haptic: false)
        IslandTimer.shared.start(seconds: 600, label: "Tea")
        XCTAssertEqual(center.alert?.id, "battery")
        XCTAssertNotNil(center.activity(id: "timer"), "and the timer starts all the same")
    }

    // MARK: - What VoiceOver is told

    func testOnlyWhatFollowsTheUsersHandIsSaidOverVoiceOver() {
        var peek = custom(NowPlayingService.peekAlertID, title: "Alright")
        peek.kind = .nowPlaying
        XCTAssertFalse(ActivityCenter.alertAnnouncementIsUrgent(peek), "the next track's sneak peek waits its turn")
        XCTAssertFalse(ActivityCenter.alertAnnouncementIsUrgent(custom(LiveActivityAPI.alertID, title: "Deployed")),
                       "so does a script's alert")
        XCTAssertFalse(ActivityCenter.alertAnnouncementIsUrgent(finishedDownload()))
        XCTAssertTrue(ActivityCenter.alertAnnouncementIsUrgent(airPods()), "a device the user just connected")
        XCTAssertTrue(ActivityCenter.alertAnnouncementIsUrgent(custom("copied", title: "Copied")))
        XCTAssertTrue(ActivityCenter.alertAnnouncementIsUrgent(lowBattery()), "a battery about to run out cannot wait")
    }

    func testTheMuteKeyIsFeedbackAndIsNotSaid() {
        XCTAssertFalse(ActivityCenter.speaksAlert(mute()))
        XCTAssertNil(ActivityCenter.alertAnnouncement(from: nil, to: mute()))
    }

    /// While VoiceOver runs an alert stays up three times as long, and a volume press behind it
    /// was queued with two seconds of patience and dropped.
    func testAKeyPressDoesNotWaitBehindAnAlertPastItsOwnTime() {
        XCTAssertTrue(ActivityCenter.waitsBehind(airPods(), arriving: volumeHUD(), shownPastItsTime: false))
        XCTAssertFalse(ActivityCenter.waitsBehind(airPods(), arriving: volumeHUD(), shownPastItsTime: true))
        XCTAssertFalse(ActivityCenter.waitsBehind(airPods(), arriving: mute(), shownPastItsTime: true))
        XCTAssertTrue(ActivityCenter.waitsBehind(charging(), arriving: finishedDownload(), shownPastItsTime: true),
                      "only a key press's feedback")
        XCTAssertFalse(ActivityCenter.waitsBehind(nil, arriving: volumeHUD(), shownPastItsTime: true))
    }

    func testAScriptsOwnLengthIsKeptUnderVoiceOver() {
        XCTAssertTrue(ActivityCenter.lengthensForVoiceOver(airPods(), exact: false, voiceOver: true))
        XCTAssertFalse(ActivityCenter.lengthensForVoiceOver(airPods(), exact: true, voiceOver: true),
                       "three seconds asked for is three seconds")
        XCTAssertFalse(ActivityCenter.lengthensForVoiceOver(airPods(), exact: false, voiceOver: false))
        XCTAssertFalse(ActivityCenter.lengthensForVoiceOver(mute(), exact: false, voiceOver: true))
    }

    /// Caps Lock's pill was a button to VoiceOver that did nothing when pressed.
    func testAKeyPressPillIsNoButton() {
        let caps = custom("capslock", title: "Caps Lock")
        XCTAssertTrue(ActivityCenter.isTransientHUD(caps, alert: caps))
        XCTAssertTrue(ActivityCenter.isTransientHUD(volumeHUD(), alert: volumeHUD()))
        XCTAssertFalse(ActivityCenter.isTransientHUD(caps, alert: nil), "only while it is the alert up")
        XCTAssertFalse(ActivityCenter.isTransientHUD(airPods(), alert: airPods()), "a card there to be opened")
    }
}
