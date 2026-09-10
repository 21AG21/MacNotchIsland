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

    /// Both sides of the cutout say something.
    ///
    /// The compact island is two slots with a camera between them, and an activity that fills
    /// only one of them comes out of the notch as a single mark at one end of a long black
    /// bar with a void after it. Unlocking the Mac looked exactly like that: a lock, and
    /// nothing. The two states that have no expanded view are the ones that get missed, so
    /// they are named here rather than left out.
    func testEveryCompactStateSaysSomethingOnBothSidesOfTheCutout() {
        var contents: [ActivityContent] = [
            .unlock,
            .silent(SilentState(isSilent: true)),
            .shelf(ShelfState(count: 2, latestName: "a.png", latestIsImage: true)),
        ]
        contents += [
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
            XCTAssertGreaterThan(content.compactWidths.leading, 0, "\(content) has nothing to say before the cutout")
            XCTAssertGreaterThan(content.compactWidths.trailing, 0, "\(content) has nothing to say after the cutout")
        }
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
        // The volume HUD's trailing slot is far wider than its glyph; without the shift its
        // bar would sit well inside the cutout.
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

    // MARK: - Room for the shadow

    /// The window is drawn to the island's own footprint plus a margin. The shadow falls
    /// outside the shape, so the margin has to hold it: a blur that runs into the window's
    /// edge is cut off square there, which is a hard grey line where the softest part of the
    /// shadow should be.
    func testTheWindowKeepsRoomForTheShadowItCasts() {
        XCTAssertGreaterThan(NotchPanel.restSlack, IslandShadow.reach,
                             "the shadow must have somewhere to fall inside the window")
        XCTAssertEqual(IslandShadow.reach, IslandShadow.ambientRadius + IslandShadow.ambientOffset)
        // The window is sized for the largest shadow, so every smaller one fits inside it too.
        for height: CGFloat in [22, 33.5, 60, 120, 250] {
            let ambient = IslandShadow.ambient(height: height)
            XCTAssertLessThanOrEqual(ambient.radius + ambient.offset, IslandShadow.reach)
        }
    }

    /// A shadow grows with what casts it: the compact pill is a couple of centimetres of black
    /// lying on the menu bar and a window's shadow around it would be most of what you saw.
    func testTheShadowGrowsWithTheSurface() {
        let pill = IslandShadow.ambient(height: 33.5)
        let panel = IslandShadow.ambient(height: IslandLayout.panelContentHeight)
        XCTAssertLessThan(pill.radius, panel.radius)
        XCTAssertLessThan(pill.offset, panel.offset)
        XCTAssertLessThan(pill.opacity, panel.opacity)
        XCTAssertEqual(panel.radius, IslandShadow.ambientRadius, accuracy: 0.001, "a panel casts the full one")
        XCTAssertEqual(IslandShadow.ambient(height: 0).radius, IslandShadow.smallestRadius, accuracy: 0.001)
    }

    /// And it grows *with* it, rather than arriving at full size and waiting.
    ///
    /// `shadow(radius:y:)` takes plain numbers and plain numbers do not interpolate, so handed
    /// the panel's final height on frame one the halo bloomed under a notch that was still a
    /// notch. Being `Animatable` is what puts the height on the spring; this pins that the
    /// height and the strength both survive the round trip through `animatableData`, because
    /// a modifier that quietly loses half of it fails silently and looks almost right.
    func testTheShadowIsCarriedByTheSpringRatherThanSwitchedOn() {
        var modifier = IslandShadowModifier(strength: 1, height: IslandLayout.panelContentHeight)
        XCTAssertEqual(modifier.animatableData.first, 1, accuracy: 0.001)
        XCTAssertEqual(modifier.animatableData.second, IslandLayout.panelContentHeight, accuracy: 0.001)

        // Mid-flight: a third of the way in, on a shape a third of the way out of the notch.
        modifier.animatableData = AnimatablePair(0.33, 90)
        XCTAssertEqual(modifier.strength, 0.33, accuracy: 0.001)
        XCTAssertEqual(modifier.height, 90, accuracy: 0.001)
        let midway = IslandShadow.ambient(height: modifier.height)
        XCTAssertLessThan(midway.radius, IslandShadow.ambientRadius, "not the full halo yet")
        XCTAssertGreaterThan(midway.radius, IslandShadow.smallestRadius, "and no longer the pill's")
    }

    /// Growing the margin must not grow what takes the clicks: everything outside the island's
    /// own footprint falls through to the menu bar and the windows under it.
    func testTheMarginIsNotPartOfWhatTheIslandCatches() {
        let layout = IslandLayout.make(presentation: .idle, geometry: geometry, clearance: .unlimited)
        XCTAssertEqual(layout.hitLeading, layout.frameWidth / 2 - layout.bodyShift + 4)
        XCTAssertLessThan(layout.hitLeading, layout.frameWidth / 2 + NotchPanel.restSlack)
        XCTAssertEqual(layout.hitHeight, layout.bodyHeight + layout.topInset + 6)
    }

    // MARK: - What the switcher band asks the pointer to hit

    /// As many slots as asked for; the fitting does not care what is in them.
    private func bandSlots(_ count: Int) -> [IslandView] {
        (0..<count).map { IslandView.home(tab: "slot\($0)") }
    }

    /// The room the sections are actually left with beside a cutout of a given width.
    private func bandSide(notch: CGFloat) -> CGFloat {
        (IslandLayout.panelWidth - (notch + SwitcherBand.cutoutMargin * 2)) / 2 - SwitcherBand.inset
    }

    /// The band is the least forgiving strip on the screen: it lies in the menu bar, the hand
    /// arrives at it from somewhere else at speed, and the top of the screen is right there to
    /// overshoot into. Every one of these numbers is a size somebody has to land on with a
    /// pointer that is already moving, so none of them may fall under the floor, whatever mix
    /// of sections and live activities the row is asked to hold.
    func testNoSlotIsEverSmallerThanThePointerNeedsItToBe() {
        let notches: [CGFloat] = [160, 180, 185, 200, 220]
        var rooms: [CGFloat] = notches.map { bandSide(notch: $0) }
        // And the screen with no cutout, where the whole row runs from the leading edge.
        rooms.append(IslandLayout.panelWidth - SwitcherBand.inset * 2 - SwitcherBand.closeRoom
                     - SwitcherBand.groupGap)
        for room in rooms {
            for count in 1...(HomeSection.allCases.count + 4) {
                let fitted = SwitcherBand.fit(bandSlots(count), in: room)
                let note = "\(count) slots in \(room) pt"
                let hit = SwitcherBand.hit(slot: fitted.slot, gap: fitted.gap)
                XCTAssertFalse(fitted.views.isEmpty, note)
                XCTAssertGreaterThanOrEqual(hit.width, SwitcherBand.minHit, note)
                XCTAssertGreaterThanOrEqual(hit.height, SwitcherBand.minHit, note)
                XCTAssertLessThanOrEqual(hit.width, fitted.slot + fitted.gap,
                                         "two targets lying over each other: \(note)")
                let drawn = CGFloat(fitted.views.count) * fitted.slot
                    + CGFloat(fitted.views.count - 1) * fitted.gap
                XCTAssertLessThanOrEqual(drawn, room, note)
                // The targets are wider than the circles and the row is no wider for it: what
                // they claim is the air the slots were keeping beside themselves anyway.
                let targets = CGFloat(fitted.views.count) * hit.width
                    + CGFloat(fitted.views.count - 1) * SwitcherBand.spacing(slot: fitted.slot, gap: fitted.gap)
                XCTAssertLessThanOrEqual(targets, room + fitted.gap, note)
            }
        }
    }

    /// Every section switched on at once is more than the panel has room for beside a 14-inch
    /// cutout at a size anybody can hit, so something has to give — and what gives is the slot
    /// at the end of the row, not the aim. A section without a slot is still one step along
    /// the ring; a row of slots nobody can land on cannot be reached at all.
    func testTheBandDropsASlotRatherThanShrinkPastThatFloor() {
        let room = bandSide(notch: 200)
        let all = bandSlots(HomeSection.allCases.count)
        let fitted = SwitcherBand.fit(all, in: room)
        XCTAssertEqual(fitted.slot, SwitcherBand.minSlot, "the circle stops at the floor")
        XCTAssertEqual(fitted.gap, SwitcherBand.minGap, "and the spacing was given up first")
        XCTAssertLessThan(fitted.views.count, all.count)
        // Dropping as few as it can get away with: one more slot and the row would be a
        // target short.
        let kept = CGFloat(fitted.views.count)
        XCTAssertLessThanOrEqual(kept * SwitcherBand.minHit - SwitcherBand.minGap, room)
        XCTAssertGreaterThan((kept + 1) * SwitcherBand.minHit - SwitcherBand.minGap, room)
        // One slot more than the room can hold, whatever that number turns out to be: the
        // slot goes and the size stays, never the other way about.
        let most = Int((room + SwitcherBand.minGap) / SwitcherBand.minHit)
        let crowded = SwitcherBand.fit(bandSlots(most + 1), in: room)
        XCTAssertEqual(crowded.views.count, most)
        XCTAssertEqual(crowded.slot, SwitcherBand.minSlot)
        // And at every count on the way there it keeps everything the room can hold.
        for count in 1...all.count {
            XCTAssertEqual(SwitcherBand.fit(bandSlots(count), in: room).views.count,
                           min(count, most), "\(count) sections")
        }
    }

    /// The circle a slot is drawn as and the rectangle it takes its click in are two different
    /// sizes on purpose: a band wide enough to draw a full row of 28 pt circles would cost the
    /// panel room it has not got, while letting each slot take its click in the air it was
    /// already keeping beside itself costs nothing at all.
    func testTheTargetIsBiggerThanTheCircleAndTheRowIsNoWiderForIt() {
        XCTAssertEqual(SwitcherBand.minSlot + SwitcherBand.minGap, SwitcherBand.minHit,
                       "the floor on the circle is the floor on the target, less the air beside it")
        let tight = SwitcherBand.hit(slot: SwitcherBand.minSlot, gap: SwitcherBand.minGap)
        XCTAssertEqual(tight.width, SwitcherBand.minHit)
        XCTAssertGreaterThan(tight.width, SwitcherBand.minSlot,
                             "the click lands in the air beside the circle as well as on it")
        XCTAssertEqual(SwitcherBand.spacing(slot: SwitcherBand.minSlot, gap: SwitcherBand.minGap), 0,
                       "at the floor the targets meet edge to edge, with nothing dead between them")
        // Whatever the size, the step from one circle to the next is the circle and its gap:
        // the rectangle takes its half out of the stack's spacing, not out of the band.
        let sizes: [(CGFloat, CGFloat)] = [(SwitcherBand.slot, SwitcherBand.gap),
                                           (SwitcherBand.minSlot, SwitcherBand.minGap),
                                           (40, 4)]
        for (slot, gap) in sizes {
            let hit = SwitcherBand.hit(slot: slot, gap: gap)
            XCTAssertEqual(hit.width + SwitcherBand.spacing(slot: slot, gap: gap), slot + gap,
                           accuracy: 0.001, "a slot of \(slot)")
            XCTAssertEqual(hit.height, max(slot, SwitcherBand.minHit), "a slot of \(slot)")
        }
        XCTAssertGreaterThanOrEqual(SwitcherBand.closeRoom,
                                    SwitcherBand.hit(slot: SwitcherBand.slot,
                                                     gap: SwitcherBand.gap).width + SwitcherBand.groupGap,
                                    "the close button's reservation covers what it takes clicks in")
    }
}
