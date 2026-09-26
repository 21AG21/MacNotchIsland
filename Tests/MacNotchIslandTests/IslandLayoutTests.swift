import AppKit
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
        // A 720 pt panel, a 200 pt cutout with 10 pt kept clear either side of it, and 16 pt
        // of inset: (720 − 220) / 2 − 16 = 234 pt for the sections to lie in.
        let room = bandSide(notch: 200)
        XCTAssertEqual(room, 234, "the room a 14-inch panel actually has beside its cutout")
        let all = bandSlots(HomeSection.allCases.count)
        let fitted = SwitcherBand.fit(all, in: room)
        XCTAssertEqual(fitted.slot, SwitcherBand.minSlot, "the circle stops at the floor")
        XCTAssertEqual(fitted.gap, SwitcherBand.minGap, "and the spacing was given up first")
        XCTAssertLessThan(fitted.views.count, all.count)
        // At the floor a 26 pt circle and the 2 pt beside it are one 28 pt target, and the
        // targets meet edge to edge, so a row of n is 28n: 8 × 28 = 224 goes into 234 and
        // 9 × 28 = 252 does not. Eight, worked out here by hand — not read back off the
        // rounding being tested, which would follow that rounding wherever it went.
        XCTAssertEqual(fitted.views.count, 8, "as many as the room holds, and not one fewer")
        // One slot more than the room can hold, and a good many more: the slot goes and the
        // size stays, never the other way about.
        for crowd in [9, 12] {
            let crowded = SwitcherBand.fit(bandSlots(crowd), in: room)
            XCTAssertEqual(crowded.views.count, 8, "\(crowd) sections")
            XCTAssertEqual(crowded.slot, SwitcherBand.minSlot, "\(crowd) sections")
        }
        // And at every count on the way there it keeps everything the room can hold.
        for count in 1...all.count {
            XCTAssertEqual(SwitcherBand.fit(bandSlots(count), in: room).views.count,
                           min(count, 8), "\(count) sections")
        }
    }

    /// What a row of slots really measures, summed the way the stack lays it out: a rectangle
    /// for every slot, and what is left of the gap between each pair of them. Built from the
    /// two the row is actually made of rather than from the arithmetic that decides how many
    /// there are — the point being that the two can disagree, and did.
    private func bandRowWidth(_ count: Int, slot: CGFloat, gap: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let hit = SwitcherBand.hit(slot: slot, gap: gap)
        let air = SwitcherBand.spacing(slot: slot, gap: gap)
        return (0..<count).reduce(CGFloat(0)) { total, index in
            total + hit.width + (index == 0 ? 0 : air)
        }
    }

    /// The row is measured in circles and laid out in targets, and a target is wider than the
    /// circle inside it. Counting the room in the one and spending it in the other put the last
    /// slot of a full row up to two points past the edge of the frame it sits in — never at the
    /// width the panel ships at, which is why nobody saw it, and waiting for the first narrower
    /// panel or wider cutout that came along. Whatever the row is measured against, it is what
    /// the row then draws.
    func testTheRowNeverDrawsPastTheRoomItWasMeasuredFor() {
        var rooms: [CGFloat] = ([160, 180, 185, 200, 220] as [CGFloat]).map { bandSide(notch: $0) }
        rooms.append(IslandLayout.panelWidth - SwitcherBand.inset * 2 - SwitcherBand.closeRoom
                     - SwitcherBand.groupGap)
        // And every width in between, a point at a time. The fault only shows where the room
        // runs out a point or two short of a whole target, which is a panel nobody happened to
        // have built yet.
        rooms.append(contentsOf: stride(from: CGFloat(20), through: 320, by: 1))
        for room in rooms {
            for count in 1...(HomeSection.allCases.count + 4) {
                let note = "\(count) slots in \(room) pt"
                let fitted = SwitcherBand.fit(bandSlots(count), in: room)
                XCTAssertLessThanOrEqual(bandRowWidth(fitted.views.count, slot: fitted.slot, gap: fitted.gap),
                                         room, note)
                // Nor one slot fewer than the room would take: a budget that has drifted the
                // other way drops a section that had a place, which is just as wrong.
                if fitted.views.count < count {
                    XCTAssertGreaterThan(bandRowWidth(fitted.views.count + 1, slot: fitted.slot, gap: fitted.gap),
                                         room, note)
                }
                // The activity slots take the size the sections settled on, and count
                // themselves into what is left over. Same arithmetic, same promise.
                let sized = SwitcherBand.fit(bandSlots(count), in: room, slot: fitted.slot, gap: fitted.gap)
                XCTAssertLessThanOrEqual(bandRowWidth(sized.views.count, slot: sized.slot, gap: sized.gap),
                                         room, note)
                if sized.views.count < count {
                    XCTAssertGreaterThan(bandRowWidth(sized.views.count + 1, slot: sized.slot, gap: sized.gap),
                                         room, note)
                }
            }
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

    // MARK: - The privacy dots in the pill

    /// The compact pill ends in a semicircle as tall as it is, and the dots were given 18 pt
    /// flush against it: the second dot was cut by the curve and had the rim drawn through it.
    /// The slot keeps 10 pt between the dots and that end now, and the content keeps its own.
    func testCompactKeepsThePrivacyDotsOffThePillsRoundedEnd() {
        let timer = TimerState(label: "Timer", total: 60, endDate: Date().addingTimeInterval(60))
        let a = activity("t", .timer(timer))
        let plain = IslandLayout.make(presentation: .compact(a, bubble: nil), geometry: geometry, clearance: .unlimited)
        ActivityCenter.shared.micInUse = true
        defer { ActivityCenter.shared.micInUse = false }
        let dotted = IslandLayout.make(presentation: .compact(a, bubble: nil), geometry: geometry, clearance: .unlimited)
        XCTAssertEqual(dotted.privacyWidth, IslandLayout.privacyDots + IslandLayout.compactPrivacyClearance)
        XCTAssertEqual(dotted.privacyWidth, 28)
        XCTAssertEqual(dotted.trailingWidth, plain.trailingWidth + 28, "the timer's digits keep their whole slot")
        // The resting island is unchanged: its dots already sat 4 pt in from either side.
        let idle = IslandLayout.make(presentation: .idle, geometry: geometry, clearance: .unlimited)
        XCTAssertEqual(idle.privacyWidth, IslandLayout.privacyDots)
    }

    // MARK: - A side with no room

    /// A menu bar that leaves less than the full width takes a side down to what still reads,
    /// and a side with no minimal form — a word, a percentage — down to nothing. The pill drew
    /// "Connected" into that 0 pt slot anyway, and a fragment of it showed at the pill's end.
    func testASideTheMenuBarLeftNoRoomOnIsNotDrawn() {
        let mouse = activity("bt", .bluetooth(BluetoothState(name: "Magic Mouse", address: "b", symbol: "magicmouse")))
        XCTAssertEqual(mouse.content.compactMinimalWidths.trailing, 0, "\"Connected\" has no shorter form")
        let tight = MenuBarClearance.Limits(leading: 20, trailing: 40)
        let squeezed = IslandLayout.make(presentation: .compact(mouse, bubble: nil), geometry: geometry, clearance: tight)
        XCTAssertEqual(squeezed.trailingWidth - squeezed.privacyWidth, 0)
        XCTAssertFalse(CompactContentView.drawsSlot(width: squeezed.trailingWidth - squeezed.privacyWidth))
        XCTAssertEqual(squeezed.leadingWidth, 0, "20 pt is short of even the glyph's minimal slot")
        XCTAssertFalse(CompactContentView.drawsSlot(width: squeezed.leadingWidth))

        let roomy = IslandLayout.make(presentation: .compact(mouse, bubble: nil), geometry: geometry, clearance: .unlimited)
        XCTAssertTrue(CompactContentView.drawsSlot(width: roomy.trailingWidth - roomy.privacyWidth))
        XCTAssertTrue(CompactContentView.drawsSlot(width: roomy.leadingWidth))
    }

    // MARK: - A card is as tall as what is in it

    /// Every card keeps 12 pt over its row and 16 under it, so its height is those and the
    /// row, summed from what the card stacks. A card given more is black under its content —
    /// every card with a bar was 3 pt too tall, a script's card with a body 33 — and a card
    /// given less cuts it off.
    func testEachCardIsAsTallAsWhatItStacks() {
        let above: CGFloat = 12, below: CGFloat = 16
        XCTAssertEqual(ActivityContent.cardRow, above + 44 + below, "a 44 pt disc beside two lines")
        XCTAssertEqual(ActivityContent.cardRowWithBar, above + 44 + 8 + 4 + below, "and a 4 pt bar 8 under it")
        XCTAssertEqual(ActivityContent.cardDigitsRow, above + 59 + below, "40 pt digits under their eyebrow")

        let download = ActivityContent.download(DownloadState(name: "a.zip", bytes: 10, total: 100, app: "Safari"))
        XCTAssertEqual(download.cardHeight, 84)
        XCTAssertEqual(ActivityContent.stopwatch(StopwatchState(startedAt: Date())).cardHeight, 87)
        let calendar = ActivityContent.calendar(CalendarState(title: "Standup", start: Date(), end: Date(),
                                                              location: nil, joinURL: nil, tint: "blue"))
        XCTAssertEqual(calendar.cardHeight, 81, "a title, its times and a countdown: 53 pt of row")
        XCTAssertEqual(ActivityContent.custom(CustomActivity(title: "A", progress: 0.5)).cardHeight, 84)
        XCTAssertEqual(ActivityContent.custom(CustomActivity(title: "A", progress: 0.5, showsRing: true)).cardHeight, 72,
                       "a ring stands in the leading slot, so there is no bar under the row")
        XCTAssertEqual(ActivityContent.custom(CustomActivity(title: "A", body: "b", url: nil)).cardHeight, 96,
                       "a title, a subtitle and two lines of body: 67 pt of row")
        XCTAssertEqual(ActivityContent.custom(CustomActivity(title: "A", progress: 0.5, body: "b", url: nil)).cardHeight,
                       96 + ActivityContent.cardBar)
    }

    // MARK: - A script's own words

    /// The pill's trailing slot is measured for a script's words, not counted for them. Eight
    /// points a character is a guess about Latin letters: five Japanese characters, each as
    /// wide as the type is tall, came out clipped, and "iii" was given the room of "WWW".
    func testACustomActivitysTrailingWordsAreMeasuredNotCounted() {
        func trailing(_ text: String) -> CGFloat {
            ActivityContent.custom(CustomActivity(title: "A", trailingText: text)).compactWidths.trailing
        }
        let japanese = "会議中です"
        XCTAssertGreaterThan(trailing(japanese), 5 * 8 + 20, "wider than a count of Latin letters allowed")
        let font = NSFont.systemFont(ofSize: CompactTrailingView.wordSize, weight: .semibold)
        let words = (japanese as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(trailing(japanese), min(120, words + 20), "the words and the slot's own air")
        XCTAssertLessThan(trailing("iii"), trailing("WWWWW"))
        XCTAssertEqual(trailing(""), 44, "never narrower than a glyph's slot")
        XCTAssertEqual(trailing(String(repeating: "W", count: 40)), 120, "nor wider than the menu bar can spare")
    }

    // MARK: - Sections the right of the band cannot hold

    /// Ten sections are switched on out of the box, and beside a 14-inch cutout the right of
    /// the band holds eight of them at the size the pointer needs. The two left over, Notes and
    /// Stats, had no slot at all while the whole left of the band stood empty: 241.5 pt, less
    /// 42 for the close button, is 199.5, seven slots of 28. They go there now, after anything
    /// live and in their order on the ring.
    func testSectionsTheRightCannotHoldSpillToTheLeft() {
        let side = bandSide(notch: 185)
        XCTAssertEqual(side, 241.5, "(720 − 205) / 2 − 16")
        let sections = bandSlots(10)
        let row = SwitcherBand.straddle(cards: [], sections: sections, side: side)
        XCTAssertEqual(row.right, Array(sections.prefix(8)), "8 × 28 = 224 goes into 241.5, 9 × 28 does not")
        XCTAssertEqual(row.left, Array(sections.suffix(2)), "the two left over, in ring order")
        XCTAssertEqual(row.slot, SwitcherBand.minSlot, "one size of circle on both sides")

        // Something live comes first, and a section spilled across never pushes it off.
        let cards = (0..<7).map { IslandView.activity(id: "card\($0)") }
        let one = SwitcherBand.straddle(cards: Array(cards.prefix(1)), sections: sections, side: side)
        XCTAssertEqual(one.left, [cards[0]] + Array(sections.suffix(2)))
        let busy = SwitcherBand.straddle(cards: cards, sections: sections, side: side)
        XCTAssertEqual(busy.left, cards, "seven live activities fill the left, and the spill waits")
        XCTAssertEqual(busy.right, Array(sections.prefix(8)))

        // With room for every section on the right, nothing crosses over.
        let few = SwitcherBand.straddle(cards: [], sections: bandSlots(5), side: side)
        XCTAssertTrue(few.left.isEmpty)
        XCTAssertEqual(few.right, bandSlots(5))
    }
}
