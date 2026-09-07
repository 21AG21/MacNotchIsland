import AppKit
import XCTest
@testable import MacNotchIsland

/// The clipboard rules are pure functions so they can be exercised without a pasteboard.
final class ClipboardStoreTests: XCTestCase {

    private func item(_ text: String,
                      kind: ClipboardItem.Kind = .text,
                      pinned: Bool = false,
                      at seconds: TimeInterval = 0) -> ClipboardItem {
        ClipboardItem(kind: kind, text: text, date: Date(timeIntervalSinceReferenceDate: seconds), pinned: pinned)
    }

    // MARK: - De-duplication

    func testConsecutiveDuplicateIsCollapsed() {
        var items = ClipboardStore.inserting(item("hello", at: 0), into: [], limit: 10)
        items = ClipboardStore.inserting(item("hello", at: 30), into: items, limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].date, Date(timeIntervalSinceReferenceDate: 30))
    }

    func testOnlyConsecutiveDuplicatesCollapse() {
        var items = ClipboardStore.inserting(item("a", at: 0), into: [], limit: 10)
        items = ClipboardStore.inserting(item("b", at: 1), into: items, limit: 10)
        items = ClipboardStore.inserting(item("a", at: 2), into: items, limit: 10)
        XCTAssertEqual(items.map { $0.text }, ["a", "b", "a"])
    }

    func testSameTextOfADifferentKindIsKept() {
        var items = ClipboardStore.inserting(item("https://example.com", kind: .text, at: 0), into: [], limit: 10)
        items = ClipboardStore.inserting(item("https://example.com", kind: .url, at: 1), into: items, limit: 10)
        XCTAssertEqual(items.count, 2)
    }

    func testCollapsingADuplicateKeepsThePin() {
        let stored = item("token", pinned: true, at: 0)
        let items = ClipboardStore.inserting(item("token", at: 5), into: [stored], limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].pinned)
        XCTAssertEqual(items[0].id, stored.id)
    }

    // MARK: - Limit trimming

    func testLimitDropsTheOldestItems() {
        var items: [ClipboardItem] = []
        for i in 0..<5 {
            items = ClipboardStore.inserting(item("t\(i)", at: TimeInterval(i)), into: items, limit: 3)
        }
        XCTAssertEqual(items.map { $0.text }, ["t4", "t3", "t2"])
    }

    func testPinnedItemsSurviveTrimming() {
        var items = [item("keep", pinned: true, at: 0)]
        for i in 1...5 {
            items = ClipboardStore.inserting(item("t\(i)", at: TimeInterval(i)), into: items, limit: 3)
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map { $0.text }, ["t5", "t4", "keep"])
    }

    func testPinnedItemsAreKeptEvenPastTheLimit() {
        let pinned = [item("p1", pinned: true, at: 0),
                      item("p2", pinned: true, at: 1),
                      item("p3", pinned: true, at: 2)]
        let items = ClipboardStore.inserting(item("new", at: 3), into: pinned, limit: 2)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first?.text, "new")
        XCTAssertEqual(items.filter { $0.pinned }.count, 3)
    }

    func testNewestItemIsAlwaysKept() {
        let items = ClipboardStore.inserting(item("only", at: 1), into: [item("old", at: 0)], limit: 0)
        XCTAssertEqual(items.map { $0.text }, ["only"])
    }

    // MARK: - Concealed and transient copies

    func testConcealedCopiesAreSkipped() {
        let snapshot = ClipboardSnapshot(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
                                         text: "hunter2")
        XCTAssertNil(ClipboardStore.item(from: snapshot))
    }

    func testTransientCopiesAreSkipped() {
        let snapshot = ClipboardSnapshot(types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"],
                                         text: "one-time code")
        XCTAssertNil(ClipboardStore.item(from: snapshot))
    }

    func testOrdinaryTypesAreNotConcealed() {
        XCTAssertFalse(ClipboardStore.isConcealed(types: ["public.utf8-plain-text", "public.url"]))
        XCTAssertTrue(ClipboardStore.isConcealed(types: ["org.nspasteboard.ConcealedType"]))
    }

    // MARK: - Capture rules

    func testPlainTextIsCaptured() {
        let captured = ClipboardStore.item(from: ClipboardSnapshot(types: ["public.utf8-plain-text"], text: "  hello  "))
        XCTAssertEqual(captured?.kind, .text)
        XCTAssertEqual(captured?.text, "  hello  ")
        XCTAssertEqual(captured?.preview, "hello")
    }

    func testMultiLineTextPreviewsItsFirstLine() {
        let captured = ClipboardStore.item(from: ClipboardSnapshot(types: ["public.utf8-plain-text"],
                                                                   text: "first line\nsecond line"))
        XCTAssertEqual(captured?.preview, "first line")
    }

    func testLinksAreCapturedAsURLs() {
        let captured = ClipboardStore.item(from: ClipboardSnapshot(types: ["public.url", "public.utf8-plain-text"],
                                                                   text: "https://example.com/a"))
        XCTAssertEqual(captured?.kind, .url)
        XCTAssertEqual(captured?.text, "https://example.com/a")
    }

    func testSentencesAreNotURLs() {
        XCTAssertFalse(ClipboardStore.isURL("see https://example.com for more"))
        XCTAssertFalse(ClipboardStore.isURL("hello"))
        XCTAssertTrue(ClipboardStore.isURL("https://example.com"))
    }

    func testFilesWinOverTheirTextRepresentation() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let snapshot = ClipboardSnapshot(types: ["public.file-url", "public.utf8-plain-text"],
                                         text: "/tmp/report.pdf",
                                         fileURLs: [url])
        let captured = ClipboardStore.item(from: snapshot)
        XCTAssertEqual(captured?.kind, .file)
        XCTAssertEqual(captured?.fileURLs, [url])
        XCTAssertEqual(captured?.preview, "report.pdf")
    }

    func testImagesAreCapturedWhenThereIsNoText() {
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let snapshot = ClipboardSnapshot(types: ["public.png"],
                                         imageData: data,
                                         imagePixelSize: CGSize(width: 100, height: 50))
        let captured = ClipboardStore.item(from: snapshot)
        XCTAssertEqual(captured?.kind, .image)
        XCTAssertEqual(captured?.imageData, data)
        XCTAssertEqual(captured?.preview, "Image 100 × 50")
    }

    func testBlankCopiesAreIgnored() {
        XCTAssertNil(ClipboardStore.item(from: ClipboardSnapshot(types: ["public.utf8-plain-text"], text: "   \n ")))
        XCTAssertNil(ClipboardStore.item(from: ClipboardSnapshot()))
    }

    // MARK: - Persistence

    func testImageBytesAreNeverEncoded() throws {
        let image = ClipboardItem(kind: .image, text: "Image 2 × 2", imageData: Data([1, 2, 3]))
        let encoded = try JSONEncoder().encode([image])
        let decoded = try JSONDecoder().decode([ClipboardItem].self, from: encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].kind, .image)
        XCTAssertNil(decoded[0].imageData)
    }

    func testTextItemsRoundTrip() throws {
        let stored = item("keep me", pinned: true, at: 1234)
        let decoded = try JSONDecoder().decode([ClipboardItem].self, from: JSONEncoder().encode([stored]))
        XCTAssertEqual(decoded, [stored])
    }

    // MARK: - Row formatting

    func testAgeIsCompact() {
        let now = Date(timeIntervalSinceReferenceDate: 200_000)
        XCTAssertEqual(item("x", at: 200_000 - 10).age(at: now), "now")
        XCTAssertEqual(item("x", at: 200_000 - 300).age(at: now), "5m")
        XCTAssertEqual(item("x", at: 200_000 - 7_200).age(at: now), "2h")
        XCTAssertEqual(item("x", at: 200_000 - 172_800).age(at: now), "2d")
    }
}
