import XCTest
import SwiftUI
@testable import MacNotchIsland

/// Layout on a screen with no physical notch — an external monitor, or a Mac that never had one.
/// There the island is the iPhone's free-floating pill: a small resting shape, rounded on all
/// four corners, hanging a few points below the top edge, with no outward "ears".
final class FloatingLayoutTests: XCTestCase {
    /// What `NotchGeometry.detect` produces for a screen without a notch.
    private let external = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                         notchWidth: 190, notchHeight: 30, hasPhysicalNotch: false)
    private let notched = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                        notchWidth: 200, notchHeight: 32, hasPhysicalNotch: true)

    override func setUp() {
        super.setUp()
        ActivityCenter.shared.resetForTesting()
        Preferences.shared.privacyIndicatorsEnabled = true
    }

    override func tearDown() {
        ActivityCenter.shared.resetForTesting()
        super.tearDown()
    }

    private func activity(_ id: String, _ content: ActivityContent) -> IslandActivity {
        IslandActivity(id: id, kind: .custom, content: content, priority: 50)
    }

    // MARK: - idle

    func testIdleIsASmallRestingPill() {
        let layout = IslandLayout.make(presentation: .idle, geometry: external)
        XCTAssertTrue(layout.floating)
        XCTAssertEqual(layout.bodyWidth, IslandLayout.floatingIdleWidth)
        XCTAssertEqual(layout.bodyWidth, 72, "the iPhone's idle island, not a 190pt slab")
        XCTAssertEqual(layout.bodyHeight, IslandLayout.floatingIdleHeight, "a handle, not a slab")
        XCTAssertEqual(layout.topInset, external.menuBarHeight + 4, "it hangs below the menu bar instead of fusing into the top edge")
        XCTAssertEqual(layout.frameWidth, layout.bodyWidth, "no ears, so the frame is just the body")
        XCTAssertEqual(layout.topRadius, layout.bottomRadius, "rounded the same on all four corners")
        XCTAssertEqual(layout.bottomRadius, IslandLayout.floatingIdleHeight / 2, "a capsule at rest")
        XCTAssertFalse(layout.isExpanded)
        XCTAssertFalse(layout.hasBubble)
    }

    func testIdlePillWidensSymmetricallyForPrivacyDots() {
        ActivityCenter.shared.micInUse = true
        let layout = IslandLayout.make(presentation: .idle, geometry: external)
        XCTAssertGreaterThan(layout.bodyWidth, IslandLayout.floatingIdleWidth)
        XCTAssertEqual(layout.leadingWidth, layout.trailingWidth, "the pill stays centred")
        XCTAssertEqual(layout.privacyWidth, 18)
        XCTAssertEqual(layout.frameWidth, layout.bodyWidth)
        XCTAssertEqual(layout.topInset, external.menuBarHeight + 4, "hangs below the menu bar, never on it")
    }

    func testHitAreaCoversTheHangingPill() {
        let layout = IslandLayout.make(presentation: .idle, geometry: external)
        // The hit rect is measured from the top of the screen, so it has to include the gap the
        // pill hangs below it.
        XCTAssertEqual(layout.hitSize.height, layout.bodyHeight + layout.topInset + 6)
        XCTAssertEqual(layout.hitSize.width, layout.bodyWidth + 8)
        let onNotch = IslandLayout.make(presentation: .idle, geometry: notched)
        XCTAssertEqual(onNotch.hitSize.height, onNotch.bodyHeight + 6, "nothing extra against a real notch")
    }

    // MARK: - the other presentations

    func testCompactHasNoEarsAndStaysCentred() {
        let a = activity("a", .custom(CustomActivity(title: "A")))
        let layout = IslandLayout.make(presentation: .compact(a, bubble: nil), geometry: external)
        let widths = ActivityContent.custom(CustomActivity(title: "A")).compactWidths
        XCTAssertTrue(layout.floating)
        // The gap between the two slots stands in for a cutout that is not there, so it is a
        // breath of space rather than the 190 pt a camera housing would have taken.
        XCTAssertEqual(layout.middleWidth, IslandLayout.floatingMiddle)
        XCTAssertEqual(layout.bodyWidth, IslandLayout.floatingMiddle + widths.leading + widths.trailing)
        XCTAssertLessThan(layout.bodyWidth, external.notchWidth,
                          "a pill with a mark at each end and nothing between them is a black bar")
        XCTAssertEqual(layout.frameWidth, layout.bodyWidth, "no ear padding to push it off centre")
        XCTAssertEqual(layout.leadingWidth, widths.leading)
        XCTAssertEqual(layout.trailingWidth, widths.trailing)
        XCTAssertEqual(layout.topRadius, layout.bottomRadius)
        XCTAssertEqual(layout.bottomRadius, external.notchHeight / 2, "still a capsule")
        XCTAssertEqual(layout.topInset, external.menuBarHeight + 4, "hangs below the menu bar, never on it")
    }

    func testExpandedHasNoEarsAndStaysCentred() {
        let a = activity("np", .custom(CustomActivity(title: "Custom", body: "body", url: nil)))
        let layout = IslandLayout.make(presentation: .card(a), geometry: external)
        XCTAssertTrue(layout.floating)
        XCTAssertTrue(layout.isExpanded)
        XCTAssertGreaterThanOrEqual(layout.bodyWidth, external.notchWidth + 120)
        XCTAssertEqual(layout.frameWidth, layout.bodyWidth, "centred, with the ears gone")
        XCTAssertEqual(layout.topRadius, layout.bottomRadius)
        XCTAssertEqual(layout.bottomRadius, IslandLayout.expandedBottomRadius)
        XCTAssertEqual(layout.topInset, external.menuBarHeight + 4, "hangs below the menu bar, never on it")
        // The band above a card's content is the cutout on a screen that has one. Here there
        // is none, so keeping its height would leave a hole in the top of the card and the
        // content sitting low in its own shape.
        XCTAssertEqual(IslandLayout.cardTopBand(external), IslandLayout.floatingCardTop)
        XCTAssertEqual(layout.bodyHeight, IslandLayout.floatingCardTop + ActivityContent.custom(
            CustomActivity(title: "Custom", body: "body", url: nil)).cardHeight)
        let onNotch = IslandLayout.make(presentation: .card(a), geometry: notched)
        XCTAssertEqual(IslandLayout.cardTopBand(notched), notched.notchHeight)
        XCTAssertGreaterThan(onNotch.bodyHeight, layout.bodyHeight,
                             "a screen with a cutout is the one that has to keep room for it")
    }

    func testHomeAndShelfFloatToo() {
        for presentation in [IslandPresentation.panel(.home(tab: "music")), .shelf] {
            let layout = IslandLayout.make(presentation: presentation, geometry: external)
            XCTAssertTrue(layout.floating, "\(presentation.contentID)")
            XCTAssertEqual(layout.frameWidth, layout.bodyWidth, "\(presentation.contentID)")
            XCTAssertEqual(layout.topRadius, layout.bottomRadius, "\(presentation.contentID)")
            XCTAssertEqual(layout.bodyHeight, external.notchHeight + IslandLayout.bandExtra + IslandLayout.panelContentHeight)
            XCTAssertEqual(layout.topInset, external.menuBarHeight + 4, "hangs below the menu bar, never on it")
        }
    }

    // MARK: - the notched screen is untouched

    func testNotchedScreenKeepsItsEarsAndSitsFlush() {
        let idle = IslandLayout.make(presentation: .idle, geometry: notched)
        XCTAssertFalse(idle.floating)
        XCTAssertEqual(idle.topInset, 0, "fused to the notch, not hanging below it")
        XCTAssertEqual(idle.bodyWidth, notched.notchWidth, "idle matches the notch, not the floating pill")
        XCTAssertEqual(idle.topRadius, IslandLayout.compactTopRadius)
        XCTAssertEqual(idle.frameWidth, idle.bodyWidth + 2 * idle.topRadius, "the ears are still in the frame")

        let a = activity("a", .custom(CustomActivity(title: "A")))
        let compact = IslandLayout.make(presentation: .compact(a, bubble: nil), geometry: notched)
        XCTAssertEqual(compact.topRadius, 8)
        XCTAssertEqual(compact.frameWidth, compact.bodyWidth + 16)
        XCTAssertEqual(compact.middleWidth, notched.notchWidth,
                       "against a real cutout the gap is the cutout, to the point")
        let expanded = IslandLayout.make(presentation: .card(a), geometry: notched)
        XCTAssertEqual(expanded.topRadius, IslandLayout.expandedTopRadius)
        XCTAssertEqual(expanded.bottomRadius, IslandLayout.expandedBottomRadius)
        XCTAssertFalse(expanded.floating)
    }
}
