import AppKit
import CoreAudio
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

    // MARK: - Sending a window to another display

    private func display(_ rect: CGRect, inset: CGFloat = 0) -> (full: CGRect, visible: CGRect) {
        (full: rect, visible: rect.insetBy(dx: 0, dy: inset))
    }

    func testTheDisplayAWindowIsOnIsTheOneItsCentreIsIn() {
        let screens = [display(CGRect(x: 0, y: 0, width: 1000, height: 800)),
                       display(CGRect(x: 1000, y: 0, width: 1600, height: 900))]
        XCTAssertEqual(WindowsMonitor.displayIndex(of: CGRect(x: 100, y: 100, width: 200, height: 200), in: screens), 0)
        XCTAssertEqual(WindowsMonitor.displayIndex(of: CGRect(x: 1200, y: 100, width: 200, height: 200), in: screens), 1)
    }

    func testAWindowHalfOffTheEdgeStillBelongsSomewhere() {
        let screens = [display(CGRect(x: 0, y: 0, width: 1000, height: 800)),
                       display(CGRect(x: 1000, y: 0, width: 1600, height: 900))]
        // Centre out past the right-hand edge of everything: it overlaps the second most.
        let stray = CGRect(x: 2400, y: 100, width: 400, height: 200)
        XCTAssertEqual(WindowsMonitor.displayIndex(of: stray, in: screens), 1)
        XCTAssertNil(WindowsMonitor.displayIndex(of: stray, in: []))
    }

    func testAWindowKeepsTheShareOfTheScreenItHadWhenItMoves() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let to = CGRect(x: 1000, y: 0, width: 2000, height: 1600)
        // A left half stays a left half.
        let half = WindowsMonitor.mapped(CGRect(x: 0, y: 0, width: 500, height: 800), from: from, to: to)
        XCTAssertEqual(half, CGRect(x: 1000, y: 0, width: 1000, height: 1600))
        // And a small window in the middle stays small and in the middle.
        let small = WindowsMonitor.mapped(CGRect(x: 250, y: 200, width: 500, height: 400), from: from, to: to)
        XCTAssertEqual(small, CGRect(x: 1500, y: 400, width: 1000, height: 800))
    }

    func testAWindowNeverArrivesHangingOffTheEdge() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let to = CGRect(x: 0, y: 0, width: 600, height: 400)
        // Bigger than the display it is going to, and starting past its far corner.
        let moved = WindowsMonitor.mapped(CGRect(x: 900, y: 700, width: 900, height: 700), from: from, to: to)
        XCTAssertGreaterThanOrEqual(moved.minX, to.minX)
        XCTAssertGreaterThanOrEqual(moved.minY, to.minY)
        XCTAssertLessThanOrEqual(moved.maxX, to.maxX)
        XCTAssertLessThanOrEqual(moved.maxY, to.maxY)
    }

    func testADisplayWithNoAreaIsNotDividedBy() {
        let empty = CGRect.zero
        let to = CGRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertEqual(WindowsMonitor.mapped(CGRect(x: 0, y: 0, width: 10, height: 10), from: empty, to: to), to)
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

    // MARK: - Laying several windows out at once

    private var tileScreen: CGRect { CGRect(x: 0, y: 25, width: 1440, height: 875) }

    func testTwoWindowsShareTheScreenDownTheMiddle() {
        let frames = WindowsMonitor.tileFrames(count: 2, in: tileScreen)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(frames[1], CGRect(x: 720, y: 25, width: 720, height: 875))
    }

    func testThreeWindowsGoAcrossRatherThanTwoAndOne() {
        // A grid would make one of them twice the size of the others; three columns is the
        // layout people mean on a laptop's width.
        let frames = WindowsMonitor.tileFrames(count: 3, in: tileScreen)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(Set(frames.map(\.height)), [875], "one row")
        XCTAssertEqual(frames.map(\.minX), [0, 480, 960])
    }

    func testFourWindowsGoInQuarters() {
        let frames = WindowsMonitor.tileFrames(count: 4, in: tileScreen)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(Set(frames.map(\.width)), [720], "two columns")
        XCTAssertEqual(Set(frames.map(\.minY)).count, 2, "two rows")
    }

    func testEveryLayoutFillsTheScreenExactlyAndNothingOverlaps() {
        for count in 1...9 {
            let frames = WindowsMonitor.tileFrames(count: count, in: tileScreen)
            XCTAssertEqual(frames.count, count)
            let area = frames.reduce(0.0) { $0 + $1.width * $1.height }
            XCTAssertEqual(area, tileScreen.width * tileScreen.height, accuracy: 1,
                           "\(count) windows should cover the screen and no more")
            for (i, a) in frames.enumerated() {
                XCTAssertTrue(tileScreen.contains(a), "\(count): \(a) hangs off the screen")
                for b in frames[(i + 1)...] {
                    XCTAssertTrue(a.intersection(b).isEmpty, "\(count): \(a) overlaps \(b)")
                }
            }
        }
    }

    func testOneWindowIsNotALayout() {
        XCTAssertEqual(WindowsMonitor.tileFrames(count: 1, in: tileScreen), [tileScreen])
        XCTAssertTrue(WindowsMonitor.tileFrames(count: 0, in: tileScreen).isEmpty)
    }

    // MARK: - The networks in range

    private func network(_ ssid: String, _ rssi: Int, current: Bool = false,
                         known: Bool = false, secure: Bool = true) -> WiFiScanner.Network {
        WiFiScanner.Network(ssid: ssid, strength: rssi, isSecure: secure, isCurrent: current, isKnown: known)
    }

    func testTheNetworkYouAreOnComesFirstAndTheRestByStrength() {
        let list = WiFiScanner.ordered([
            network("Café", -70),
            network("Home", -45),
            network("Phone", -55, current: true),
        ])
        XCTAssertEqual(list.map(\.ssid), ["Phone", "Home", "Café"])
    }

    func testTwoNetworksOfTheSameStrengthAreOrderedByName() {
        let list = WiFiScanner.ordered([network("Zebra", -60), network("Apple", -60)])
        XCTAssertEqual(list.map(\.ssid), ["Apple", "Zebra"])
    }

    func testTheBarsFollowTheStrength() {
        XCTAssertEqual(WiFiScanner.bars(forRSSI: -30), 4, "next to the router")
        XCTAssertEqual(WiFiScanner.bars(forRSSI: -50), 4)
        XCTAssertEqual(WiFiScanner.bars(forRSSI: -60), 3)
        XCTAssertEqual(WiFiScanner.bars(forRSSI: -70), 2)
        XCTAssertEqual(WiFiScanner.bars(forRSSI: -95), 1, "the edge of nothing is still one bar")
        // Whatever the radio reports, it lands on one of the four.
        for rssi in stride(from: -100, through: 0, by: 5) {
            XCTAssertTrue((1...4).contains(WiFiScanner.bars(forRSSI: rssi)), "\(rssi)")
        }
    }

    func testControlsIsASectionWithASwitchOfItsOwn() {
        let prefs = Preferences.shared
        defer { prefs.controlsEnabled = true }
        XCTAssertTrue(HomeSection.controls.isEnabled(prefs))
        HomeSection.controls.setEnabled(false, in: prefs)
        XCTAssertFalse(HomeSection.controls.isEnabled(prefs))
        XCTAssertFalse(HomeSection.available(prefs).contains(.controls))
    }

    // MARK: - The sound column

    private func device(_ id: UInt32, _ name: String,
                        _ transport: UInt32 = kAudioDeviceTransportTypeBuiltIn) -> AudioOutputs.Device {
        AudioOutputs.Device(id: AudioDeviceID(id), name: name, transport: transport)
    }

    func testWhereTheSoundGoesComesBeforeWhereItComesFrom() {
        let speakers = device(1, "MacBook Air Speakers")
        let airpods = device(2, "AirPods Pro", kAudioDeviceTransportTypeBluetooth)
        let mic = device(3, "MacBook Air Microphone")
        let entries = SoundList.entries(outputs: [speakers, airpods], current: airpods,
                                        inputs: [mic], currentInput: mic)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.first, .heading(SoundList.output))
        XCTAssertEqual(entries[1], .device(speakers, isCurrent: false, isInput: false))
        XCTAssertEqual(entries[2], .device(airpods, isCurrent: true, isInput: false), "the one playing is ticked")
        XCTAssertEqual(entries[3], .heading(SoundList.input))
        XCTAssertEqual(entries[4], .device(mic, isCurrent: true, isInput: true))
    }

    func testAHeadingIsOnlyThereWhenSomethingIsUnderIt() {
        let speakers = device(1, "MacBook Air Speakers")
        let outputsOnly = SoundList.entries(outputs: [speakers], current: speakers, inputs: [], currentInput: nil)
        XCTAssertEqual(outputsOnly.count, 2)
        XCTAssertFalse(outputsOnly.contains(.heading(SoundList.input)))
        XCTAssertTrue(SoundList.entries(outputs: [], current: nil, inputs: [], currentInput: nil).isEmpty,
                      "a Mac with no sound card draws no headings at all")
    }

    func testTheHeadphonesOnBothSidesAreTwoRowsNotOne() {
        // AirPods record as well as play, and CoreAudio hands back one id for both. Keyed on
        // that alone the list drew the pair once and SwiftUI complained about the duplicate.
        let airpods = device(7, "AirPods Pro", kAudioDeviceTransportTypeBluetooth)
        let entries = SoundList.entries(outputs: [airpods], current: airpods,
                                        inputs: [airpods], currentInput: airpods)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    }

    func testTheDeviceNamesItselfAfterTheMacRatherThanItsSpeakers() {
        XCTAssertEqual(device(1, "MacBook Air Speakers").shortName, "MacBook Air")
        XCTAssertEqual(device(2, "AirPods Pro", kAudioDeviceTransportTypeBluetooth).shortName, "AirPods Pro")
    }

    func testThreeColumnsAndTwoGuttersFillTheSection() {
        let used = CGFloat(ControlsSectionView.columns) * ControlsSectionView.columnWidth
            + CGFloat(ControlsSectionView.columns - 1) * ControlsSectionView.gutter
        XCTAssertLessThanOrEqual(used, IslandLayout.panelContentWidth)
        XCTAssertGreaterThan(used, IslandLayout.panelContentWidth - CGFloat(ControlsSectionView.columns),
                             "at most a point lost per column to rounding")
    }

    // MARK: - The level on a device row

    func testTheEarThatRunsOutFirstIsTheOneOnTheRow() {
        XCTAssertEqual(BluetoothBattery.summary(BluetoothBattery.Levels(left: 88, right: 62)), 62,
                       "a pair stops working when the emptier bud does")
        XCTAssertEqual(BluetoothBattery.summary(BluetoothBattery.Levels(left: 40, right: 95)), 40)
    }

    func testOneEarAnsweringIsEnoughForARow() {
        XCTAssertEqual(BluetoothBattery.summary(BluetoothBattery.Levels(right: 74)), 74,
                       "a bud still in the case reports nothing, and the other one is in use")
        XCTAssertEqual(BluetoothBattery.summary(BluetoothBattery.Levels(left: 74)), 74)
    }

    func testAKeyboardHasOneBatteryAndThatIsTheOneShown() {
        XCTAssertEqual(BluetoothBattery.summary(BluetoothBattery.Levels(single: 42)), 42)
        XCTAssertEqual(BluetoothBattery.summary(BluetoothBattery.Levels(left: 55, caseLevel: 20, single: 90)), 55,
                       "what is in your ears comes before the case and before any single reading")
    }

    func testANumberOffTheScaleIsNotAReading() {
        // Asleep, or never asked, a device leaves a 0 behind in the registry; a flat one would
        // have long since stopped answering at all.
        XCTAssertNil(BluetoothBattery.summary(BluetoothBattery.Levels(left: 0, right: 0)))
        XCTAssertNil(BluetoothBattery.summary(BluetoothBattery.Levels(single: 101)))
        XCTAssertNil(BluetoothBattery.summary(BluetoothBattery.Levels(single: -1)))
        XCTAssertEqual(BluetoothBattery.summary(BluetoothBattery.Levels(left: 0, right: 66)), 66,
                       "the ear that did answer is still worth a number")
        XCTAssertEqual(BluetoothBattery.summary(BluetoothBattery.Levels(left: 0, single: 30)), 30)
    }

    func testADeviceThatSaysNothingGetsNoLevelAtAll() {
        XCTAssertNil(BluetoothBattery.summary(BluetoothBattery.Levels()))
        XCTAssertNil(BluetoothBattery.summary(BluetoothBattery.Levels(caseLevel: 80)),
                     "a case on its own is not the level of the thing you are wearing")
    }
}
