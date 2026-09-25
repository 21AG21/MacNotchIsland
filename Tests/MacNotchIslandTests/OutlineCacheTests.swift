import AppKit
import SwiftUI
import XCTest
@testable import MacNotchIsland

/// The hit test's memory. Inside the canvas every move of the pointer asks for the island's
/// outline two or three times; the outline is built once for a layout and kept, and the
/// whole of what makes that safe is that nothing is kept past a change of what it was built
/// from.
@MainActor
final class OutlineCacheTests: XCTestCase {
    private let notched = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107), notchWidth: 185,
                                        notchHeight: 33.5, hasPhysicalNotch: true, menuBarHeight: 33.5)
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 340)

    private var idle: IslandLayout { IslandLayout.make(presentation: .idle, geometry: notched) }
    private var panel: IslandLayout {
        IslandLayout.make(presentation: .panel(.home(tab: HomeSection.music.rawValue)), geometry: notched)
    }
    private var withBubble: IslandLayout {
        let a = IslandActivity(id: "a", kind: .timer, content: .custom(CustomActivity(title: "A")), priority: 70)
        let b = IslandActivity(id: "b", kind: .custom, content: .custom(CustomActivity(title: "B")), priority: 60)
        return IslandLayout.make(presentation: .compact(a, bubble: b), geometry: notched)
    }

    private func key(_ layout: IslandLayout, in bounds: CGRect? = nil, bubble: Bool = true) -> OutlineCache.Key {
        OutlineCache.Key(layout: layout, bounds: bounds ?? self.bounds, includingBubble: bubble)
    }

    /// Builds outlines the way the view does, and counts them.
    private final class Builder {
        private(set) var count = 0

        func build(_ key: OutlineCache.Key) -> Path {
            count += 1
            return NotchHostingView<EmptyView>.outline(of: key.layout, in: key.bounds, includingBubble: key.includingBubble)
        }
    }

    /// The outline the view would build for a key, drawn out as text so two can be compared.
    private func fresh(_ key: OutlineCache.Key) -> String {
        NotchHostingView<EmptyView>.outline(of: key.layout, in: key.bounds, includingBubble: key.includingBubble).description
    }

    // MARK: - The rule

    func testOnlyTheSameKeyIsAnswered() {
        let asked = key(idle)
        XCTAssertTrue(OutlineCache.answers(asked, asked))
        XCTAssertTrue(OutlineCache.answers(key(idle), asked), "equal is enough; it need not be the same request")
        XCTAssertFalse(OutlineCache.answers(nil, asked), "nothing built yet answers nothing")
        XCTAssertFalse(OutlineCache.answers(key(panel), asked), "another layout")
        XCTAssertFalse(OutlineCache.answers(key(idle, in: CGRect(x: 0, y: 0, width: 900, height: 340)), asked),
                       "the same layout in other bounds, as after the panel moved to a wider screen")
        XCTAssertFalse(OutlineCache.answers(key(idle, bubble: false), asked), "the other way of asking")
    }

    // MARK: - The memory

    func testAnUnchangedIslandIsBuiltOnce() {
        var cache = OutlineCache()
        let builder = Builder()
        let first = cache.outline(for: key(idle), build: builder.build)
        for _ in 0..<5 { _ = cache.outline(for: key(idle), build: builder.build) }
        XCTAssertEqual(builder.count, 1, "six moves over the same island build its outline once")
        XCTAssertEqual(cache.outline(for: key(idle), build: builder.build).description, first.description)
        XCTAssertEqual(first.description, fresh(key(idle)), "and what is kept is what would have been built")
    }

    func testAChangedLayoutOrBoundsIsBuiltAgain() {
        var cache = OutlineCache()
        let builder = Builder()
        _ = cache.outline(for: key(idle), build: builder.build)
        let opened = cache.outline(for: key(panel), build: builder.build)
        XCTAssertEqual(builder.count, 2, "the island opened under the pointer")
        XCTAssertEqual(opened.description, fresh(key(panel)), "and the outline is the open panel's, not the pill's")
        let wider = CGRect(x: 0, y: 0, width: 900, height: 340)
        let moved = cache.outline(for: key(panel, in: wider), build: builder.build)
        XCTAssertEqual(builder.count, 3, "the same panel in new bounds sits somewhere else")
        XCTAssertEqual(moved.description, fresh(key(panel, in: wider)))
        _ = cache.outline(for: key(idle), build: builder.build)
        XCTAssertEqual(builder.count, 4, "one entry per way of asking: the pill it was before is built again")
    }

    /// Both ways are asked on the same move — the body alone for the hover, with the bubble
    /// for the click — so each keeps its own entry rather than throwing out the other's.
    func testTheTwoWaysOfAskingAreKeptSideBySide() {
        let layout = withBubble
        XCTAssertTrue(layout.hasBubble)
        var cache = OutlineCache()
        let builder = Builder()
        for _ in 0..<3 {
            let body = key(layout, bubble: false)
            let both = key(layout, bubble: true)
            XCTAssertEqual(cache.outline(for: body, build: builder.build).description, fresh(body))
            XCTAssertEqual(cache.outline(for: both, build: builder.build).description, fresh(both))
        }
        XCTAssertEqual(builder.count, 2, "each way built once, however the questions alternate")
        XCTAssertNotEqual(fresh(key(layout, bubble: false)), fresh(key(layout, bubble: true)),
                          "and they are different outlines, so neither may answer for the other")
    }

    // MARK: - The view

    /// The provider is still asked every time, so the view never answers with an outline
    /// older than the island: a new layout is a new outline at once, and a hidden island is
    /// no outline at all, whatever was kept.
    func testTheViewFollowsItsProviderPastWhatItKept() {
        let view = NotchHostingView(rootView: EmptyView())
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 340)
        var shown: IslandLayout? = idle
        view.islandLayoutProvider = { shown }
        XCTAssertEqual(view.islandPath()?.description, fresh(key(idle, in: view.bounds)))
        XCTAssertEqual(view.islandPath()?.description, fresh(key(idle, in: view.bounds)))
        shown = panel
        XCTAssertEqual(view.islandPath()?.description, fresh(key(panel, in: view.bounds)))
        shown = nil
        XCTAssertNil(view.islandPath())
    }
}
