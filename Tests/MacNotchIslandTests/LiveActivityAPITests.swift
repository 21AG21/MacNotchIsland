import XCTest
@testable import MacNotchIsland

final class LiveActivityAPITests: XCTestCase {
    private var center: ActivityCenter { ActivityCenter.shared }

    override func setUp() {
        super.setUp()
        center.resetForTesting()
        IslandTimer.shared.cancel()
        IslandStopwatch.shared.reset()
    }

    private func handle(_ s: String) {
        LiveActivityAPI.shared.handle(URL(string: s)!)
    }

    func testStartUpdateAndEndActivity() {
        handle("notchisland://activity?id=build&title=Building&subtitle=xcodebuild&symbol=hammer.fill&tint=blue&progress=0.4&ring=1&ttl=600&url=https://example.com")
        guard let a = center.activity(id: "api-build"), case .custom(let c) = a.content else { return XCTFail("activity missing") }
        XCTAssertEqual(c.title, "Building")
        XCTAssertEqual(c.subtitle, "xcodebuild")
        XCTAssertEqual(c.symbol, "hammer.fill")
        XCTAssertEqual(c.tint, "blue")
        XCTAssertEqual(c.progress ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertTrue(c.showsRing)
        XCTAssertNotNil(a.expiresAt)
        XCTAssertEqual(a.openAction, .url(URL(string: "https://example.com")!))

        handle("notchisland://activity?id=build&title=Building&progress=0.9")
        guard case .custom(let c2)? = center.activity(id: "api-build")?.content else { return XCTFail() }
        XCTAssertEqual(c2.progress ?? -1, 0.9, accuracy: 0.0001)
        XCTAssertEqual(center.activities.count, 1)

        handle("notchisland://activity/end?id=build")
        XCTAssertNil(center.activity(id: "api-build"))
    }

    func testEndingEveryCardLeavesTheIslandsOwnActivitiesAlone() {
        // The screen recording's activity is `.custom` as well, and carries the only Stop
        // button for a `screencapture` that keeps running whether the card is there or not.
        let recording = ScreenRecorder.activity(since: Date(), saving: false, folder: "Desktop")
        center.upsert(IslandActivity(id: ScreenRecorder.activityID, kind: .custom, content: .custom(recording), priority: 90))
        handle("notchisland://activity?id=build&title=Building")
        handle("notchisland://activity?id=deploy&title=Deploying")
        XCTAssertEqual(center.activities.count, 3)

        handle("notchisland://activity/end")
        XCTAssertNil(center.activity(id: "api-build"))
        XCTAssertNil(center.activity(id: "api-deploy"))
        XCTAssertNotNil(center.activity(id: ScreenRecorder.activityID), "a script ends its own cards, not the island's")
        XCTAssertEqual(center.activities.map(\.id), [ScreenRecorder.activityID])
        center.end(id: ScreenRecorder.activityID)
    }

    func testProgressIsClamped() {
        handle("notchisland://activity?id=x&title=T&progress=7")
        guard case .custom(let c)? = center.activity(id: "api-x")?.content else { return XCTFail() }
        XCTAssertEqual(c.progress, 1)
    }

    func testAlert() {
        handle("notchisland://alert?title=Deployed&symbol=checkmark.circle.fill&tint=green&duration=5")
        guard case .compact(let a, _) = center.presentation, case .custom(let c) = a.content else { return XCTFail("expected alert") }
        XCTAssertEqual(c.title, "Deployed")
        XCTAssertEqual(c.tint, "green")
        XCTAssertTrue(center.activities.isEmpty, "alerts are transient, not live activities")
    }

    func testTimerAndStopwatch() {
        handle("notchisland://timer?minutes=5&label=Tea")
        guard let t = IslandTimer.shared.state else { return XCTFail("timer not started") }
        XCTAssertEqual(t.label, "Tea")
        XCTAssertEqual(t.total, 300)
        XCTAssertNotNil(center.activity(id: "timer"))
        handle("notchisland://timer/pause")
        XCTAssertTrue(IslandTimer.shared.state?.isPaused ?? false)
        handle("notchisland://timer/cancel")
        XCTAssertNil(IslandTimer.shared.state)
        XCTAssertNil(center.activity(id: "timer"))

        handle("notchisland://stopwatch")
        XCTAssertNotNil(IslandStopwatch.shared.state)
        handle("notchisland://stopwatch/lap")
        XCTAssertEqual(IslandStopwatch.shared.state?.laps.count, 1)
        handle("notchisland://stopwatch/stop")
        XCTAssertFalse(IslandStopwatch.shared.state?.isRunning ?? true)
        handle("notchisland://stopwatch/reset")
        XCTAssertNil(IslandStopwatch.shared.state)
    }

    func testUnknownSchemeIsIgnored() {
        handle("https://example.com/activity?id=x&title=T")
        XCTAssertTrue(center.activities.isEmpty)
        XCTAssertEqual(center.presentation, .idle)
    }

    func testHomeAndCollapse() {
        handle("notchisland://home")
        guard case .panel(.home) = center.presentation else { return XCTFail("home opens the panel") }
        handle("notchisland://home?tab=shelf")
        XCTAssertEqual(center.openView, .home(tab: "shelf"))
        handle("notchisland://collapse")
        XCTAssertEqual(center.presentation, .idle)
    }

    func testAURLCannotOpenASectionThatIsSwitchedOff() {
        let prefs = Preferences.shared
        let wasOn = prefs.statsEnabled
        defer { prefs.statsEnabled = wasOn }
        prefs.statsEnabled = false
        handle("notchisland://home/stats")
        // The switcher has no slot for a section that is off, so opening the panel on it
        // would leave the band with nothing lit. The panel opens where it usually does.
        XCTAssertNotEqual(center.openView, .home(tab: "stats"))
        guard case .panel = center.presentation else { return XCTFail("the panel still opens") }
        handle("notchisland://collapse")
    }

    // MARK: - Naming a settings pane

    func testAPaneCanBeNamedTheWayTheSidebarNamesIt() {
        // The one pane whose name on screen is not its name in the code. Somebody writing a
        // URL is reading the sidebar.
        XCTAssertEqual(SettingsSection.named("actions"), .shortcuts)
        XCTAssertEqual(SettingsSection.named("Actions"), .shortcuts)
        XCTAssertEqual(SettingsSection.named("shortcuts"), .shortcuts)
        XCTAssertEqual(SettingsSection.named("home"), .home)
        XCTAssertEqual(SettingsSection.named("home panel"), .home)
        XCTAssertEqual(SettingsSection.named(" About "), .about)
        XCTAssertNil(SettingsSection.named(""))
        XCTAssertNil(SettingsSection.named("nonsense"))
    }

    func testEveryPaneAnswersToBothItsNames() {
        for section in SettingsSection.allCases {
            XCTAssertEqual(SettingsSection.named(section.rawValue), section)
            XCTAssertEqual(SettingsSection.named(section.title), section)
        }
    }

    // MARK: - Buttons a script asks for

    func testAScriptCanAskForButtons() {
        let actions = LiveActivityAPI.actions(from: [
            "action": "Retry", "action_url": "https://ci.example/retry",
            "action2": "Deploy", "action2_shortcut": "Ship it", "action2_symbol": "play.fill",
        ], allowsShortcuts: true)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].title, "Retry")
        XCTAssertEqual(actions[0].url?.absoluteString, "https://ci.example/retry")
        XCTAssertEqual(actions[1].shortcut, "Ship it")
        XCTAssertEqual(actions[1].symbol, "play.fill")
        XCTAssertNil(actions[1].url)
    }

    func testAButtonWithNowhereToGoIsNotDrawn() {
        // A button that does nothing is not a button.
        XCTAssertTrue(LiveActivityAPI.actions(from: ["action": "Retry"], allowsShortcuts: true).isEmpty)
        XCTAssertTrue(LiveActivityAPI.actions(from: ["action_url": "https://example.com"], allowsShortcuts: true).isEmpty,
                      "and one with no name is not one either")
        XCTAssertTrue(LiveActivityAPI.actions(from: ["action": "   ", "action_url": "https://example.com"], allowsShortcuts: true).isEmpty)
        XCTAssertTrue(LiveActivityAPI.actions(from: [:], allowsShortcuts: true).isEmpty)
    }

    func testAButtonIsHeldToTheSameLinksEverythingElseIs() {
        // A button that opened a file, or another app's scheme, would be a way to make
        // somebody click on something they were never shown.
        for bad in ["file:///etc/passwd", "notchisland://settings", "ftp://example.com", "javascript:alert(1)"] {
            XCTAssertTrue(LiveActivityAPI.actions(from: ["action": "Go", "action_url": bad], allowsShortcuts: true).isEmpty, bad)
        }
        XCTAssertEqual(LiveActivityAPI.actions(from: ["action": "Mail", "action_url": "mailto:a@b.c"], allowsShortcuts: true).count, 1)
    }

    func testAPushedCardMayNotRunAShortcutUnlessItHasBeenAllowedTo() {
        // Anything on this Mac can push a card, and a Shortcut is a shell script by another
        // name. The link beside it was always held to the web; this half was not held at all.
        let q = ["action": "Install", "action_shortcut": "Wipe the disk"]
        XCTAssertTrue(LiveActivityAPI.actions(from: q, allowsShortcuts: false).isEmpty,
                      "with nothing else to do, the button is not drawn at all")
        XCTAssertEqual(LiveActivityAPI.actions(from: q, allowsShortcuts: true).first?.shortcut, "Wipe the disk")
    }

    func testABlockedShortcutDoesNotTakeItsButtonsLinkWithIt() {
        // A button with a web link and a Shortcut keeps the link: what is refused is the
        // running of somebody else's Shortcut, not the button.
        let both = LiveActivityAPI.actions(from: ["action": "Open", "action_url": "https://example.com",
                                                  "action_shortcut": "Ship it"], allowsShortcuts: false)
        XCTAssertEqual(both.count, 1)
        XCTAssertNil(both[0].shortcut, "the name is dropped")
        XCTAssertEqual(both[0].url?.absoluteString, "https://example.com")
    }

    /// The switch was read when the card was pushed and never again: a card pushed while it was
    /// on ran its Shortcut after it had been turned off. It is asked again at the press.
    func testAPushedCardsShortcutIsAskedAboutAgainWhenItIsPressed() throws {
        let prefs = Preferences.shared
        let saved = prefs.apiShortcutsEnabled
        defer { prefs.apiShortcutsEnabled = saved }

        prefs.apiShortcutsEnabled = true
        handle("notchisland://activity?id=ship&title=Ready&action=Install&action_shortcut=Ship%20it")
        guard case .custom(let card)? = center.activity(id: LiveActivityAPI.pushedPrefix + "ship")?.content else {
            return XCTFail("card missing")
        }
        let install = try XCTUnwrap(card.actions.first)
        let id = LiveActivityAPI.pushedPrefix + "ship"
        XCTAssertEqual(LiveActivityAPI.press(install, activityID: id, allowsShortcuts: prefs.apiShortcutsEnabled),
                       .shortcut("Ship it"), "pushed with the switch on, and it is still on")
        prefs.apiShortcutsEnabled = false
        XCTAssertEqual(LiveActivityAPI.press(install, activityID: id, allowsShortcuts: prefs.apiShortcutsEnabled),
                       .refused, "turned off since: the card already up runs nothing")
        XCTAssertEqual(LiveActivityAPI.press(install, activityID: "api-alert", allowsShortcuts: false), .refused,
                       "an alert a script pushed is held to it too")
    }

    func testARefusedShortcutLeavesTheRestOfTheButtonAlone() {
        let link = URL(string: "https://example.com")!
        let both = CustomAction(title: "Open", url: link, shortcut: "Ship it")
        XCTAssertEqual(LiveActivityAPI.press(both, activityID: "api-build", allowsShortcuts: false), .link(link),
                       "a link beside it still goes")
        // The island's own cards carry commands, not somebody else's Shortcut, and are not
        // held to a switch about pushed cards.
        let stop = CustomAction(title: "Stop", symbol: "stop.fill", command: .stopRecording)
        XCTAssertEqual(LiveActivityAPI.press(stop, activityID: ScreenRecorder.activityID, allowsShortcuts: false),
                       .command(.stopRecording))
        let blank = CustomAction(title: "Nothing", shortcut: "  ")
        XCTAssertEqual(LiveActivityAPI.press(blank, activityID: "api-build", allowsShortcuts: true), .nothing)
    }

    func testNoMoreThanTwo() {
        let q = ["action": "One", "action_url": "https://a.example",
                 "action2": "Two", "action2_url": "https://b.example",
                 "action3": "Three", "action3_url": "https://c.example"]
        XCTAssertEqual(LiveActivityAPI.actions(from: q, allowsShortcuts: true).count, LiveActivityAPI.maxActions)
    }

    func testTheSecondButtonCanStandAlone() {
        // Numbering is which slot it is in, not how many came before it.
        let actions = LiveActivityAPI.actions(from: ["action2": "Only", "action2_url": "https://example.com"], allowsShortcuts: true)
        XCTAssertEqual(actions.map(\.title), ["Only"])
    }

    // MARK: - The rest of the query

    func testALengthIsANumberOfSecondsAndNothingElse() {
        // `Double` reads all of these as numbers; none of them is a length an alert can be.
        for bad in ["inf", "-inf", "nan", "0", "-3", "soon", ""] {
            XCTAssertNil(LiveActivityAPI.seconds(bad), bad)
        }
        XCTAssertNil(LiveActivityAPI.seconds(nil))
        XCTAssertEqual(LiveActivityAPI.seconds("3"), 3)
        XCTAssertEqual(LiveActivityAPI.seconds("0.5"), 0.5)
        XCTAssertEqual(LiveActivityAPI.seconds("86400"), LiveActivityAPI.maxSeconds, "a day is held to a minute")
    }

    func testAPushedCardCannotOutrankACall() {
        XCTAssertEqual(LiveActivityAPI.priority("500"), 99)
        XCTAssertEqual(LiveActivityAPI.priority("-5"), 0)
        XCTAssertEqual(LiveActivityAPI.priority("70"), 70)
        XCTAssertNil(LiveActivityAPI.priority("high"))
        handle("notchisland://activity?id=p&title=T&priority=1000")
        XCTAssertEqual(center.activity(id: "api-p")?.priority, 99, "a call is 100")
    }

    func testATitleOfNothingButSpacesIsNoTitle() {
        XCTAssertNil(LiveActivityAPI.text("   "))
        XCTAssertNil(LiveActivityAPI.text("\n"))
        XCTAssertNil(LiveActivityAPI.text(nil))
        XCTAssertEqual(LiveActivityAPI.text(" Build "), " Build ", "what is there is kept as it was sent")
        handle("notchisland://activity?id=blank&title=%20%20")
        guard case .custom(let c)? = center.activity(id: "api-blank")?.content else { return XCTFail() }
        XCTAssertEqual(c.title, "Activity")
    }

    func testASymbolThatDoesNotExistDrawsTheCardsOwn() {
        let known: (String) -> Bool = { $0 == "hammer.fill" }
        XCTAssertEqual(LiveActivityAPI.symbol("hammer.fill", fallback: "app.fill", exists: known), "hammer.fill")
        XCTAssertEqual(LiveActivityAPI.symbol("hamer.fill", fallback: "app.fill", exists: known), "app.fill")
        XCTAssertEqual(LiveActivityAPI.symbol(nil, fallback: "bell.fill", exists: known), "bell.fill")
        handle("notchisland://activity?id=typo&title=T&symbol=not.a.symbol.at.all")
        guard case .custom(let c)? = center.activity(id: "api-typo")?.content else { return XCTFail() }
        XCTAssertEqual(c.symbol, "app.fill")
    }

    // MARK: - Lengths

    func testALengthIsAPlainNumberWithAnOptionalUnit() {
        XCTAssertEqual(LiveActivityAPI.length("45", per: 60), .seconds(2700))
        XCTAssertEqual(LiveActivityAPI.length("45m", per: 60), .seconds(2700))
        XCTAssertEqual(LiveActivityAPI.length(" 25 min ", per: 60), .seconds(1500))
        XCTAssertEqual(LiveActivityAPI.length("25 Minutes", per: 60), .seconds(1500))
        XCTAssertEqual(LiveActivityAPI.length("90s", per: 60), .seconds(90), "a unit of its own beats the flag's")
        XCTAssertEqual(LiveActivityAPI.length("1.5h", per: 60), .seconds(5400))
        XCTAssertEqual(LiveActivityAPI.length("10m", per: 1), .seconds(600), "--ttl 10m is ten minutes")
        XCTAssertEqual(LiveActivityAPI.length("600", per: 1), .seconds(600))
        XCTAssertEqual(LiveActivityAPI.length("-1", per: 60), .seconds(-60), "a minute less")
        XCTAssertEqual(LiveActivityAPI.length(nil, per: 60), .absent)
    }

    func testAnythingElseIsUnreadableRatherThanTheDefault() {
        // `Double` reads the first four of these as numbers, and none of the rest at all — and
        // each was a default started instead, with the script told it had worked.
        for bad in ["1e300", "inf", "nan", "0x1p9", "", " ", "soon", "45 mins please", "5-3", "--5", ".5", "5.", "1.2.3", "5 d"] {
            XCTAssertEqual(LiveActivityAPI.length(bad, per: 60), .unreadable, bad)
        }
        XCTAssertEqual(LiveActivityAPI.length(String(repeating: "9", count: 400), per: 60), .unreadable,
                       "a number too big to be finite")
    }

    func testTheUnitsIncludeEveryWordTheActionsFieldTakes() {
        // The Actions field reads "25m" and "25 min"; a script is read the same way.
        for typed in ["5", "25m", "25 min", "25 mins", "90 minutes", "1 minute", "1440"] {
            guard let minutes = TimerEntry.typedMinutes(typed) else { return XCTFail(typed) }
            XCTAssertEqual(LiveActivityAPI.length(typed, per: 60), .seconds(TimeInterval(minutes) * 60), typed)
        }
    }

    func testATimerIsMoreThanNothingAndAtMostADay() {
        XCTAssertEqual(LiveActivityAPI.maxTimer, TimeInterval(TimerEntry.maxTypedMinutes) * 60)
        XCTAssertEqual(LiveActivityAPI.timerStart(minutes: "5", seconds: nil), 300)
        XCTAssertEqual(LiveActivityAPI.timerStart(minutes: "5", seconds: "30"), 330)
        XCTAssertEqual(LiveActivityAPI.timerStart(minutes: nil, seconds: "90"), 90)
        XCTAssertEqual(LiveActivityAPI.timerStart(minutes: "1440", seconds: nil), 86400)
        XCTAssertNil(LiveActivityAPI.timerStart(minutes: "1441", seconds: nil), "past the day the Actions field allows")
        XCTAssertNil(LiveActivityAPI.timerStart(minutes: "1e300", seconds: nil))
        XCTAssertNil(LiveActivityAPI.timerStart(minutes: "5", seconds: "soon"), "one unreadable half refuses the lot")
        XCTAssertNil(LiveActivityAPI.timerStart(minutes: nil, seconds: nil), "nothing is no timer")
        XCTAssertNil(LiveActivityAPI.timerStart(minutes: "0", seconds: nil))
        XCTAssertNil(LiveActivityAPI.timerStart(minutes: "-5", seconds: nil))
    }

    func testAddingIsAMinuteByDefaultAndEitherWayUpToADay() {
        XCTAssertEqual(LiveActivityAPI.timerAdd(minutes: nil, seconds: nil), IslandTimer.addStep)
        XCTAssertEqual(LiveActivityAPI.timerAdd(minutes: "5m", seconds: nil), 300, "timer add 5m is five minutes, not one")
        XCTAssertEqual(LiveActivityAPI.timerAdd(minutes: nil, seconds: "30"), 30, "and seconds=30 is not ninety")
        XCTAssertEqual(LiveActivityAPI.timerAdd(minutes: "-1", seconds: nil), -60)
        XCTAssertNil(LiveActivityAPI.timerAdd(minutes: "0", seconds: nil))
        XCTAssertNil(LiveActivityAPI.timerAdd(minutes: "5x", seconds: nil))
        XCTAssertNil(LiveActivityAPI.timerAdd(minutes: "-1441", seconds: nil))
        XCTAssertNil(LiveActivityAPI.timerAdd(minutes: "1441", seconds: nil))
    }

    func testSleepAndAPomodoroRunAreReadTheSameWay() {
        XCTAssertEqual(LiveActivityAPI.timer(nil, per: 60, absent: LiveActivityAPI.defaultSleep), 1800)
        XCTAssertEqual(LiveActivityAPI.timer("45m", per: 60, absent: LiveActivityAPI.defaultSleep), 2700)
        XCTAssertNil(LiveActivityAPI.timer("forty", per: 60, absent: LiveActivityAPI.defaultSleep))

        XCTAssertEqual(LiveActivityAPI.pomodoro([:]),
                       LiveActivityAPI.PomodoroRequest(work: 1500, rest: 300, longRest: 900, cycles: 4))
        XCTAssertEqual(LiveActivityAPI.pomodoro(["work": "50m", "rest": "10", "long": "20 min", "cycles": "3"]),
                       LiveActivityAPI.PomodoroRequest(work: 3000, rest: 600, longRest: 1200, cycles: 3))
        XCTAssertNil(LiveActivityAPI.pomodoro(["work": "50x"]), "--work 50x is not twenty-five minutes")
        XCTAssertNil(LiveActivityAPI.pomodoro(["cycles": "0"]))
        XCTAssertNil(LiveActivityAPI.pomodoro(["cycles": "two"]))
        XCTAssertNil(LiveActivityAPI.pomodoro(["rest": "0"]))
    }

    func testACardsTimeToLiveIsALengthAboveNought() {
        XCTAssertEqual(LiveActivityAPI.ttl(nil), .absent)
        XCTAssertEqual(LiveActivityAPI.ttl("600"), .seconds(600))
        XCTAssertEqual(LiveActivityAPI.ttl("10m"), .seconds(600))
        XCTAssertEqual(LiveActivityAPI.ttl("0"), .unreadable)
        XCTAssertEqual(LiveActivityAPI.ttl("-5"), .unreadable)
        XCTAssertEqual(LiveActivityAPI.ttl("soon"), .unreadable)
        XCTAssertEqual(LiveActivityAPI.seconds("3s"), 3, "an alert's duration takes a unit as well")
    }

    func testAURLWithALengthItCannotReadStartsNothing() {
        IslandTimer.shared.cancelAll()
        defer { IslandTimer.shared.cancelAll() }
        handle("notchisland://timer?minutes=1e300")
        handle("notchisland://timer?minutes=soon")
        handle("notchisland://timer?minutes=2000")
        handle("notchisland://sleep?minutes=forty")
        handle("notchisland://timer/pomodoro?work=50x")
        XCTAssertTrue(IslandTimer.shared.timers.isEmpty, "refused, not run on a default")

        handle("notchisland://sleep?minutes=45m")
        XCTAssertEqual(IslandTimer.shared.sleepTimer?.state.total, 2700, "45m is forty-five minutes")
        IslandTimer.shared.cancelAll()
        handle("notchisland://timer?minutes=5")
        handle("notchisland://timer/add?minutes=5m")
        XCTAssertEqual(IslandTimer.shared.state?.total, 600, "5 and 5m more")
        handle("notchisland://timer/add?minutes=lots")
        XCTAssertEqual(IslandTimer.shared.state?.total, 600, "and nothing for what cannot be read")

        handle("notchisland://activity?id=never&title=T&ttl=10x")
        XCTAssertNil(center.activity(id: "api-never"), "a card that would never go is not put up")
        handle("notchisland://activity?id=soon&title=T&ttl=10m")
        let expires = center.activity(id: "api-soon")?.expiresAt?.timeIntervalSinceNow ?? 0
        XCTAssertEqual(expires, 600, accuracy: 5)
        center.end(id: "api-soon")
    }

    /// Read aloud, a length is held to what the clock shows before it becomes an `Int`, which
    /// traps past `Int.max`.
    func testAnyLengthCanBeSpoken() {
        XCTAssertEqual(IslandAccessibility.spokenDuration(1e300), IslandAccessibility.spokenDuration(TimeInterval.clockLimit))
        XCTAssertEqual(IslandAccessibility.spokenDuration(TimeInterval.clockLimit), "99 hours 59 minutes 59 seconds")
        XCTAssertEqual(IslandAccessibility.spokenDuration(-TimeInterval.greatestFiniteMagnitude), "0 seconds")
    }

    // MARK: - Ids and bodies

    func testAPushedCardCannotTakeTheAlertsId() {
        XCTAssertEqual(LiveActivityAPI.pushedID("build"), "api-build")
        XCTAssertEqual(LiveActivityAPI.pushedID(nil), "api-custom")
        XCTAssertEqual(LiveActivityAPI.pushedID("  "), "api-custom")
        XCTAssertTrue(LiveActivityAPI.alertID.hasPrefix(LiveActivityAPI.pushedPrefix), "the alert is still a pushed card")
        for name in ["alert", "", " ", "custom", "api-"] {
            XCTAssertNotEqual(LiveActivityAPI.pushedID(name), LiveActivityAPI.alertID, name)
        }

        handle("notchisland://activity?id=alert&title=Card")
        handle("notchisland://alert?title=Deployed&duration=5")
        XCTAssertEqual(center.alert?.id, LiveActivityAPI.alertID)
        guard case .custom(let card)? = center.activity(id: "api-alert")?.content else { return XCTFail("the card went") }
        XCTAssertEqual(card.title, "Card", "and the alert did not write over it")
        handle("notchisland://activity/end?id=alert")
        XCTAssertNil(center.activity(id: "api-alert"))
        XCTAssertEqual(center.alert?.id, LiveActivityAPI.alertID, "ending the card leaves the alert")
    }

    func testAnEmptyBodyIsNoBody() {
        handle("notchisland://activity?id=b&title=T&body=")
        guard case .custom(let card)? = center.activity(id: "api-b")?.content else { return XCTFail("no card") }
        XCTAssertNil(card.body)
        XCTAssertEqual(ActivityContent.custom(card).cardHeight, ActivityContent.cardRow, "no black band for a line not drawn")
        XCTAssertEqual(ActivityContent.custom(CustomActivity(title: "T", body: "")).cardHeight, ActivityContent.cardRow)
        XCTAssertEqual(ActivityContent.custom(CustomActivity(title: "T", body: "Line")).cardHeight, ActivityContent.cardCustomBody)
        handle("notchisland://alert?title=A&body=%20")
        guard case .custom(let alert)? = center.alert?.content else { return XCTFail("no alert") }
        XCTAssertNil(alert.body)
    }
}
