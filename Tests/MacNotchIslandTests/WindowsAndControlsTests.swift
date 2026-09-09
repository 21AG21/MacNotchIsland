import AppKit
import XCTest
@testable import MacNotchIsland

/// The pure parts of the window switcher, the switcher band's fitting, the artwork lookup and
/// the menu bar's hysteresis.
final class WindowsAndControlsTests: XCTestCase {

    // MARK: - Snap zones

    private let screen = CGRect(x: 0, y: 25, width: 1710, height: 1050)

    func testHalvesSplitTheScreenAndTouchNothingElse() {
        let left = SnapZone.leftHalf.rect(in: screen)
        let right = SnapZone.rightHalf.rect(in: screen)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(left.maxX, right.minX, "the halves meet in the middle with no gap and no overlap")
        XCTAssertEqual(left.height, screen.height)
        XCTAssertEqual(right.height, screen.height)
        XCTAssertEqual(left.minY, screen.minY, "a snapped window starts below the menu bar")
    }

    func testFullFillsTheVisibleFrameAndCentreStaysInside() {
        XCTAssertEqual(SnapZone.full.rect(in: screen), screen)
        let centre = SnapZone.center.rect(in: screen)
        XCTAssertTrue(screen.contains(centre))
        XCTAssertEqual(centre.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(centre.midY, screen.midY, accuracy: 1)
    }

    // MARK: - Listing windows

    private func entry(id: CGWindowID, layer: Int = 0, owner: String = "Safari", name: String = "A page",
                       bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600), alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id),
         kCGWindowLayer as String: layer,
         kCGWindowOwnerPID as String: pid_t(1),
         kCGWindowOwnerName as String: owner,
         kCGWindowName as String: name,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height).dictionaryRepresentation]
    }

    func testOnlyRealWindowsAreListed() {
        let windows = WindowsMonitor.list(now: [
            entry(id: 1),
            entry(id: 2, layer: 25, owner: "SystemUIServer"),                       // a status item
            entry(id: 3, owner: "Dock"),                                            // the Dock
            entry(id: 4, bounds: CGRect(x: 0, y: 0, width: 60, height: 40)),        // a palette
            entry(id: 5, alpha: 0),                                                 // invisible
            entry(id: 6, owner: "Mail", name: ""),
        ])
        XCTAssertEqual(windows.map(\.id), [1, 6])
        XCTAssertEqual(windows[0].label, "A page")
        XCTAssertEqual(windows[1].label, "Mail", "without a title a window is known by its app")
    }

    func testTheListIsCapped() {
        let many = (1...40).map { entry(id: CGWindowID($0)) }
        XCTAssertEqual(WindowsMonitor.list(now: many).count, WindowsMonitor.maxWindows)
    }

    // MARK: - The switcher band

    private var views: [IslandView] { HomeSection.allCases.map { .home(tab: $0.rawValue) } }

    /// The band's trailing side on a 15-inch notch: what the sections actually get.
    private var bandSide: CGFloat {
        let middle = 185 + SwitcherBand.cutoutMargin * 2
        return (IslandLayout.panelWidth - middle) / 2 - SwitcherBand.inset
    }

    func testEverySectionKeepsASlotInTheRoomThePanelHas() {
        let fitted = SwitcherBand.fit(views, in: bandSide)
        XCTAssertEqual(fitted.views.count, HomeSection.allCases.count, "no section may be dropped from the switcher")
        XCTAssertGreaterThanOrEqual(fitted.slot, SwitcherBand.minSlot)
        let used = CGFloat(fitted.views.count) * fitted.slot + CGFloat(fitted.views.count - 1) * fitted.gap
        XCTAssertLessThanOrEqual(used, bandSide)
    }

    /// The close button sits at the leading edge, so its room comes out of the side the live
    /// activities are on — and it is kept there whether or not the button is showing, or
    /// pinning a peeked panel would shunt every card along.
    func testTheCloseButtonsRoomHoldsItAndItsGap() {
        let sections = SwitcherBand.fit(views, in: bandSide)
        XCTAssertGreaterThanOrEqual(SwitcherBand.closeRoom, sections.slot + SwitcherBand.groupGap,
                                    "the reservation must cover the button and the step after it")
        // Three live activities beside it still fit on the leading side.
        let cards = SwitcherBand.fit(Array(views.prefix(3)), in: bandSide - SwitcherBand.closeRoom,
                                     slot: sections.slot, gap: sections.gap)
        XCTAssertEqual(cards.views.count, 3)
        let used = sections.slot + SwitcherBand.groupGap + CGFloat(cards.views.count) * cards.slot
            + CGFloat(cards.views.count - 1) * cards.gap
        XCTAssertLessThanOrEqual(used, bandSide)
    }

    func testBothSidesOfTheBandUseOneSlotSize() {
        // Sections settle the size; the activity slots take it, whatever room they have.
        let sections = SwitcherBand.fit(views, in: 190)
        let activities = SwitcherBand.fit(Array(views.prefix(2)), in: 220, slot: sections.slot, gap: sections.gap)
        XCTAssertEqual(activities.slot, sections.slot, "one row of buttons, not two sizes of circle")
        XCTAssertEqual(activities.gap, sections.gap)
        XCTAssertEqual(activities.views.count, 2, "with room to spare, nothing is dropped")
    }

    func testAnImposedSizeStillDropsWhatCannotFit() {
        let fitted = SwitcherBand.fit(views, in: 60, slot: 26, gap: 4)
        XCTAssertEqual(fitted.slot, 26)
        XCTAssertEqual(fitted.views.count, 2)
    }

    func testAFewSlotsKeepTheirFullSize() {
        let fitted = SwitcherBand.fit(Array(views.prefix(3)), in: 300)
        XCTAssertEqual(fitted.slot, SwitcherBand.slot)
        XCTAssertEqual(fitted.gap, SwitcherBand.gap)
    }

    func testSlotsAreOnlyDroppedWhenEvenTheSmallestDoNotFit() {
        let fitted = SwitcherBand.fit(views, in: 60)
        XCTAssertLessThan(fitted.views.count, views.count)
        XCTAssertEqual(fitted.slot, SwitcherBand.minSlot)
        let used = CGFloat(fitted.views.count) * fitted.slot + CGFloat(max(0, fitted.views.count - 1)) * fitted.gap
        XCTAssertLessThanOrEqual(used, 60)
    }

    // MARK: - The section grid

    /// Every section is given the same 140 pt, and what each one puts in it has to fill that
    /// without spilling out of it. These are the numbers a spacing change is most likely to
    /// break silently: the panel clips, so an overflow shows up as a truncated last line
    /// rather than as anything that fails.
    func testWhatEachSectionPutsInItsBodyFitsThatBody() {
        XCTAssertEqual(SectionMetrics.bodyHeight,
                       IslandLayout.sectionHeight - SectionMetrics.headerHeight - SectionMetrics.gapBelowHeader)

        XCTAssertLessThanOrEqual(WindowsSectionView.stripHeight, SectionMetrics.bodyHeight,
                                 "the window tiles and their names must not spill past the section")
        XCTAssertGreaterThan(WindowsSectionView.stripHeight, SectionMetrics.bodyHeight - 8,
                             "a strip well short of the body leaves a band of black under it")

        XCTAssertLessThanOrEqual(ShelfStripView.stripHeight, SectionMetrics.bodyHeight,
                                 "the shelf's tiles and the air around them must fit the body")
        XCTAssertGreaterThan(ShelfStripView.stripHeight, SectionMetrics.bodyHeight - 16,
                             "a shelf well short of the body wastes the room a preview wants")

        // Header, the buttons, the hairline and the presets, with room left for the gap
        // above and below the rule.
        let fixed = ActionsSectionView.actionsRow + ActionsSectionView.timerRowHeight + 0.5
        XCTAssertLessThanOrEqual(fixed + ActionsSectionView.ruleGap * 2, SectionMetrics.bodyHeight,
                                 "the two rows and the rule between them must fit with their gaps")
    }

    func testFourWindowTilesFillTheRowTheHeaderIsMeasuredAgainst() {
        let used = 4 * WindowsSectionView.tileWidth + 3 * WindowsSectionView.tileGap
        XCTAssertLessThanOrEqual(used, IslandLayout.panelContentWidth,
                                 "a fourth tile that does not fit turns a full row into a scroll")
        // The header's count sits on the right edge of this same column, so a row that stops
        // short of it reads as a mistake rather than as a strip with more to come.
        XCTAssertGreaterThan(used, IslandLayout.panelContentWidth - 6,
                             "the strip stops \(IslandLayout.panelContentWidth - used) pt short of the right edge")
    }

    func testEveryControlTheRailCanShowFitsTheRailAtOnce() {
        // A Mac with a brightness slider, Wi-Fi, Bluetooth, a second output and something on
        // the shelf shows all of it. The rail has no room to overflow into: it is one row of
        // the panel's own column.
        XCTAssertLessThanOrEqual(RailMetrics.widest, IslandLayout.panelContentWidth,
                                 "the rail overflows by \(RailMetrics.widest - IslandLayout.panelContentWidth) pt")
        // And not so far short that the row looks lost in the middle of the panel.
        XCTAssertGreaterThan(RailMetrics.widest, IslandLayout.panelContentWidth - 80)
    }

    func testTheRailsGlyphHangsFromTheSameColumnAsEverythingAboveIt() {
        // 22 pt, hanging from the leading edge rather than centred in a wider box: the first
        // glyph of the rail is the panel's leftmost mark.
        XCTAssertEqual(RailMetrics.glyph, 22)
        XCTAssertGreaterThan(RailMetrics.button, RailMetrics.glyph, "a disc is a bigger target than a bare glyph")
    }

    // MARK: - Favourite apps

    func testADeletedAppLeavesTheFavouritesButAnUnpluggedOneStays() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Thing.app")
        try Data("app".utf8).write(to: app)
        XCTAssertTrue(FavoriteApps.worthKeeping(app.path), "it is there")
        try FileManager.default.removeItem(at: app)
        XCTAssertFalse(FavoriteApps.worthKeeping(app.path), "deleted: forget it")
        XCTAssertTrue(FavoriteApps.worthKeeping("/Volumes/Nothing Here/Thing.app"),
                      "a whole folder missing is an unplugged disk, not a deleted app")
    }

    // MARK: - Menu bar hysteresis

    func testTheIslandIgnoresAMenuBarThatMovedByAHair() {
        let old = MenuBarClearance.Limits(leading: 200, trailing: 120)
        let jitter = MenuBarClearance.settled(MenuBarClearance.Limits(leading: 203, trailing: 117), from: old)
        XCTAssertEqual(jitter, old, "a couple of points either way must not resize the island")
        let real = MenuBarClearance.settled(MenuBarClearance.Limits(leading: 60, trailing: 120), from: old)
        XCTAssertEqual(real.leading, 60, "a menu that really is in the way still moves it")
        XCTAssertEqual(real.trailing, 120)
    }

    // MARK: - Artwork lookup

    func testTheSearchAsksForTheArtistAndTitle() {
        let info = NowPlayingInfo(title: "Alright", artist: "Kendrick Lamar", album: "To Pimp a Butterfly",
                                  duration: 219, elapsed: 0, timestamp: Date(), isPlaying: true,
                                  bundleID: "com.apple.Music", artwork: nil, artworkID: 0, accent: .white)
        let url = ArtworkFetcher.searchURL(for: ArtworkFetcher.Key(info))
        XCTAssertEqual(url?.host, "itunes.apple.com")
        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("kendrick"), query)
        XCTAssertTrue(query.contains("alright"), query)
    }

    func testACoverIsAskedForAtFullSize() {
        let json = """
        {"resultCount":1,"results":[{"artworkUrl100":"https://example.com/art/100x100bb.jpg"}]}
        """.data(using: .utf8)!
        let url = ArtworkFetcher.artworkURL(fromSearch: json)
        XCTAssertEqual(url?.absoluteString, "https://example.com/art/\(ArtworkFetcher.size)x\(ArtworkFetcher.size)bb.jpg")
    }

    func testAnEmptySearchResultIsNoCover() {
        let json = #"{"resultCount":0,"results":[]}"#.data(using: .utf8)!
        XCTAssertNil(ArtworkFetcher.artworkURL(fromSearch: json))
    }

    // MARK: - The panel is one thing

    func testEveryPanelViewSharesOneIdentity() {
        let home = IslandPresentation.panel(.home(tab: HomeSection.music.rawValue))
        let other = IslandPresentation.panel(.home(tab: HomeSection.windows.rawValue))
        let activity = IslandPresentation.panel(.activity(id: "timer"))
        XCTAssertEqual(home.contentID, other.contentID, "stepping between sections must not rebuild the panel")
        XCTAssertEqual(home.contentID, activity.contentID)
        XCTAssertEqual(IslandPresentation.shelf.contentID, home.contentID)
        XCTAssertNotEqual(home.contentID, IslandPresentation.idle.contentID)
    }

    // MARK: - A drag holds the panel open

    func testASliderDragHoldsThePanelUnderThePointer() {
        let center = ActivityCenter.shared
        center.resetForTesting()
        Preferences.shared.hoverToExpand = true
        Preferences.shared.hoverDelay = 0.01
        center.setHovering(true, panel: "main")
        let arrived = expectation(description: "hovering")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { arrived.fulfill() }
        wait(for: [arrived], timeout: 1)
        XCTAssertTrue(center.isHovering)

        center.setControlDragging(true)
        center.setHovering(false, panel: "main")
        let left = expectation(description: "pointer left")
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivityCenter.hoverExitGrace + 0.2) { left.fulfill() }
        wait(for: [left], timeout: 2)
        XCTAssertTrue(center.isHovering, "the panel stays while the slider is being dragged")

        center.setControlDragging(false)
        XCTAssertFalse(center.isHovering, "and closes the moment the button comes up")
        center.resetForTesting()
    }

    // MARK: - A name under a picture

    /// A tile whose name is wider than its picture and hung from the same leading edge puts
    /// every name a few points left of the thing it names, and a different few for each: a
    /// short name hugs the left of its box, a long one fills it. Either the name is centred on
    /// the picture, or the picture is centred in the name's box — never both left.
    func testShelfTilesAreAsWideAsThePictureInThem() {
        XCTAssertEqual(ShelfItemView.column, ShelfItemView.thumbnailSize,
                       "the name is centred under the picture, so the tile is the picture")
        XCTAssertEqual(ShelfItemView.height,
                       ShelfItemView.thumbnailSize + ShelfItemView.labelGap + ShelfItemView.labelHeight)
    }

    /// The Actions row does it the other way about — the disc is the tile, so it lands on the
    /// panel's content column, and the name is centred on it and overhangs. Which only works
    /// if the row's spacing is wide enough that two names at full width cannot meet.
    func testTwoQuickActionNamesCannotTouch() {
        let overhang = (ActionTile.label - ActionTile.diameter) / 2
        XCTAssertGreaterThan(overhang, 0, "the name is the wider of the two")
        XCTAssertGreaterThan(ActionTile.gap, overhang * 2, "and the row leaves air between them")
        // Eight of them is what the row holds; they still fit the panel's content column.
        let count: CGFloat = CGFloat(QuickActionsRowView.capacity)
        let used = count * ActionTile.diameter + (count - 1) * ActionTile.gap
        XCTAssertLessThanOrEqual(used, IslandLayout.panelContentWidth)
    }
}
