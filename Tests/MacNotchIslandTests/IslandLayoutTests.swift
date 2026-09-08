import XCTest
import SwiftUI
@testable import MacNotchIsland

final class IslandLayoutTests: XCTestCase {
    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                         notchWidth: 200, notchHeight: 32, hasPhysicalNotch: true)

    override func setUp() {
        super.setUp()
        ActivityCenter.shared.resetForTesting()
        Preferences.shared.privacyIndicatorsEnabled = true
    }

    private func activity(_ id: String, _ content: ActivityContent, priority: Int = 50) -> IslandActivity {
        IslandActivity(id: id, kind: .custom, content: content, priority: priority)
    }

    func testIdleMatchesNotch() {
        let layout = IslandLayout.make(presentation: .idle, geometry: geometry)
        XCTAssertEqual(layout.bodyWidth, 200)
        XCTAssertEqual(layout.bodyHeight, 32)
        XCTAssertFalse(layout.isExpanded)
        XCTAssertFalse(layout.hasBubble)
        XCTAssertEqual(layout.frameWidth, 200 + 2 * layout.topRadius)
    }

    func testIdleWidensForPrivacyDots() {
        ActivityCenter.shared.micInUse = true
        let layout = IslandLayout.make(presentation: .idle, geometry: geometry)
        XCTAssertGreaterThan(layout.bodyWidth, 200)
        XCTAssertEqual(layout.leadingWidth, layout.trailingWidth, "island stays centred on the notch")
        XCTAssertEqual(layout.privacyWidth, 18)
    }

    func testCompactAddsLeadingAndTrailingAroundNotch() {
        let timer = TimerState(label: "Timer", total: 60, endDate: Date().addingTimeInterval(60))
        let a = activity("t", .timer(timer))
        let layout = IslandLayout.make(presentation: .compact(a, bubble: nil), geometry: geometry)
        let widths = ActivityContent.timer(timer).compactWidths
        XCTAssertEqual(layout.bodyWidth, 200 + widths.leading + widths.trailing)
        XCTAssertEqual(layout.bodyHeight, 32)
        XCTAssertEqual(layout.bottomRadius, 16, "compact pill is a full capsule")
        XCTAssertFalse(layout.hasBubble)
    }

    func testCompactWithBubbleReservesHitArea() {
        let a = activity("a", .custom(CustomActivity(title: "A")))
        let b = activity("b", .custom(CustomActivity(title: "B")))
        let withBubble = IslandLayout.make(presentation: .compact(a, bubble: b), geometry: geometry)
        let without = IslandLayout.make(presentation: .compact(a, bubble: nil), geometry: geometry)
        XCTAssertTrue(withBubble.hasBubble)
        XCTAssertEqual(withBubble.bubbleDiameter, 32)
        XCTAssertGreaterThan(withBubble.hitSize.width, without.hitSize.width)
    }

    func testExpandedIsLargerThanCompactAndClearsNotch() {
        let info = NowPlayingInfo(title: "Song", artist: "Artist", album: "", duration: 200, elapsed: 10,
                                  timestamp: Date(), isPlaying: true, bundleID: nil, artwork: nil, artworkID: 0, accent: .white)
        let a = activity("np", .nowPlaying(info))
        let expanded = IslandLayout.make(presentation: .card(a), geometry: geometry)
        let compact = IslandLayout.make(presentation: .compact(a, bubble: nil), geometry: geometry)
        XCTAssertTrue(expanded.isExpanded)
        XCTAssertGreaterThan(expanded.bodyWidth, compact.bodyWidth)
        XCTAssertGreaterThan(expanded.bodyHeight, geometry.notchHeight + 100)
        XCTAssertGreaterThanOrEqual(expanded.bodyWidth, geometry.notchWidth + 120)
        XCTAssertEqual(expanded.topRadius, IslandLayout.expandedTopRadius)
    }

    func testHomeAndShelfShareSize() {
        let home = IslandLayout.make(presentation: .panel(.home(tab: "music")), geometry: geometry)
        let shelf = IslandLayout.make(presentation: .shelf, geometry: geometry)
        let card = IslandLayout.make(presentation: .panel(.activity(id: "timer")), geometry: geometry)
        XCTAssertEqual(home.bodyWidth, shelf.bodyWidth)
        XCTAssertEqual(home.bodyHeight, shelf.bodyHeight)
        XCTAssertEqual(home.bodyWidth, IslandLayout.panelWidth)
        XCTAssertEqual(home.bodyHeight, geometry.notchHeight + IslandLayout.bandExtra + IslandLayout.panelContentHeight)
        XCTAssertEqual(card.bodyHeight, home.bodyHeight, "every view of the panel is the same size, so stepping never resizes it")
    }

    func testEveryContentHasSaneExpandedSize() {
        let contents: [ActivityContent] = [
            .timer(TimerState(label: "t", total: 1, endDate: Date())),
            .stopwatch(StopwatchState(startedAt: Date())),
            .call(CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: Date())),
            .battery(BatteryState(percent: 50, isCharging: true, isPluggedIn: true, event: .pluggedIn)),
            .bluetooth(BluetoothState(name: "AirPods", address: "", symbol: "airpods")),
            .focus(FocusState(name: "Work", symbol: "moon.fill", isOn: true, tint: "indigo")),
            .hud(LevelHUD(kind: .volume, level: 0.5)),
            .calendar(CalendarState(title: "Standup", start: Date(), end: Date(), location: nil, joinURL: nil, tint: "blue")),
            .download(DownloadState(name: "file.zip", bytes: 10, total: 100, app: "Safari")),
            .custom(CustomActivity(title: "Custom", body: "body", url: nil)),
        ]
        for content in contents {
            let card = IslandLayout.make(presentation: .card(activity("x", content)), geometry: geometry)
            XCTAssertGreaterThan(card.bodyWidth, geometry.notchWidth + 100, "\(content)")
            XCTAssertGreaterThan(card.bodyHeight, geometry.notchHeight + 40, "\(content)")
            XCTAssertGreaterThanOrEqual(content.cardHeight, ActivityContent.cardRow, "\(content)")
            let widths = content.compactWidths
            XCTAssertGreaterThan(widths.leading, 0)
            XCTAssertGreaterThan(widths.trailing, 0)
        }
        XCTAssertFalse(ActivityContent.unlock.hasExpandedView)
        XCTAssertFalse(ActivityContent.silent(SilentState(isSilent: true)).hasExpandedView)
    }

    func testNotchShapeStaysInsideRectAndIsClosed() {
        let shape = NotchShape(topRadius: 8, bottomRadius: 16)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 32)
        let path = shape.path(in: rect)
        let bounds = path.boundingRect
        XCTAssertEqual(bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(bounds.maxX, 300, accuracy: 0.5)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.5)
        XCTAssertEqual(bounds.maxY, 32, accuracy: 0.5)
        XCTAssertTrue(path.contains(CGPoint(x: 150, y: 16)))
        XCTAssertFalse(path.contains(CGPoint(x: 2, y: 30)), "outward top corner leaves the lower ear empty")
    }

    func testCompactKeepsTheNotchGapOnTheNotch() {
        // The volume HUD has the widest trailing slot; without the shift its bar would sit
        // well inside the cutout.
        let hud = IslandActivity(id: "hud", kind: .hud, content: .hud(LevelHUD(kind: .volume, level: 0.5, isMuted: false)), priority: 85)
        let layout = IslandLayout.make(presentation: .compact(hud, bubble: nil), geometry: geometry, clearance: .unlimited)
        let widths = hud.content.compactWidths
        let shift = (widths.trailing - widths.leading) / 2
        XCTAssertEqual(layout.bodyShift, (layout.trailingWidth - layout.leadingWidth) / 2)
        XCTAssertEqual(layout.bodyShift, shift)
        XCTAssertGreaterThanOrEqual(shift, 16, "the bar's slot is far wider than the glyph's")
        // Gap centre measured from the body's left edge equals the body's centre, shifted back.
        let notchCentreInBody = layout.leadingWidth + 200 / 2
        XCTAssertEqual(notchCentreInBody, layout.bodyWidth / 2 - layout.bodyShift, accuracy: 0.001)
        XCTAssertEqual(layout.hitLeading, layout.frameWidth / 2 - shift + 4)
        XCTAssertEqual(layout.hitTrailing, layout.frameWidth / 2 + shift + 4)
        XCTAssertEqual(layout.hitSize.width, 2 * layout.hitTrailing)
    }

    func testIdleReservesWhatThePrivacyDotsDraw() {
        ActivityCenter.shared.micInUse = true
        let layout = IslandLayout.make(presentation: .idle, geometry: geometry, clearance: .unlimited)
        XCTAssertEqual(layout.trailingWidth, layout.privacyWidth + 8, "22 pt of dots plus 4 pt of padding")
        ActivityCenter.shared.micInUse = false
    }
}
