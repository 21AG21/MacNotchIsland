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
        ])
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].title, "Retry")
        XCTAssertEqual(actions[0].url?.absoluteString, "https://ci.example/retry")
        XCTAssertEqual(actions[1].shortcut, "Ship it")
        XCTAssertEqual(actions[1].symbol, "play.fill")
        XCTAssertNil(actions[1].url)
    }

    func testAButtonWithNowhereToGoIsNotDrawn() {
        // A button that does nothing is not a button.
        XCTAssertTrue(LiveActivityAPI.actions(from: ["action": "Retry"]).isEmpty)
        XCTAssertTrue(LiveActivityAPI.actions(from: ["action_url": "https://example.com"]).isEmpty,
                      "and one with no name is not one either")
        XCTAssertTrue(LiveActivityAPI.actions(from: ["action": "   ", "action_url": "https://example.com"]).isEmpty)
        XCTAssertTrue(LiveActivityAPI.actions(from: [:]).isEmpty)
    }

    func testAButtonIsHeldToTheSameLinksEverythingElseIs() {
        // A button that opened a file, or another app's scheme, would be a way to make
        // somebody click on something they were never shown.
        for bad in ["file:///etc/passwd", "notchisland://settings", "ftp://example.com", "javascript:alert(1)"] {
            XCTAssertTrue(LiveActivityAPI.actions(from: ["action": "Go", "action_url": bad]).isEmpty, bad)
        }
        XCTAssertEqual(LiveActivityAPI.actions(from: ["action": "Mail", "action_url": "mailto:a@b.c"]).count, 1)
    }

    func testNoMoreThanTwo() {
        let q = ["action": "One", "action_url": "https://a.example",
                 "action2": "Two", "action2_url": "https://b.example",
                 "action3": "Three", "action3_url": "https://c.example"]
        XCTAssertEqual(LiveActivityAPI.actions(from: q).count, LiveActivityAPI.maxActions)
    }

    func testTheSecondButtonCanStandAlone() {
        // Numbering is which slot it is in, not how many came before it.
        let actions = LiveActivityAPI.actions(from: ["action2": "Only", "action2_url": "https://example.com"])
        XCTAssertEqual(actions.map(\.title), ["Only"])
    }
}
