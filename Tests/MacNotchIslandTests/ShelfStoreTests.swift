import XCTest
@testable import MacNotchIsland

/// The shelf's rules: expiry, de-duplication, the item cap and the persistence migration.
/// Every store here gets its own UserDefaults suite and its own temp directory, so nothing
/// touches the real preferences or the user's shelf.
///
/// With one deliberate exception. The writers that turn a dropped picture, link or piece of
/// text into a file are static and put it where the app really puts it, which is the whole
/// point of testing them — so `drop` remembers each one and `tearDown` takes it away again.
/// Before that they piled up in the app's own folder on every developer's Mac, under a
/// comment saying they did not.
final class ShelfStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard
    private var dir = URL(fileURLWithPath: NSTemporaryDirectory())
    private let key = "shelfItems"
    /// Real files, in the app's real folder, to be removed when the test is done with them.
    private var written: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ShelfStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
        for url in written { try? FileManager.default.removeItem(at: url) }
        written.removeAll()
        try super.tearDownWithError()
    }

    /// A file one of the drop writers really wrote, taken away again at the end of the test.
    private func drop(_ url: URL?) throws -> URL {
        let url = try XCTUnwrap(url)
        written.append(url)
        return url
    }

    // MARK: - Helpers

    private func makeFile(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("shelf".utf8).write(to: url)
        return url.standardizedFileURL
    }

    private func makeStore(maxItems: Int = 24, expiryHours: Double = 0) -> ShelfStore {
        ShelfStore(defaults: defaults,
                   key: key,
                   maxItems: maxItems,
                   backgroundWork: false,
                   expiryHours: { expiryHours })
    }

    private func writeStoredItems(_ pairs: [(URL, Date)]) {
        let encoded: [[String: Any]] = pairs.map { ["path": $0.0.path, "addedAt": $0.1] }
        defaults.set(encoded, forKey: key)
    }

    private func item(_ url: URL, hoursAgo: Double) -> ShelfItem {
        ShelfItem(url: url, addedAt: Date().addingTimeInterval(-hoursAgo * 3600))
    }

    // MARK: - Anything can be dropped

    func testDroppedTextBecomesAFileNamedAfterItsFirstLine() throws {
        let url = try drop(ShelfStore.write(text: "Shopping list\nmilk\nbread"))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "Shopping list")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Shopping list\nmilk\nbread")
        XCTAssertTrue(ShelfStore.isOwned(url), "the island wrote it, so the island may tidy it away")
    }

    func testDroppedTextThatIsAllWhitespaceIsStillWrittenUnderATimeStamp() throws {
        let url = try drop(ShelfStore.write(text: "\n   \n"))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Text "), url.lastPathComponent)
    }

    func testDroppedLinkBecomesAWeblocFinderCanOpen() throws {
        let link = try XCTUnwrap(URL(string: "https://example.com/a/page"))
        let url = try drop(ShelfStore.write(link: link))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "webloc")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "example.com")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String]
        XCTAssertEqual(plist?["URL"], "https://example.com/a/page")
    }

    func testTwoDropsOfTheSameNameBecomeTwoFiles() throws {
        let first = try drop(ShelfStore.write(text: "Note\none"))
        let second = try drop(ShelfStore.write(text: "Note\ntwo"))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "Note\ntwo")
    }

    func testAFileFromFinderIsNeverOurs() throws {
        XCTAssertFalse(ShelfStore.isOwned(try makeFile("theirs.txt")))
    }

    // MARK: - Copying

    func testCopyingATextFileCarriesItsText() throws {
        let url = try makeFile("note.txt")
        try "the quick brown fox".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(ShelfStore.mightHaveExtras(url))
        let extras = try XCTUnwrap(ShelfStore.pasteboardExtras(for: url))
        let text = extras.first { $0.0 == .string }.map { String(data: $0.1, encoding: .utf8) }
        XCTAssertEqual(text, "the quick brown fox")
    }

    func testCopyingALinkCarriesItsAddressRatherThanItsPlist() throws {
        let link = try XCTUnwrap(URL(string: "https://example.com/page"))
        let url = try drop(ShelfStore.write(link: link))
        defer { try? FileManager.default.removeItem(at: url) }
        let extras = try XCTUnwrap(ShelfStore.pasteboardExtras(for: url))
        XCTAssertEqual(extras.first.map { String(data: $0.1, encoding: .utf8) }, "https://example.com/page")
    }

    func testAnOrdinaryFileCarriesNothingExtra() throws {
        let url = dir.appendingPathComponent("archive.zip")
        try Data("not really a zip".utf8).write(to: url)
        XCTAssertFalse(ShelfStore.mightHaveExtras(url))
    }

    func testSomethingTooBigToHoldIsNotRead() throws {
        let url = try makeFile("big.txt")
        try Data(repeating: 65, count: 4096).write(to: url)
        XCTAssertNil(ShelfStore.pasteboardExtras(for: url, limit: 1024), "the size guard comes first")
    }

    // MARK: - Files that go away

    func testAnItemWhoseFileWasDeletedIsDropped() throws {
        let url = try makeFile("gone.txt")
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(ShelfStore.stillThere(item(url, hoursAgo: 0)), "the folder is there, the file is not")
    }

    func testAnItemOnAnUnpluggedDiskIsKept() throws {
        let url = URL(fileURLWithPath: "/Volumes/Nothing Here/report.pdf")
        XCTAssertTrue(ShelfStore.stillThere(item(url, hoursAgo: 0)),
                      "the whole folder is missing, so the disk is away rather than the file gone")
    }

    // MARK: - Expiry (pure)

    func testExpiryRemovesItemsOlderThanTheLimit() throws {
        let old = item(try makeFile("old.txt"), hoursAgo: 30)
        let fresh = item(try makeFile("fresh.txt"), hoursAgo: 2)

        let kept = ShelfStore.pruned([old, fresh], expiryHours: 24)
        XCTAssertEqual(kept.map(\.url), [fresh.url])
    }

    func testExpiryKeepsItemsYoungerThanTheLimit() throws {
        let a = item(try makeFile("a.txt"), hoursAgo: 1)
        let b = item(try makeFile("b.txt"), hoursAgo: 23.5)

        XCTAssertEqual(ShelfStore.pruned([a, b], expiryHours: 24).count, 2)
    }

    func testZeroExpiryNeverRemovesAnything() throws {
        let ancient = item(try makeFile("ancient.txt"), hoursAgo: 24 * 365)
        let old = item(try makeFile("old.txt"), hoursAgo: 100)

        XCTAssertEqual(ShelfStore.pruned([ancient, old], expiryHours: 0).count, 2)
        XCTAssertEqual(ShelfStore.pruned([ancient, old], expiryHours: -1).count, 2)
    }

    func testExpiryUsesTheSuppliedNow() throws {
        let url = try makeFile("clock.txt")
        let added = Date(timeIntervalSince1970: 1_000_000)
        let one = ShelfItem(url: url, addedAt: added)

        XCTAssertEqual(ShelfStore.pruned([one], expiryHours: 2, now: added.addingTimeInterval(3600)).count, 1)
        XCTAssertEqual(ShelfStore.pruned([one], expiryHours: 2, now: added.addingTimeInterval(3 * 3600)).count, 0)
    }

    /// Stale items are swept when the store loads and again on the next add.
    func testStoreSweepsExpiredItemsOnLoadAndOnAdd() throws {
        let stale = try makeFile("stale.txt")
        let recent = try makeFile("recent.txt")
        writeStoredItems([(stale, Date().addingTimeInterval(-10 * 3600)),
                          (recent, Date().addingTimeInterval(-1 * 3600))])

        let store = makeStore(expiryHours: 5)
        XCTAssertEqual(store.items.map(\.url), [recent])

        let extra = try makeFile("extra.txt")
        store.add([extra])
        XCTAssertEqual(store.items.map(\.url), [extra, recent])
    }

    // MARK: - Adding

    func testAddDeduplicatesAndMovesToFront() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        let store = makeStore()

        store.add([a])
        store.add([b])
        XCTAssertEqual(store.items.map(\.url), [b, a])

        store.add([a])
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.map(\.url), [a, b])
    }

    func testAddIgnoresNonFileURLs() throws {
        let store = makeStore()
        let web = try XCTUnwrap(URL(string: "https://example.com/thing.pdf"))
        store.add([web])
        XCTAssertTrue(store.items.isEmpty)
    }

    func testMaxItemCapKeepsTheNewest() throws {
        let store = makeStore(maxItems: 3)
        var urls: [URL] = []
        for i in 0..<6 { urls.append(try makeFile("f\(i).txt")) }

        store.add(urls)
        XCTAssertEqual(store.items.count, 3)
        // add() inserts each URL at the front, so the last ones dropped survive.
        XCTAssertEqual(store.items.map(\.url), [urls[5], urls[4], urls[3]])
    }

    func testRemoveAndClear() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        let store = makeStore()
        store.add([a, b])

        store.remove([a])
        XCTAssertEqual(store.items.map(\.url), [b])
        XCTAssertFalse(store.contains(a))

        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue((defaults.array(forKey: key) as? [[String: Any]] ?? []).isEmpty)
    }

    // MARK: - Persistence

    func testPersistenceRoundTripKeepsTheAddedDate() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        let first = makeStore()
        first.add([a, b])
        let added = try XCTUnwrap(first.items.first?.addedAt)

        let second = makeStore()
        XCTAssertEqual(second.items.map(\.url), first.items.map(\.url))
        let reloaded = try XCTUnwrap(second.items.first?.addedAt)
        XCTAssertEqual(reloaded.timeIntervalSince1970, added.timeIntervalSince1970, accuracy: 1)
    }

    func testMissingFilesAreDroppedOnLoad() throws {
        let alive = try makeFile("alive.txt")
        let gone = dir.appendingPathComponent("gone.txt").standardizedFileURL
        writeStoredItems([(alive, Date()), (gone, Date())])

        XCTAssertEqual(makeStore().items.map(\.url), [alive])
    }

    func testMigratesLegacyStringArrayFormat() throws {
        let a = try makeFile("legacy-a.txt")
        let b = try makeFile("legacy-b.txt")
        defaults.set([a.path, b.path], forKey: key)

        let store = makeStore()
        XCTAssertEqual(store.items.map(\.url), [a, b])
        // Migrated items are treated as added now, so an upgrade doesn't wipe the shelf.
        for item in store.items {
            XCTAssertEqual(item.addedAt.timeIntervalSinceNow, 0, accuracy: 30)
        }

        // The store rewrites the new format, and it reloads cleanly.
        let raw = try XCTUnwrap(defaults.array(forKey: key) as? [[String: Any]])
        XCTAssertEqual(raw.count, 2)
        XCTAssertEqual(raw.first?["path"] as? String, a.path)
        XCTAssertNotNil(raw.first?["addedAt"] as? Date)
        XCTAssertEqual(makeStore().items.map(\.url), [a, b])
    }

    func testLegacyMigrationStillHonoursTheItemCap() throws {
        var paths: [String] = []
        for i in 0..<5 { paths.append(try makeFile("legacy\(i).txt").path) }
        defaults.set(paths, forKey: key)

        XCTAssertEqual(makeStore(maxItems: 2).items.count, 2)
    }

    // MARK: - Island activity

    func testShelfPublishesALiveActivityWhileItHoldsFiles() throws {
        let center = ActivityCenter.shared
        center.resetForTesting()
        let store = ShelfStore(defaults: defaults, key: key, maxItems: 24, backgroundWork: false,
                               expiryHours: { 0 }, publishesActivity: true)
        XCTAssertNil(center.activity(id: ShelfStore.activityID), "an empty shelf shows nothing")

        let a = try makeFile("a.png")
        store.add([a])
        guard case .shelf(let one)? = center.activity(id: ShelfStore.activityID)?.content else { return XCTFail("shelf activity missing") }
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.latestName, "a.png")
        XCTAssertTrue(one.latestIsImage)

        let b = try makeFile("notes.txt")
        store.add([b])
        guard case .shelf(let two)? = center.activity(id: ShelfStore.activityID)?.content else { return XCTFail("shelf activity missing") }
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.latestName, "notes.txt")
        XCTAssertFalse(two.latestIsImage)

        store.remove(b)
        store.clear()
        XCTAssertNil(center.activity(id: ShelfStore.activityID), "the activity ends with the last file")
        center.resetForTesting()
    }

    func testStoresBuiltForTestsStayOffTheIsland() throws {
        let center = ActivityCenter.shared
        center.resetForTesting()
        let store = makeStore()
        store.add([try makeFile("quiet.txt")])
        XCTAssertNil(center.activity(id: ShelfStore.activityID))
    }

    // MARK: - Compressing

    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-zip-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testOneFileIsNamedAfterItself() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Report.pdf")
        let url = ShelfStore.archiveURL(for: [file])
        XCTAssertEqual(url.lastPathComponent, "Report.zip")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL,
                       "beside the file it was made from, the way Finder does it")
    }

    func testSeveralFilesAreNamedAfterTheFolderTheyShare() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ["a.txt", "b.txt"].map { folder.appendingPathComponent($0) }
        XCTAssertEqual(ShelfStore.archiveURL(for: files).lastPathComponent,
                       folder.lastPathComponent + ".zip")
    }

    func testFilesFromDifferentFoldersHaveNoFolderInCommon() {
        let a = tempFolder(), b = tempFolder()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        XCTAssertNil(ShelfStore.commonFolder(of: [a.appendingPathComponent("x"), b.appendingPathComponent("y")]))
        XCTAssertEqual(ShelfStore.archiveURL(for: [a.appendingPathComponent("x"), b.appendingPathComponent("y")])
                        .lastPathComponent, "Archive.zip")
    }

    func testAnArchiveNeverOverwritesTheLastOne() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("Report.zip")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let next = ShelfStore.unusedURL(first)
        XCTAssertEqual(next.lastPathComponent, "Report 2.zip")
        FileManager.default.createFile(atPath: next.path, contents: Data())
        XCTAssertEqual(ShelfStore.unusedURL(first).lastPathComponent, "Report 3.zip")
    }

    func testAnArchiveBesideSomebodyElsesFilesIsTheirsToKeep() {
        // Written where the files are, which is not the island's own folder — so clearing the
        // shelf lets go of it and never deletes it.
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = ShelfStore.archiveURL(for: [folder.appendingPathComponent("Report.pdf")])
        XCTAssertFalse(ShelfStore.isOwned(url))
    }
}
