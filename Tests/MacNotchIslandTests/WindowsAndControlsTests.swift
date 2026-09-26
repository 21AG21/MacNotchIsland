import AppKit
import CoreAudio
import CoreBluetooth
import CoreLocation
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

    /// One entry of the window server's list. `onScreen` nil leaves the key out, which is how
    /// a list taken with `.optionAll` reports a window that is not on screen.
    private func entry(id: CGWindowID, layer: Int = 0, owner: String = "Safari", name: String = "A page",
                       bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600), alpha: Double = 1,
                       pid: pid_t = 1, onScreen: Bool? = true) -> [String: Any] {
        var entry: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowLayer as String: layer,
            kCGWindowOwnerPID as String: pid,
            kCGWindowOwnerName as String: owner,
            kCGWindowName as String: name,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height).dictionaryRepresentation,
        ]
        if let onScreen { entry[kCGWindowIsOnscreen as String] = onScreen }
        return entry
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

    // MARK: - Windows put away

    private func away(pid: pid_t = 1, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
                      title: String = "", _ reason: IslandWindow.Away = .minimised) -> PutAwayWindow {
        PutAwayWindow(pid: pid, frame: frame, title: title, away: reason)
    }

    /// The minus on a tile put its window in the Dock and the tile went with it — the list was
    /// of the windows on screen and nothing else — and "Hide Safari" did the same to every
    /// Safari window. A window Accessibility says is minimised, or behind its hidden app, stays:
    /// after the ones in view, and marked as put away so it can be drawn dimmed.
    func testAWindowPutAwayStaysInTheListAfterTheOnesOnScreen() {
        let notes = CGRect(x: 40, y: 60, width: 500, height: 400)
        let windows = WindowsMonitor.list(now: [
            entry(id: 1, onScreen: false),                                              // in the Dock
            entry(id: 2, owner: "Mail", name: "Inbox", pid: 2),
            entry(id: 3, owner: "Notes", name: "Groceries", bounds: notes, pid: 3, onScreen: nil),
        ], putAway: [
            away(),
            away(pid: 3, frame: notes, .hidden),
        ])
        XCTAssertEqual(windows.map(\.id), [2, 1, 3], "what is in view first, then what was put away")
        XCTAssertNil(windows[0].away)
        XCTAssertEqual(windows[1].away, .minimised)
        XCTAssertEqual(windows[2].away, .hidden)
    }

    /// Off screen is also every window on another desktop and every window an app keeps
    /// ordered out, none of which a click on a tile could bring back. Without Accessibility
    /// vouching for one, it stays out — and the section says "on this desktop".
    func testAWindowOutOfSightIsOnlyListedWhenItWasPutAway() {
        let info = [entry(id: 1), entry(id: 2, onScreen: false), entry(id: 3, onScreen: nil)]
        XCTAssertEqual(WindowsMonitor.list(now: info).map(\.id), [1], "on another desktop, or never shown")
        let elsewhere = away(frame: CGRect(x: 900, y: 0, width: 800, height: 600))
        XCTAssertEqual(WindowsMonitor.list(now: info, putAway: [elsewhere]).map(\.id), [1],
                       "a window put away somewhere else is not one of these")
        XCTAssertEqual(WindowsMonitor.list(now: info, putAway: [away(pid: 9)]).map(\.id), [1],
                       "nor is another app's")
    }

    /// Where the window goes back to is what the two sides always share: Accessibility reads a
    /// title without Screen Recording, and the window list does not.
    func testAPutAwayWindowIsKnownByWhereItGoesBackToOrByItsName() {
        let untitled = entry(id: 1, name: "", onScreen: false)
        XCTAssertEqual(WindowsMonitor.list(now: [untitled], putAway: [away(title: "Report.pdf")]).first?.away,
                       .minimised)
        let neighbour = entry(id: 2, name: "Other.pdf", onScreen: false)
        XCTAssertTrue(WindowsMonitor.list(now: [neighbour], putAway: [away(title: "Report.pdf")]).isEmpty,
                      "a title that disagrees rules out a window of the same size")
        let placedApart = entry(id: 3, name: "Report.pdf", bounds: CGRect(x: 300, y: 200, width: 800, height: 600),
                                onScreen: false)
        XCTAssertEqual(WindowsMonitor.list(now: [placedApart], putAway: [away(title: "Report.pdf")]).map(\.id), [3],
                       "and the name alone finds one the two sides place differently")
    }

    func testOneWindowPutAwayAnswersForOneListedWindow() {
        let twins = [entry(id: 1, name: "", onScreen: false), entry(id: 2, name: "", onScreen: false)]
        XCTAssertEqual(WindowsMonitor.list(now: twins, putAway: [away()]).map(\.id), [1],
                       "two entries the same size cannot both be the one window in the Dock")
    }

    /// Two Safari windows called "Start Page": one on another desktop, earlier in the window
    /// server's list, and one in the Dock. Asked entry by entry, the first took the minimised
    /// one's report by its name before the second could sit on it, and the tile carried the
    /// other desktop's window — its id and its frame — while the one in the Dock went unlisted.
    func testWhereAWindowSitsIsAskedOfTheWholeListBeforeItsName() {
        let dock = CGRect(x: 120, y: 80, width: 900, height: 700)
        let info = [
            entry(id: 1, name: "Start Page", bounds: CGRect(x: 600, y: 300, width: 800, height: 600), onScreen: nil),
            entry(id: 2, name: "Start Page", bounds: dock, onScreen: false),
        ]
        let windows = WindowsMonitor.list(now: info, putAway: [away(frame: dock, title: "Start Page")])
        XCTAssertEqual(windows.map(\.id), [2], "the window in the Dock, and not the one on another desktop")
        XCTAssertEqual(windows.first?.frame, dock, "so Snap moves the window that is there")
        XCTAssertEqual(windows.first?.away, .minimised)

        // A second report with nothing sitting under it still finds its window by name, once
        // every window that does sit on one has been given it.
        let hidden = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let safari = { (id: CGWindowID, frame: CGRect) in
            IslandWindow(id: id, title: "Start Page", appName: "Safari", pid: 1, frame: frame, icon: nil, thumbnail: nil)
        }
        let both = WindowsMonitor.claimed([safari(1, CGRect(x: 600, y: 300, width: 800, height: 600)), safari(2, dock)],
                                          by: [away(frame: dock, title: "Start Page"),
                                               away(frame: hidden, title: "Start Page", .hidden)])
        XCTAssertEqual(both.map(\.id), [1, 2], "in the window server's order")
        XCTAssertEqual(both.map(\.away), [.hidden, .minimised],
                       "each has the report that is its own: where it sits first, the name for the rest")
    }

    func testOnlyAppsWithAWindowOutOfSightAreAskedAboutIt() {
        let info = [
            entry(id: 1, pid: 1),
            entry(id: 2, pid: 2, onScreen: false),
            entry(id: 3, layer: 25, pid: 3, onScreen: false),                                  // a status item
            entry(id: 4, bounds: CGRect(x: 0, y: 0, width: 60, height: 40), pid: 4, onScreen: false),   // a palette
        ]
        XCTAssertEqual(WindowsMonitor.appsWithWindowsOutOfSight(in: info), [2],
                       "an app with everything in view has nothing put away, and is not asked")
    }

    // MARK: - The switcher band

    private var views: [IslandView] { HomeSection.allCases.map { .home(tab: $0.rawValue) } }

    /// The band's trailing side on a 15-inch notch: what the sections actually get.
    private var bandSide: CGFloat {
        let middle = 185 + SwitcherBand.cutoutMargin * 2
        return (IslandLayout.panelWidth - middle) / 2 - SwitcherBand.inset
    }

    /// The band gives up its spacing before it gives up a slot, and gives up a slot before it
    /// draws one nobody can hit — so with more sections switched on than the panel's width can
    /// hold at that size, what has to be true is this: every section the row has room for
    /// keeps its place, in order, from the head of the row. A slot that will not fit must
    /// never shuffle the ones that do, and none that had room to stand in may be dropped.
    func testTheBandKeepsEverySectionItHasRoomForAndDropsFromTheEnd() {
        let fitted = SwitcherBand.fit(views, in: bandSide)
        XCTAssertGreaterThanOrEqual(fitted.slot, SwitcherBand.minSlot)
        XCTAssertEqual(fitted.views, Array(views.prefix(fitted.views.count)),
                       "what is shown is the head of the row, in the order it is written in")
        let used = CGFloat(fitted.views.count) * fitted.slot
            + CGFloat(max(0, fitted.views.count - 1)) * fitted.gap
        XCTAssertLessThanOrEqual(used, bandSide)
        guard fitted.views.count < views.count else { return }
        let another = CGFloat(fitted.views.count + 1) * fitted.slot
            + CGFloat(fitted.views.count) * fitted.gap
        XCTAssertGreaterThan(another, bandSide, "a slot was dropped that had room to stand in")
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

    /// The Actions rule is half a point tall, and it draws as one crisp pixel on a Retina
    /// display only if it starts on a whole one. With 64 pt of buttons the two spacers shared
    /// 17.5 pt and the rule fell at 102.75, between two pixels.
    func testTheActionsRuleLandsOnAWholePixel() {
        let fixed = ActionsSectionView.actionsRow + ActionsSectionView.timerRowHeight + 0.5
        XCTAssertEqual(SectionMetrics.bodyHeight - fixed, ActionsSectionView.ruleGap * 2,
                       "the spacers come out at exactly the gap they are named for")
        let rule = SectionMetrics.headerHeight + SectionMetrics.gapBelowHeader
            + ActionsSectionView.actionsRow + ActionsSectionView.ruleGap
        XCTAssertEqual(rule, 103.5)
        XCTAssertEqual((rule * 2).rounded(), rule * 2, "a whole pixel at 2×")
    }

    /// Today with the weather on: the hours along the floor take their strip and the gap above
    /// it out of the room the rows are counted against. The list went on counting the whole
    /// body, so the gallery's day — two events and a reminder, 100 pt — was laid out in 62 and
    /// pushed the hours off the bottom of the section.
    func testTodaysRowsAreCountedAgainstTheRoomTheHoursLeave() {
        XCTAssertEqual(TodaySectionView.listHeight(showingHours: false), SectionMetrics.bodyHeight)
        let withHours = TodaySectionView.listHeight(showingHours: true)
        XCTAssertEqual(SectionMetrics.headerHeight + SectionMetrics.gapBelowHeader + withHours
                       + SectionMetrics.gapBelowHeader + TodaySectionView.hourlyHeight,
                       IslandLayout.sectionHeight, "the header, the rows, a gap and the hours fill the section")
        let plain = TodaySectionView.fit(events: 2, reminders: 2, in: SectionMetrics.bodyHeight)
        XCTAssertEqual(plain.events, 2)
        XCTAssertEqual(plain.reminders, 1, "36 + 36 + 28 = 100 of 110; a second reminder is 128")
        XCTAssertEqual(plain.left, 1, "and the reminder that did not fit is counted, not lost")
        let hours = TodaySectionView.fit(events: 2, reminders: 2, in: withHours)
        XCTAssertEqual(hours.events, 1, "36 of 60; a second event is 72")
        XCTAssertEqual(hours.reminders, 0, "and a reminder after it is 64")
        XCTAssertEqual(hours.left, 3)
        let many = TodaySectionView.fit(events: 5, reminders: 0, in: 1000)
        XCTAssertEqual(many.events, 3, "never more than three events")
        XCTAssertEqual(many.left, 2, "and the rest are counted too")
    }

    /// With the weather on there is room for one event, and a second event or every reminder
    /// of the day went missing with nothing to say so and nothing to scroll. What the room
    /// leaves out goes in the header, and every row is either shown or counted.
    func testWhatTheRoomLeavesOutIsSaidInTheHeader() {
        XCTAssertEqual(TodaySectionView.title(left: 0), "Today", "a day that fits says nothing more")
        XCTAssertEqual(TodaySectionView.title(left: 2), "Today · 2 more")
        let room = TodaySectionView.listHeight(showingHours: true)
        XCTAssertEqual(TodaySectionView.fit(events: 1, reminders: 0, in: room).left, 0,
                       "one event fits beside the hours, and nothing is said")
        for (events, reminders) in [(0, 5), (3, 4), (6, 1), (2, 0)] {
            for height in [room, TodaySectionView.listHeight(showingHours: false)] {
                let fitted = TodaySectionView.fit(events: events, reminders: reminders, in: height)
                XCTAssertEqual(fitted.events + fitted.reminders + fitted.left, events + reminders,
                               "\(events) events and \(reminders) reminders in \(height) pt")
            }
        }
    }

    /// "N more" is only said of a list that is on screen. With Calendars refused, Reminders
    /// allowed and the weather on, three reminders read "Today · 1 more" above "Calendar
    /// access is off", and the section counted as one that scrolls — so a scroll there neither
    /// scrolled nor changed the volume.
    func testNothingIsLeftOutOfAListThatIsNotOnScreen() {
        let room = TodaySectionView.listHeight(showingHours: true)
        XCTAssertEqual(TodaySectionView.leftOut(events: 0, reminders: 3, in: room, calendarOff: false), 1,
                       "the calendar allowed: two reminders fit beside the hours and one is counted")
        XCTAssertEqual(TodaySectionView.leftOut(events: 0, reminders: 3, in: room, calendarOff: true), 0,
                       "refused: the empty state is on screen, and there is nothing for 'more' to be more of")
        XCTAssertEqual(TodaySectionView.title(left: TodaySectionView.leftOut(events: 0, reminders: 3, in: room,
                                                                             calendarOff: true)), "Today")
        XCTAssertFalse(TodaySectionView.showsList(calendarOff: true, rows: 3))
        XCTAssertFalse(TodaySectionView.showsList(calendarOff: false, rows: 0), "the day's own empty state")
        XCTAssertTrue(TodaySectionView.showsList(calendarOff: false, rows: 1))
        for (events, reminders) in [(0, 0), (1, 0), (3, 4), (0, 6)] {
            for height in [room, TodaySectionView.listHeight(showingHours: false)] {
                XCTAssertEqual(TodaySectionView.leftOut(events: events, reminders: reminders, in: height, calendarOff: false),
                               TodaySectionView.fit(events: events, reminders: reminders, in: height).left,
                               "with the list on screen it is exactly what the room left out")
            }
        }
    }

    /// The transport row takes what the rows above it leave, and the buttons take their clicks
    /// in that row rather than in 42 pt frames that reached over the scrubber's times.
    func testTheTransportRowFillsTheNowPlayingSection() {
        // The artwork row, a gap, the scrubber and its times, and the gap above the transport.
        let above: CGFloat = 60 + 8 + (14 + 4 + 14) + 4
        XCTAssertEqual(above + MusicSectionView.transportRow, IslandLayout.sectionHeight)
        XCTAssertEqual(MusicSectionView.transportRow, MusicSectionView.transportGlyph + 12)
        XCTAssertEqual(MusicSectionView.transportRow + MusicSectionView.transportSpacing, 72,
                       "the glyphs' centres stay where they were")
    }

    func testFourWindowTilesFillTheRowTheHeaderIsMeasuredAgainst() {
        let used = 4 * WindowsSectionView.tileWidth + 3 * WindowsSectionView.tileGap
        XCTAssertLessThanOrEqual(used, IslandLayout.panelContentWidth,
                                 "a fourth tile that does not fit turns a full row into a scroll")
        // The header's count sits on the right edge of this same column, so a row that stops
        // short of it reads as a mistake rather than as a strip with more to come.
        XCTAssertGreaterThan(used, IslandLayout.panelContentWidth - 6,
                             "the strip stops \(IslandLayout.panelContentWidth - used) pt short of the right edge")
        // Exactly, now: three gaps of 10 left 160.5 a tile, rounded down to 2 pt short.
        XCTAssertEqual(used, IslandLayout.panelContentWidth, "four tiles of 162 and three gaps of 8")
    }

    /// The three discs under a hovered shelf tile are drawn at 18 pt and take their clicks in
    /// 24, and the gap between them is what keeps two of those targets from lying over each
    /// other: the three of them come to the tile's width exactly.
    func testTheShelfTilesButtonsAreBigEnoughToHitAndDoNotOverlap() {
        let reach = IslandHit.outset(drawn: ShelfItemView.buttonSize)
        XCTAssertEqual(ShelfItemView.buttonSize + 2 * reach, IslandHit.minimum)
        XCTAssertGreaterThanOrEqual(ShelfItemView.buttonGap, 2 * reach, "two targets never lie over each other")
        let row = 3 * ShelfItemView.buttonSize + 2 * ShelfItemView.buttonGap + 2 * reach
        XCTAssertLessThanOrEqual(row, ShelfItemView.column, "and the outer two stay inside the tile")
    }

    // MARK: - Controls that stay under the pointer

    /// The timer glyph at the head of the Actions row is drawn 16 pt wide and takes its clicks
    /// in 24, reaching no further than the gap before the first preset.
    func testTheTimerGlyphIsATargetThePointerIsOwed() {
        let reach = IslandHit.outset(drawn: ActionsSectionView.timerGlyphWidth)
        XCTAssertEqual(ActionsSectionView.timerGlyphWidth + 2 * reach, IslandHit.minimum)
        XCTAssertLessThanOrEqual(reach, ActionsSectionView.timerRowSpacing,
                                 "the target stops short of the first preset's")
        XCTAssertGreaterThanOrEqual(ActionsSectionView.timerRowHeight, IslandHit.minimum)
    }

    /// The stopwatch's pill keeps the width of its longest word, which only works if every
    /// word it can show is one of the words it is measured by.
    func testTheStopwatchPillIsMeasuredByEveryWordItCanSay() {
        let said = [ActionsSectionView.stopwatchTitle(isRunning: nil),
                    ActionsSectionView.stopwatchTitle(isRunning: true),
                    ActionsSectionView.stopwatchTitle(isRunning: false)]
        XCTAssertEqual(said, ["Stopwatch", "Stop", "Reset"], "start, then stop, and only then reset")
        for word in said {
            XCTAssertTrue(ActionsSectionView.stopwatchTitles.contains(word), "\(word) would change the pill's width")
        }
    }

    /// The three lists' Clear says how many it is about to take whenever a find has narrowed
    /// what is showing, and nothing more when it has not.
    func testTheClearPillCountsWhatAFindHasNarrowedItTo() {
        XCTAssertEqual(ClearPill.title(clearing: 10, query: nil), "Clear")
        XCTAssertEqual(ClearPill.title(clearing: 10, query: ""), "Clear", "an empty field narrows nothing")
        XCTAssertEqual(ClearPill.title(clearing: 10, query: "  "), "Clear")
        XCTAssertEqual(ClearPill.title(clearing: 2, query: "pdf"), "Clear 2")
    }

    /// The rail's sliders take their clicks in 24 pt and draw the same 4 pt track they always
    /// did, inside a row the rail already had room for.
    func testTheRailSlidersTakeTheirClicksInTwentyFourPoints() {
        XCTAssertGreaterThanOrEqual(IslandSlider.hitHeight, IslandHit.minimum)
        XCTAssertEqual(IslandSlider.restingTrack, 4)
        XCTAssertEqual(IslandSlider.activeTrack, 7)
        XCTAssertLessThan(IslandSlider.activeTrack, IslandSlider.hitHeight)
        XCTAssertLessThanOrEqual(IslandSlider.hitHeight, RailMetrics.button,
                                 "no taller than the discs beside it, so the rail does not grow")
    }

    func testTheSevenButtonsTheRailHasAlwaysHadStillFitAtItsWidest() {
        // A Mac with a brightness slider, a second output and something on the shelf has the
        // widest fixed end there is, and the rail still holds everything it held before it had
        // a catalog: six discs and Settings. Nothing that used to be on it moves off it.
        let room = RailMetrics.room(hasPicker: true, hasBrightness: true)
        let classic: [RailControl] = [.wifi, .bluetooth, .display, .keepAwake, .mirror, .airDrop, .settings]
        let fit = RailControl.fit(classic, room: room)
        XCTAssertEqual(fit.rail, classic)
        XCTAssertTrue(fit.spill.isEmpty)
        // And not so far short that the row looks lost in the middle of the panel.
        let spent = classic.reduce(CGFloat(0)) { $0 + RailMetrics.cost(of: $1) }
        XCTAssertLessThan(room - spent, 80)
    }

    func testWhatTheRailKeepsAlwaysFitsTheRail() {
        // Every control switched on, against every shape of the fixed end: what stays on the
        // rail adds up to no more than the column, Settings is its last button, and every
        // control is in one place or the other — never both, never neither.
        for picker in [false, true] {
            for brightness in [false, true] {
                let room = RailMetrics.room(hasPicker: picker, hasBrightness: brightness)
                let fit = RailControl.fit(RailControl.defaultOrder, room: room)
                let spent = fit.rail.reduce(CGFloat(0)) { $0 + RailMetrics.cost(of: $1) }
                XCTAssertLessThanOrEqual(spent, room, "picker \(picker), brightness \(brightness)")
                // The whole row, added up the way the HStack lays it out: the fixed end, the gap
                // before the spacer, the least the spacer may be, and each control with its gap.
                let row = RailMetrics.leading(hasPicker: picker, hasBrightness: brightness)
                    + RailMetrics.gap + RailMetrics.minSpacer + spent
                XCTAssertLessThanOrEqual(row, IslandLayout.panelContentWidth,
                                         "the rail overflows by \(row - IslandLayout.panelContentWidth) pt")
                XCTAssertEqual(fit.rail.last, .settings)
                XCTAssertFalse(fit.spill.contains(.settings), "the one button that has to be found without looking")
                XCTAssertEqual(fit.rail.count + fit.spill.count, RailControl.defaultOrder.count)
                XCTAssertEqual(Set(fit.rail + fit.spill), Set(RailControl.defaultOrder))
            }
        }
    }

    func testTheKeyboardsDiscFitsBesideTheButtonsThatShipOnWithAFileOnTheShelfAndWithout() {
        // Every control that ships on, on a Mac with both radios and a backlit keyboard — with
        // the shelf empty, and with one file on it, which brings AirDrop onto the rail.
        func shipped(shelfHasFiles: Bool) -> [RailControl] {
            RailControl.available(order: RailControl.defaultOrder,
                                  isEnabled: { RailControl.isSwitchedOn($0, switches: [:]) },
                                  presence: RailControl.Presence(shelfHasFiles: shelfHasFiles))
        }
        let empty = shipped(shelfHasFiles: false)
        let oneFile = shipped(shelfHasFiles: true)
        XCTAssertEqual(empty, [.wifi, .bluetooth, .display, .keepAwake, .mirror, .keyboardLight, .settings])
        XCTAssertEqual(oneFile, [.wifi, .bluetooth, .display, .keepAwake, .mirror, .airDrop, .keyboardLight, .settings])

        // One output and a display with a brightness: the everyday laptop. The keyboard's slider
        // was pushed off this rail by a single file on the shelf, and came back on the Shelf
        // section; its disc stays put either way.
        let room = RailMetrics.room(hasPicker: false, hasBrightness: true)
        XCTAssertEqual(RailControl.fit(empty, room: room).rail, empty)
        let everyday = RailControl.fit(oneFile, room: room)
        XCTAssertEqual(everyday.rail, oneFile, "a file on the shelf pushes nothing off the rail")
        XCTAssertTrue(everyday.spill.isEmpty)
        XCTAssertEqual(RailPlan.plan(oneFile, room: room, showingShelf: true, showingMirror: false).rail, empty,
                       "and on the Shelf section only its own AirDrop stands down")

        // A second output as well: the widest fixed end there is. With the shelf empty it all
        // still fits; with a file on it the last control before Settings waits in the Controls
        // section — on every section, the Shelf's included, rather than coming and going.
        let widest = RailMetrics.room(hasPicker: true, hasBrightness: true)
        XCTAssertEqual(RailControl.fit(empty, room: widest).rail, empty)
        let crowded = RailPlan.plan(oneFile, room: widest, showingShelf: false, showingMirror: false)
        XCTAssertEqual(crowded.spill, [.keyboardLight])
        XCTAssertEqual(crowded.rail.last, .settings)
        let crowdedShelf = RailPlan.plan(oneFile, room: widest, showingShelf: true, showingMirror: false)
        XCTAssertEqual(crowdedShelf.spill, [.keyboardLight])
        XCTAssertEqual(crowdedShelf.rail, crowded.rail.filter { $0 != .airDrop })
    }

    func testTheRailIsTheFrontOfTheListAndTheOverflowItsBack() {
        // Whatever the room, the rail is the start of the user's order and the Controls row the
        // rest of it — never a shuffle of both.
        let order: [RailControl] = [.keyboardLight, .wifi, .bluetooth, .display, .lock, .settings]
        for discs in 0...5 {
            let room = RailMetrics.cost(of: .settings) + CGFloat(discs) * RailMetrics.cost(of: .wifi) + 1
            let fit = RailControl.fit(order, room: room)
            XCTAssertEqual(fit.rail.last, .settings, "room for \(discs)")
            XCTAssertEqual(fit.rail.count - 1, discs, "room for \(discs)")
            XCTAssertEqual(Array(fit.rail.dropLast()) + fit.spill, Array(order.dropLast()), "room for \(discs)")
        }
    }

    func testTheMirrorsOwnButtonStaysWhileTheMirrorIsShowing() {
        // The mirror covers the section, the Controls section's overflow row with it; the way
        // out of the mirror has to be on the rail.
        let room = RailMetrics.cost(of: .settings) + RailMetrics.cost(of: .mirror)
        let fit = RailControl.fit([.wifi, .bluetooth, .mirror, .settings], room: room, pinned: [.settings, .mirror])
        XCTAssertEqual(fit.rail, [.mirror, .settings])
        XCTAssertEqual(fit.spill, [.wifi, .bluetooth])
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
        // Ten of them is what the row holds; their discs still fit the panel's content column,
        // and the last name overhangs into the panel's margin as the first always has, never
        // out of the panel.
        let count: CGFloat = CGFloat(QuickActionsRowView.capacity)
        let used = count * ActionTile.diameter + (count - 1) * ActionTile.gap
        XCTAssertLessThanOrEqual(used, IslandLayout.panelContentWidth)
        XCTAssertLessThanOrEqual(used + overhang - IslandLayout.panelContentWidth, IslandLayout.panelInset)
    }

    /// Six apps and eight favourites were fourteen buttons chosen for a row that drew eight:
    /// two of the favourites appeared and six were dropped, under a pane saying "8 of 8
    /// chosen". The row holds ten, and Settings counts the two lists against it together.
    func testTheActionsRowSharesItsTenButtonsBetweenAppsAndShortcuts() {
        let capacity = QuickActionsRowView.capacity
        XCTAssertEqual(capacity, 10)
        XCTAssertEqual(CGFloat(capacity) * ActionTile.diameter + CGFloat(capacity - 1) * ActionTile.gap, 670,
                       "ten discs and nine gaps, 2 pt inside the 672 pt column")
        XCTAssertEqual(QuickActionsRowView.shortcutRoom(besideApps: FavoriteApps.maximum), 4, "six apps leave four")
        XCTAssertEqual(QuickActionsRowView.shortcutRoom(besideApps: 0), ShortcutsRunner.maxFavorites,
                       "and no apps leave the runner its own eight")
        XCTAssertEqual(QuickActionsRowView.appRoom(besideShortcuts: ShortcutsRunner.maxFavorites), 2)
        XCTAssertEqual(QuickActionsRowView.appRoom(besideShortcuts: 0), FavoriteApps.maximum)
        // Whatever Settings allows, the row draws.
        for apps in 0...FavoriteApps.maximum {
            let shortcuts = QuickActionsRowView.shortcutRoom(besideApps: apps)
            XCTAssertLessThanOrEqual(apps + shortcuts, capacity)
            XCTAssertLessThanOrEqual(apps, QuickActionsRowView.appRoom(besideShortcuts: shortcuts),
                                     "\(apps) apps and a full list of favourites still leave the apps room")
            let fit = QuickActionsRowView.fit(apps: apps, shortcuts: shortcuts)
            XCTAssertEqual(fit.apps, apps)
            XCTAssertEqual(fit.shortcuts, shortcuts, "\(apps) apps: every favourite Settings allows is drawn")
        }
        // A list chosen before the room was shared keeps its apps, and Settings says how many of
        // its favourites the row can show rather than calling it eight of eight.
        let chosenBefore = QuickActionsRowView.fit(apps: 6, shortcuts: 8)
        XCTAssertEqual(chosenBefore.apps, 6)
        XCTAssertEqual(chosenBefore.shortcuts, 4)
        XCTAssertEqual(QuickActionsRowView.tally(favourites: 8, apps: 6), "8 chosen; 4 fit beside your apps")
        XCTAssertEqual(QuickActionsRowView.tally(favourites: 3, apps: 6), "3 of 4 chosen")
        XCTAssertEqual(QuickActionsRowView.tally(favourites: 8, apps: 0), "8 of 8 chosen")
    }

    /// Settings counted the apps it stored and the row the apps it could draw, so one on a disk
    /// that was not plugged in left Settings a Shortcut short of the room the row had. The
    /// Shortcuts' share is counted as the row draws it; what is stored is still held to six.
    func testAnAppOnAnUnpluggedDiskTakesNoRoomInTheRowButStaysKept() {
        // Four apps drawn and one on a disk that is not plugged in, beside four favourites.
        let room = QuickActionsRowView.appRoom(besideShortcuts: 4)
        XCTAssertEqual(room, 6)
        XCTAssertTrue(FavoriteApps.hasRoom(stored: 5, room: room), "the row has room, and so does the list")
        XCTAssertEqual(QuickActionsRowView.shortcutRoom(besideApps: 4), 6, "and the Shortcuts get the room the row leaves them")
        XCTAssertFalse(FavoriteApps.hasRoom(stored: FavoriteApps.maximum, room: room),
                       "six kept is six, however many of them are plugged in")
        XCTAssertFalse(FavoriteApps.hasRoom(stored: 2, room: 2), "and the row's share is the row's")
        XCTAssertTrue(FavoriteApps.hasRoom(stored: 0, room: 10), "an empty list with a full row's room")
    }

    /// With six favourites the row leaves the apps four. Three drawn and one on a disk that
    /// was not plugged in left room, counted as the row drew them, for a fifth; Settings added
    /// it, and when the disk came back the row drew five apps and pushed a favourite out.
    func testAddingAnAppCountsTheOnesOnADiskThatIsNotPluggedIn() {
        let room = QuickActionsRowView.appRoom(besideShortcuts: 6)
        XCTAssertEqual(room, 4)
        XCTAssertFalse(FavoriteApps.hasRoom(stored: 4, room: room),
                       "four kept, three of them drawn: the fourth has its place for when its disk is back")
        XCTAssertTrue(FavoriteApps.hasRoom(stored: 3, room: room))
        let back = QuickActionsRowView.fit(apps: 4, shortcuts: 6)
        XCTAssertEqual(back.shortcuts, 6, "so with every disk back each favourite is still drawn")
    }

    func testTheFavouritesTallySaysWhenAnAppIsAway() {
        XCTAssertEqual(QuickActionsSettingsView.tally(favourites: 3, appsInRow: 4, appsAway: 0), "3 of 6 chosen",
                       "nothing away: the row's own count")
        XCTAssertEqual(QuickActionsSettingsView.tally(favourites: 3, appsInRow: 4, appsAway: 1),
                       "3 of 6 chosen. 1 app is away on a disk that is not plugged in")
        XCTAssertEqual(QuickActionsSettingsView.tally(favourites: 6, appsInRow: 4, appsAway: 1),
                       "6 of 6 chosen. 5 fit once the app on a disk that is not plugged in is back",
                       "a favourite the row would leave out then is said so now")
        XCTAssertEqual(QuickActionsSettingsView.tally(favourites: 6, appsInRow: 3, appsAway: 2),
                       "6 of 7 chosen. 5 fit once the 2 apps on disks that are not plugged in are back")
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

    func testOnlyARefusedLocationIsBlamedForAnEmptyList() {
        // macOS keeps the network names from an app Location has refused, and the column
        // said "Nothing in range" on a Mac sitting on a working network.
        XCTAssertTrue(WiFiScanner.namesWithheld(.denied))
        XCTAssertTrue(WiFiScanner.namesWithheld(.restricted))
        XCTAssertFalse(WiFiScanner.namesWithheld(.notDetermined), "the question is still on screen")
        XCTAssertFalse(WiFiScanner.namesWithheld(.authorizedAlways))
    }

    func testControlsIsASectionWithASwitchOfItsOwn() {
        let prefs = Preferences.shared
        let saved = (prefs.railSwitches, prefs.mirrorEnabled)
        defer {
            prefs.controlsEnabled = true
            (prefs.railSwitches, prefs.mirrorEnabled) = saved
        }
        XCTAssertTrue(HomeSection.controls.isEnabled(prefs))
        HomeSection.controls.setEnabled(false, in: prefs)
        XCTAssertFalse(HomeSection.controls.isEnabled(prefs))
        // Nothing on the rail but Settings, so nothing can be waiting in the section: it goes.
        for control in RailControl.allCases { control.setEnabled(false, in: prefs) }
        XCTAssertFalse(HomeSection.railSpills(prefs))
        XCTAssertFalse(HomeSection.available(prefs).contains(.controls))
        XCTAssertFalse(HomeSection.tiles(prefs).contains(.controls))
        // Every control switched on: the section is there exactly when the rail has overflow
        // for it, whatever this Mac's rail has room for.
        for control in RailControl.allCases { control.setEnabled(true, in: prefs) }
        let spills = HomeSection.railSpills(prefs)
        XCTAssertEqual(HomeSection.available(prefs).contains(.controls), spills)
        XCTAssertEqual(HomeSection.tiles(prefs).contains(.controls), spills)
        XCTAssertEqual(HomeSection.controls.isShown(prefs), spills)
    }

    func testTheControlsSectionStaysWhileTheRailHasOverflowForIt() {
        // The rail's overflow lives only at the top of the Controls section: switching the
        // section off must not take those controls with it, with nothing to say where they went.
        XCTAssertTrue(HomeSection.isShown(.controls, isEnabled: false, railSpills: true))
        XCTAssertFalse(HomeSection.isShown(.controls, isEnabled: false, railSpills: false),
                       "and it goes again once nothing is waiting there")
        XCTAssertTrue(HomeSection.isShown(.controls, isEnabled: true, railSpills: false))
        XCTAssertTrue(HomeSection.isShown(.controls, isEnabled: true, railSpills: true))
        for section in HomeSection.allCases where section != .controls {
            XCTAssertFalse(HomeSection.isShown(section, isEnabled: false, railSpills: true), "\(section) holds no overflow")
            XCTAssertTrue(HomeSection.isShown(section, isEnabled: true, railSpills: false), "\(section)")
        }
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

    // MARK: - The AirPods row, open

    func testAColumnHoldsFourRowsUnderItsHeader() {
        // The budget every list in the section is laid out against: four rows in the body, with
        // the air under the fourth that a fifth would need.
        XCTAssertLessThanOrEqual(4 * ControlsSectionView.rowHeight, SectionMetrics.bodyHeight)
        XCTAssertGreaterThan(5 * ControlsSectionView.rowHeight, SectionMetrics.bodyHeight)
    }

    func testAnOpenAirPodsRowIsExactlyTwoRowsOfTheColumn() {
        // The row, a hairline of air and the pills: two rows' worth, so every row under it lands
        // on the grid it would have been on, and the column still shows the open pair and two
        // more devices without scrolling.
        XCTAssertEqual(ControlsSectionView.expandedRowHeight, 2 * ControlsSectionView.rowHeight)
        XCTAssertLessThanOrEqual(ControlsSectionView.expandedRowHeight + 2 * ControlsSectionView.rowHeight,
                                 SectionMetrics.bodyHeight)
        XCTAssertEqual(ListeningModeMetrics.height, IslandHit.minimum, "the pills are 24 pt targets")
    }

    func testFourPillsAndTheDisconnectFitTheColumnAtTargetSize() {
        let modes = AirPodsControl.Mode.allCases.count
        let pill = ListeningModeMetrics.pillWidth(count: modes, in: ControlsSectionView.modesWidth)
        XCTAssertGreaterThanOrEqual(pill, IslandHit.minimum, "every pill is a target the pointer is owed")
        // Indent, the pills, the gap and the disconnect: the column's width and no more.
        let line = ControlsSectionView.modesIndent + ListeningModeMetrics.rowWidth(count: modes, pill: pill)
            + ControlsSectionView.rowSpacing + IslandHit.minimum
        XCTAssertLessThanOrEqual(line, ControlsSectionView.columnWidth)
        XCTAssertGreaterThan(line, ControlsSectionView.columnWidth - CGFloat(modes),
                             "at most a point lost per pill to rounding")
        XCTAssertEqual(ControlsSectionView.modesIndent, ControlsSectionView.tickWidth + ControlsSectionView.rowSpacing,
                       "the pills start under the name, not the tick")
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

    func testTheRowAndTheCardGoRedAtTheSameLevel() {
        // 10 in the list and 20 on the AirPods card: the same pair at 15% was grey in one and
        // red in the other.
        XCTAssertEqual(BluetoothState.lowBattery, 20)
        XCTAssertTrue(BluetoothState.isLow(15))
        XCTAssertTrue(BluetoothState.isLow(20))
        XCTAssertFalse(BluetoothState.isLow(21))
        XCTAssertNotEqual(ControlsSectionView.batteryTint(15), ControlsSectionView.batteryTint(80),
                          "the list's row is red at 15 as well")
        XCTAssertNotEqual(ControlsSectionView.batteryTint(20), ControlsSectionView.batteryTint(21),
                          "and turns at the card's level, not its own")
    }

    // MARK: - Asking the radios without stopping the panel

    func testASecondPassOverTheRadioWhileOneIsRunningStandsDown() {
        var pass = RadioPass()
        let first = pass.start()
        XCTAssertTrue(first, "the first caller goes")
        let second = pass.start()
        XCTAssertFalse(second, "the second finds one in flight and asks for nothing")
        XCTAssertTrue(pass.isRunning)
        // The one that stood down is remembered, so finishing hands its ask back.
        XCTAssertTrue(pass.finish())
        XCTAssertFalse(pass.isRunning)
        let next = pass.start()
        XCTAssertTrue(next, "once the answer is back the next pass is free to go")
    }

    func testTheAskThatCameWhileTheRadioWasBusyIsNotForgotten() {
        // Standing down is right — two sets of round trips for one answer — but standing down
        // and forgetting is not. The ask that matters most is the one straight after a switch
        // is thrown or a network joined, and dropping it left the tick against the wrong row
        // until the next tick came round, twelve seconds later.
        var pass = RadioPass()
        XCTAssertTrue(pass.start())
        XCTAssertFalse(pass.start(), "the second one still stands down")
        XCTAssertTrue(pass.finish(), "and is handed back when the first is done")
        XCTAssertTrue(pass.start(), "so it can go")
        XCTAssertFalse(pass.finish(), "with nobody waiting behind it")
    }

    func testAQueueOfAsksNeverPilesUpBehindOnePass() {
        // However many arrive while a pass is in the air, they are one ask between them: the
        // answer they are all waiting for is the same reading.
        var pass = RadioPass()
        XCTAssertTrue(pass.start())
        for _ in 0..<5 { XCTAssertFalse(pass.start()) }
        XCTAssertTrue(pass.finish())
        XCTAssertTrue(pass.start())
        XCTAssertFalse(pass.finish(), "five asks made one pass, not five")
    }

    func testAReadThatArrivesAfterYouChangedYourMindIsIgnored() {
        let tapped = Date()
        let asked = SystemToggles.Pending(value: true, until: tapped.addingTimeInterval(SystemToggles.writeSettle))
        XCTAssertFalse(SystemToggles.accepts(false, waitingFor: asked, at: tapped),
                       "a reading that left the radio before the tap does not undo it")
        XCTAssertTrue(SystemToggles.accepts(true, waitingFor: asked, at: tapped),
                      "the system agreeing settles the wait there and then")
        XCTAssertTrue(SystemToggles.accepts(false, waitingFor: nil, at: tapped),
                      "with nothing asked for, whatever comes back is the truth")
    }

    func testASwitchTheSystemNeverThrowsIsBelievedInTheEnd() {
        let tapped = Date()
        let asked = SystemToggles.Pending(value: true, until: tapped.addingTimeInterval(SystemToggles.writeSettle))
        XCTAssertTrue(SystemToggles.accepts(false, waitingFor: asked,
                                            at: tapped.addingTimeInterval(SystemToggles.writeSettle)),
                      "past the settle window the answer is no, and the rail says so")
        XCTAssertTrue(SystemToggles.accepts(false, waitingFor: asked,
                                            at: tapped.addingTimeInterval(SystemToggles.writeSettle + 1)))
    }

    // MARK: - The pollers under a lock

    func testTheNetworkSweepAndThePairedListBackOffWithTheEnergyPolicy() {
        XCTAssertEqual(WiFiScanner.scaledRefreshInterval(multiplier: 1), WiFiScanner.refreshInterval)
        XCTAssertEqual(WiFiScanner.scaledRefreshInterval(multiplier: 8), WiFiScanner.refreshInterval * 8)
        XCTAssertEqual(WiFiScanner.scaledRefreshInterval(multiplier: 0.5), WiFiScanner.refreshInterval,
                       "never faster than the daytime rate")
        XCTAssertEqual(PairedDevices.scaledPollInterval(multiplier: 1), PairedDevices.pollInterval)
        XCTAssertEqual(PairedDevices.scaledPollInterval(multiplier: 4), PairedDevices.pollInterval * 4)
        XCTAssertEqual(PairedDevices.scaledPollInterval(multiplier: 0), PairedDevices.pollInterval)
    }

    /// The paired list was read on the main thread every four seconds with the radio off, or
    /// with no radio at all.
    func testThePairedListIsOnlyReadWithTheRadioOnAndTheTourDone() {
        XCTAssertTrue(PairedDevices.reads(hasSeenWelcome: true, hasBluetooth: true, bluetoothOn: true))
        XCTAssertFalse(PairedDevices.reads(hasSeenWelcome: true, hasBluetooth: true, bluetoothOn: false),
                       "the column says Off then")
        XCTAssertFalse(PairedDevices.reads(hasSeenWelcome: false, hasBluetooth: true, bluetoothOn: true),
                       "nothing Bluetooth before the tour")
        XCTAssertFalse(PairedDevices.reads(hasSeenWelcome: true, hasBluetooth: false, bluetoothOn: true),
                       "a switch left on by a radio that has since gone away is not a radio to ask")
    }

    // MARK: - The network you are on

    /// Clicking the ticked network joined it again, which could drop it or send the user to
    /// Wi-Fi Settings for a password nobody needed.
    func testTheNetworkYouAreOnIsNotJoinedAgain() {
        XCTAssertFalse(WiFiScanner.joins(network("Home", -45, current: true, known: true)))
        XCTAssertTrue(WiFiScanner.joins(network("Café", -70, known: true)))
        XCTAssertTrue(WiFiScanner.joins(network("Guest", -60, secure: false)))
    }

    // MARK: - Bluetooth refused, and a cold radio

    func testBluetoothRefusedIsSaidAsSuchAndNotAsNoRadio() {
        XCTAssertTrue(SystemToggles.bluetoothAccessOff(reading: nil, asked: true, denied: true))
        XCTAssertFalse(SystemToggles.bluetoothAccessOff(reading: true, asked: true, denied: true),
                       "a radio that answers is not refused, whatever CoreBluetooth says")
        XCTAssertFalse(SystemToggles.bluetoothAccessOff(reading: nil, asked: false, denied: true),
                       "before the tour nothing was asked")
        XCTAssertFalse(SystemToggles.bluetoothAccessOff(reading: nil, asked: true, denied: false),
                       "no reading and no refusal is a Mac without Bluetooth")

        XCTAssertTrue(SystemToggles.isRefusal(.denied))
        XCTAssertTrue(SystemToggles.isRefusal(.restricted), "a managed Mac's no is a no too, not a Mac without Bluetooth")
        XCTAssertFalse(SystemToggles.isRefusal(.allowedAlways))
        XCTAssertFalse(SystemToggles.isRefusal(.notDetermined), "not asked yet is not refused")

        XCTAssertNil(ControlsSectionView.bluetoothNote(hasBluetooth: false, isOn: false, accessRefused: true),
                     "refused, the column offers the Privacy pane instead of a note")
        XCTAssertEqual(ControlsSectionView.bluetoothNote(hasBluetooth: false, isOn: false, accessRefused: false),
                       "Not on this Mac")
        XCTAssertEqual(ControlsSectionView.bluetoothNote(hasBluetooth: true, isOn: false, accessRefused: false), "Off")
        XCTAssertNil(ControlsSectionView.bluetoothNote(hasBluetooth: true, isOn: true, accessRefused: false))
    }

    /// A cold radio took longer than the settle window to come on, and the switch went back to
    /// off and then forward again when it did.
    func testABluetoothPowerOnIsHeldLongerThanAnyOtherSwitch() {
        XCTAssertGreaterThan(SystemToggles.settle(for: .bluetooth, wanted: true), SystemToggles.writeSettle)
        XCTAssertEqual(SystemToggles.settle(for: .bluetooth, wanted: false), SystemToggles.writeSettle)
        XCTAssertEqual(SystemToggles.settle(for: .wifi, wanted: true), SystemToggles.writeSettle)
        let tapped = Date()
        let asked = SystemToggles.Pending(value: true,
                                          until: tapped.addingTimeInterval(SystemToggles.settle(for: .bluetooth, wanted: true)))
        XCTAssertFalse(SystemToggles.accepts(false, waitingFor: asked,
                                             at: tapped.addingTimeInterval(SystemToggles.writeSettle + 0.5)),
                       "still coming up past the old window: the switch stays on")
        XCTAssertTrue(SystemToggles.accepts(true, waitingFor: asked, at: tapped.addingTimeInterval(1)),
                      "and the radio saying it is on ends the wait there and then")
    }

    // MARK: - A device's levels, on the card as in the list

    /// An asleep or unasked bud or case leaves 0, or something past full, in the registry; the
    /// list dropped it and the card drew "Case 0%" in red.
    func testTheCardIsBuiltOnlyFromLevelsThatAreACharge() {
        let raw = BluetoothBattery.Levels(left: 0, right: 80, caseLevel: 0, single: 120)
        let kept = BluetoothBattery.usable(raw)
        XCTAssertNil(kept.left)
        XCTAssertEqual(kept.right, 80)
        XCTAssertNil(kept.caseLevel, "no \"Case 0%\"")
        XCTAssertNil(kept.single)
        XCTAssertEqual(BluetoothBattery.usable(BluetoothBattery.Levels(left: 1, right: 100)).left, 1)
        XCTAssertEqual(BluetoothBattery.usable(BluetoothBattery.Levels(left: 1, right: 100)).right, 100)
    }

    /// The pill put a single reading ahead of the buds, so a pair that reported both said one
    /// number on the pill and another on its row.
    func testThePillAndTheRowSummariseADeviceTheSameWay() {
        let both = BluetoothState(name: "", address: "", symbol: "", batteryLeft: 55, batterySingle: 90)
        XCTAssertEqual(both.summaryPercent, 55, "the bud, as the list shows it")
        XCTAssertEqual(both.summaryPercent,
                       BluetoothBattery.summary(BluetoothBattery.Levels(left: 55, single: 90)))
        XCTAssertNil(BluetoothState(name: "", address: "", symbol: "", batteryLeft: 0, batteryRight: 0).summaryPercent,
                     "a 0 left in the registry is not a charge")
        XCTAssertNil(BluetoothState(name: "", address: "", symbol: "", batteryCase: 70).summaryPercent,
                     "nor is the case the thing in your ears")
    }
}
