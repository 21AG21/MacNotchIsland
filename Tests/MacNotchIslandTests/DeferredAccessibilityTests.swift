import XCTest
@testable import MacNotchIsland

/// What the island says out loud about the lists and rows that only drew it: the find's count and
/// its mark, a clipboard row's pin and missing file, and a network's lock and signal.
final class DeferredAccessibilityTests: XCTestCase {

    // MARK: - The find

    func testTheFindsCountIsSaidInWords() {
        XCTAssertEqual(FindField.matchCount(0), "No matches")
        XCTAssertEqual(FindField.matchCount(1), "1 match")
        XCTAssertEqual(FindField.matchCount(12), "12 matches")
    }

    func testTheCountIsSaidOnlyForSomethingTyped() {
        XCTAssertEqual(FindField.countAnnouncement(matches: 3, query: "saf"), "3 matches")
        XCTAssertNil(FindField.countAnnouncement(matches: 3, query: ""), "an empty field counts nothing")
        XCTAssertNil(FindField.countAnnouncement(matches: 3, query: nil), "no find at all")
        XCTAssertNil(FindField.countAnnouncement(matches: nil, query: "saf"), "a section with no count to give")
    }

    func testTheMarkSaysWhereItIs() {
        XCTAssertEqual(FindField.moveAnnouncement(row: "Report.pdf", index: 1, count: 5), "Report.pdf, 2 of 5")
        XCTAssertEqual(FindField.moveAnnouncement(row: nil, index: 0, count: 3), "1 of 3",
                       "a section that gives no name still says where the mark is")
        XCTAssertEqual(FindField.moveAnnouncement(row: "", index: 2, count: 3), "3 of 3")
    }

    // MARK: - Clipboard rows

    func testAClipboardRowSaysItIsPinnedAndThatItsFileHasGone() {
        XCTAssertEqual(ClipboardView.spokenRow(kind: "text", preview: "hello", age: "4 minutes ago",
                                               pinned: false, missing: false),
                       "Copied text: hello, 4 minutes ago", "exactly as it was, with neither")
        XCTAssertEqual(ClipboardView.spokenRow(kind: "file", preview: "Report.pdf", age: "just now",
                                               pinned: true, missing: true),
                       "Copied file: Report.pdf, just now, pinned, no longer on disk")
    }

    // MARK: - The networks

    func testANetworksSignalIsSaidInWords() {
        XCTAssertEqual(WiFiBars.spoken(4), "strong signal")
        XCTAssertEqual(WiFiBars.spoken(3), "strong signal")
        XCTAssertEqual(WiFiBars.spoken(2), "fair signal")
        XCTAssertEqual(WiFiBars.spoken(1), "weak signal")
        XCTAssertEqual(WiFiBars.spoken(WiFiScanner.bars(forRSSI: -40)), "strong signal")
        XCTAssertEqual(WiFiBars.spoken(WiFiScanner.bars(forRSSI: -90)), "weak signal")
    }

    func testARowSaysWhereTheLockIsAndWhatItsDetailIs() {
        XCTAssertEqual(ControlsSectionView.rowLabel(title: "Café", isOn: false, lock: true, detail: "fair signal"),
                       "Café, secured, fair signal")
        XCTAssertEqual(ControlsSectionView.rowLabel(title: "Home", isOn: true, lock: false, detail: "strong signal"),
                       "Home, on, strong signal")
        XCTAssertEqual(ControlsSectionView.rowLabel(title: "AirPods", isOn: true, lock: false, detail: "80 percent"),
                       "AirPods, on, 80 percent", "a device row reads as it always did")
        XCTAssertEqual(ControlsSectionView.rowLabel(title: "Speakers", isOn: false, lock: false, detail: nil), "Speakers")
    }
}
