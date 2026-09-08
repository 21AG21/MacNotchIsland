import XCTest
@testable import MacNotchIsland

/// The compact island may only widen into menu bar space that is free.
final class MenuBarClearanceTests: XCTestCase {
    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                         notchWidth: 200, notchHeight: 32, hasPhysicalNotch: true)

    private func window(x: CGFloat, y: CGFloat = 0, width: CGFloat = 30, layer: Int = MenuBarClearance.statusItemLayer) -> [String: Any] {
        let bounds = CGRect(x: x, y: y, width: width, height: 24)
        return [kCGWindowLayer as String: layer,
                kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }

    func testNearestStatusItemRightOfTheNotchSetsTheRoom() {
        let band = CGRect(x: 0, y: 0, width: 1710, height: 32)
        let windows = [window(x: 1600), window(x: 1010), window(x: 1100), window(x: 300),
                       window(x: 980, layer: 0), window(x: 990, y: 500)]
        // Notch spans 755...955; the nearest status item starts at 1010.
        XCTAssertEqual(MenuBarClearance.statusItemClearance(windows: windows, menuBar: band, notchMaxX: 955), 55)
        XCTAssertNil(MenuBarClearance.statusItemClearance(windows: [window(x: 300)], menuBar: band, notchMaxX: 955),
                     "nothing on the right means nothing known")
    }

    func testFittedPicksFullThenMinimalThenNothing() {
        XCTAssertEqual(MenuBarClearance.fitted(60, minimal: 28, free: nil), 60)
        XCTAssertEqual(MenuBarClearance.fitted(60, minimal: 28, free: 64), 60)
        XCTAssertEqual(MenuBarClearance.fitted(60, minimal: 28, free: 50), 28)
        XCTAssertEqual(MenuBarClearance.fitted(60, minimal: 28, free: 20), 0)
        XCTAssertEqual(MenuBarClearance.fitted(60, minimal: 0, free: 50), 0)
    }

    func testCompactLayoutShrinksIntoFreeRoomAndDropsTheBubble() {
        let timer = IslandActivity(id: "timer", kind: .timer,
                                   content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 90)
        let music = IslandActivity(id: "music", kind: .custom, content: .custom(CustomActivity(title: "x")), priority: 50)
        let center = ActivityCenter.shared
        center.resetForTesting()

        let roomy = IslandLayout.make(presentation: .compact(timer, bubble: music), geometry: geometry, center: center,
                                      clearance: .unlimited)
        XCTAssertEqual(roomy.leadingWidth, timer.content.compactWidths.leading)
        XCTAssertEqual(roomy.trailingWidth, timer.content.compactWidths.trailing)
        XCTAssertTrue(roomy.hasBubble)

        let tight = IslandLayout.make(presentation: .compact(timer, bubble: music), geometry: geometry, center: center,
                                      clearance: MenuBarClearance.Limits(leading: 10, trailing: 40))
        XCTAssertEqual(tight.leadingWidth, 0, "no room on the left: the glyph goes")
        XCTAssertEqual(tight.trailingWidth, 28, "a ring instead of the digits")
        XCTAssertFalse(tight.hasBubble, "the bubble needs its own room beyond the trailing side")
        XCTAssertEqual(tight.bodyWidth, 200 + 28)

        let none = IslandLayout.make(presentation: .compact(timer, bubble: nil), geometry: geometry, center: center,
                                     clearance: MenuBarClearance.Limits(leading: 0, trailing: 0))
        XCTAssertEqual(none.bodyWidth, 200, "a crowded menu bar leaves the island the size of the notch")
    }

    func testFloatingIslandIgnoresTheMenuBar() {
        let plain = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                  notchWidth: 190, notchHeight: 30, hasPhysicalNotch: false)
        let timer = IslandActivity(id: "timer", kind: .timer,
                                   content: .timer(TimerState(label: "Tea", total: 60, endDate: Date(timeIntervalSinceNow: 60))), priority: 90)
        let layout = IslandLayout.make(presentation: .compact(timer, bubble: nil), geometry: plain, center: .shared,
                                       clearance: MenuBarClearance.Limits(leading: 0, trailing: 0))
        XCTAssertEqual(layout.leadingWidth, timer.content.compactWidths.leading)
        XCTAssertEqual(layout.trailingWidth, timer.content.compactWidths.trailing)
    }

    func testBandConversionForANotchedScreenBelowThePrimary() {
        // An external 2560x1440 display is primary at the origin; the built-in notched screen
        // sits directly below it, so its AppKit frame has a negative origin.
        let builtin = CGRect(x: 524, y: -982, width: 1512, height: 982)
        let band = MenuBarClearance.menuBarBand(screenFrame: builtin, primaryHeight: 1440, notchHeight: 32)
        XCTAssertEqual(band.minY, 1440, "the built-in's top edge is the external's bottom edge, top-down")
        XCTAssertEqual(band.minX, 524)
        XCTAssertEqual(band.height, 32)
    }

    func testAWindowStraddlingTheNotchLeavesNoRoom() {
        let band = CGRect(x: 0, y: 0, width: 1710, height: 32)
        XCTAssertEqual(MenuBarClearance.statusItemClearance(windows: [window(x: 900, width: 100)], menuBar: band, notchMaxX: 955), 0)
    }

    func testMenuClearanceIsUnknownWithoutAnApp() {
        XCTAssertNil(MenuBarClearance.menuClearance(app: nil, notchMinX: 755))
    }
}
