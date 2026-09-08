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
        XCTAssertEqual(layout.bodyWidth, 120, "the iPhone's idle island, not a 190pt slab")
        XCTAssertEqual(layout.bodyHeight, external.notchHeight)
        XCTAssertEqual(layout.topInset, external.menuBarHeight + 4, "it hangs below the menu bar instead of fusing into the top edge")
        XCTAssertEqual(layout.frameWidth, layout.bodyWidth, "no ears, so the frame is just the body")
        XCTAssertEqual(layout.topRadius, layout.bottomRadius, "rounded the same on all four corners")
        XCTAssertEqual(layout.bottomRadius, external.notchHeight / 2, "a capsule at rest")
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
        XCTAssertEqual(layout.bodyWidth, external.notchWidth + widths.leading + widths.trailing)
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
        XCTAssertEqual(idle.bodyWidth, notched.notchWidth, "idle matches the notch, not the 120pt pill")
        XCTAssertEqual(idle.topRadius, 6)
        XCTAssertEqual(idle.frameWidth, idle.bodyWidth + 2 * idle.topRadius, "the ears are still in the frame")

        let a = activity("a", .custom(CustomActivity(title: "A")))
        let compact = IslandLayout.make(presentation: .compact(a, bubble: nil), geometry: notched)
        XCTAssertEqual(compact.topRadius, 8)
        XCTAssertEqual(compact.frameWidth, compact.bodyWidth + 16)
        let expanded = IslandLayout.make(presentation: .card(a), geometry: notched)
        XCTAssertEqual(expanded.topRadius, IslandLayout.expandedTopRadius)
        XCTAssertEqual(expanded.bottomRadius, IslandLayout.expandedBottomRadius)
        XCTAssertFalse(expanded.floating)
    }
}
