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
    // MARK: - Where it is kept, and who may read it

    /// The clipboard, the notes and the lyrics cache all go through one door, and it shuts
    /// behind them. On a stock Mac the umask hands out 644 — every other account on a shared
    /// machine — for a file holding everything its owner has copied.
    func testWhatIsKeptOnDiskBelongsToTheAccountThatWroteIt() throws {
        let name = "permissions-test-\(UUID().uuidString).json"
        try IslandFiles.write(Data("kept".utf8), to: name)
        guard let folder = IslandFiles.folder else { return XCTFail("no folder") }
        let file = folder.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(IslandFiles.read(name), Data("kept".utf8))
        XCTAssertEqual(IslandFiles.permissions(of: file), 0o600, "readable by its owner and nobody else")
        XCTAssertEqual(IslandFiles.permissions(of: folder), 0o700, "and so is the folder around it")

        // An atomic write replaces the file, so the permissions have to be put back each time.
        try IslandFiles.write(Data("kept again".utf8), to: name)
        XCTAssertEqual(IslandFiles.permissions(of: file), 0o600, "still, after being written over")
    }

    /// One app, one folder. The shelf used to write to a second one with a space in its name,
    /// so deleting the folder named after the app left the user's dropped files behind.
    func testEverythingTheAppRemembersIsInOneFolder() {
        guard let folder = IslandFiles.folder else { return XCTFail("no folder") }
        XCTAssertTrue(ShelfStore.dropFolder.path.hasPrefix(folder.path + "/"))
        XCTAssertNotEqual(ShelfStore.legacyDropFolder.path, ShelfStore.dropFolder.path)
        // A file left in the old one is still this app's to tidy up.
        XCTAssertTrue(ShelfStore.isOwned(ShelfStore.legacyDropFolder.appendingPathComponent("Note.txt")))
        XCTAssertTrue(ShelfStore.isOwned(ShelfStore.dropFolder.appendingPathComponent("Note.txt")))
        XCTAssertFalse(ShelfStore.isOwned(URL(fileURLWithPath: "/Users/someone/Downloads/Note.txt")))
    }

    /// All three of the stamps nspasteboard.org defines, not two.
    func testACopyMarkedByATooIsNotRecorded() {
        for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                     "org.nspasteboard.AutoGeneratedType"] {
            let snapshot = ClipboardSnapshot(types: ["public.utf8-plain-text", type], text: "secret")
            XCTAssertNil(ClipboardStore.item(from: snapshot), "\(type) must never be recorded")
        }
        XCTAssertNotNil(ClipboardStore.item(from: ClipboardSnapshot(types: ["public.utf8-plain-text"], text: "ordinary")))
    }


    // MARK: - Dragging an entry out

    func testEveryKindOfEntryKnowsWhetherItCanBeDragged() {
        XCTAssertTrue(ClipboardItem(kind: .text, text: "hello").canDrag)
        XCTAssertFalse(ClipboardItem(kind: .text, text: "").canDrag)
        XCTAssertTrue(ClipboardItem(kind: .url, text: "https://example.com").canDrag)
        XCTAssertFalse(ClipboardItem(kind: .file, text: "").canDrag)
        XCTAssertTrue(ClipboardItem(kind: .file, text: "/tmp/a.txt").canDrag)
        XCTAssertFalse(ClipboardItem(kind: .image, text: "Image").canDrag, "no bytes, nothing to carry")
        var picture = ClipboardItem(kind: .image, text: "Image")
        picture.imageData = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(picture.canDrag)
    }

    func testTextAndLinksBothHaveSomethingToCarry() {
        XCTAssertNotNil(ClipboardItem(kind: .text, text: "hello").dragProvider())
        XCTAssertNotNil(ClipboardItem(kind: .url, text: "https://example.com").dragProvider())
        // A link that will not parse is still text somebody copied.
        XCTAssertNotNil(ClipboardItem(kind: .url, text: "not a url at all").dragProvider())
    }

    func testAPictureCarriesItsBytes() {
        var picture = ClipboardItem(kind: .image, text: "Image")
        picture.imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let provider = picture.dragProvider()
        XCTAssertNotNil(provider)
        XCTAssertEqual(provider?.suggestedName, "Image.png")
        XCTAssertNil(ClipboardItem(kind: .image, text: "Image").dragProvider())
    }
}
