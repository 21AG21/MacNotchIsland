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

    // MARK: - Two drops, one name

    func testADropIsWrittenUnderItsOwnNameAndThenANumbered() {
        XCTAssertEqual(ShelfStore.dropFileName("Note", extension: "txt", attempt: 1), "Note.txt")
        XCTAssertEqual(ShelfStore.dropFileName("Note", extension: "txt", attempt: 2), "Note 2.txt")
        XCTAssertEqual(ShelfStore.dropFileName("github.com", extension: "webloc", attempt: 3), "github.com 3.webloc")
        XCTAssertEqual(ShelfStore.dropFileName("a/b", extension: "txt", attempt: 1), "a-b.txt",
                       "a slash would be a folder")
        XCTAssertEqual(ShelfStore.dropFileName("  \n ", extension: "png", attempt: 1), "Dropped.png")
        XCTAssertEqual(ShelfStore.dropFileName(String(repeating: "x", count: 200), extension: "txt", attempt: 1),
                       String(repeating: "x", count: 60) + ".txt")
    }

    /// The file system counts a name's bytes, decomposed, not its characters: sixty Korean
    /// syllables are 540 of them, and the write refused the name and lost the drop.
    func testANameIsCutToTheBytesTheFileSystemAllows() {
        let korean = String(repeating: "한", count: 80)
        XCTAssertEqual(ShelfStore.fileNameBytes(String(korean.prefix(60))), 540, "nine bytes a syllable, decomposed")
        for attempt in [1, 2, 123] {
            let name = ShelfStore.dropFileName(korean, extension: "txt", attempt: attempt)
            XCTAssertLessThanOrEqual(ShelfStore.fileNameBytes(name), ShelfStore.nameByteLimit, name)
            XCTAssertLessThanOrEqual(ShelfStore.fileNameBytes(name), 255)
            XCTAssertTrue(name.hasSuffix(attempt == 1 ? ".txt" : " \(attempt).txt"), name)
            XCTAssertTrue(name.hasPrefix("한"), "cut, not emptied")
            XCTAssertTrue(name.dropLast(attempt == 1 ? 4 : 4 + " \(attempt)".count).allSatisfy { $0 == "한" },
                          "cut a whole syllable at a time: \(name)")
        }
        // As much as fits: one syllable more would not have.
        let base = String(ShelfStore.dropFileName(korean, extension: "txt", attempt: 1).dropLast(4))
        XCTAssertGreaterThan(ShelfStore.fileNameBytes(base + "한.txt"), ShelfStore.nameByteLimit)
    }

    func testANameInTamilIsCutWithoutBreakingALetter() throws {
        // "தமிழ்" is five scalars in three letters, fifteen bytes; sixty letters are 300.
        let tamil = String(repeating: "தமிழ்", count: 30)
        let name = ShelfStore.dropFileName(tamil, extension: "txt", attempt: 1)
        XCTAssertLessThanOrEqual(ShelfStore.fileNameBytes(name), ShelfStore.nameByteLimit)
        let base = name.dropLast(4)
        XCTAssertTrue(tamil.hasPrefix(String(base)), name)
        let last = try XCTUnwrap(base.last)
        XCTAssertTrue(["த", "மி", "ழ்"].contains(String(last)), "a whole letter at the end, not half of one: \(last)")
    }

    func testANameThatAlreadyFitsIsLeftAlone() {
        XCTAssertEqual(ShelfStore.dropFileName("Réunion", extension: "txt", attempt: 1), "Réunion.txt")
        XCTAssertEqual(ShelfStore.dropFileName("회의록", extension: "txt", attempt: 2), "회의록 2.txt")
    }

    /// A file name is not prose: written in the Mac's own language, the stamp came out in
    /// Eastern Arabic figures on a Mac in Arabic.
    func testTheStampIsWrittenTheSameEverywhere() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // 2026-09-21 14:32:05 UTC.
        let moment = Date(timeIntervalSince1970: 1_790_001_125)
        XCTAssertEqual(ShelfStore.stamp("Image", now: moment, timeZone: utc), "Image 14.32.05")
        XCTAssertTrue(ShelfStore.stamp("Text", now: moment, timeZone: utc).unicodeScalars.allSatisfy(\.isASCII))
    }

    /// A folder of the test's own, so nothing here touches the app's.
    private func scratchFolder() throws -> URL {
        let url = dir.appendingPathComponent("drops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testANewFileNeverGoesOverOneThatIsThere() throws {
        let folder = try scratchFolder()
        try Data("theirs".utf8).write(to: folder.appendingPathComponent("Note.txt"))
        let url = try IslandFiles.writeNew(Data("mine".utf8), in: folder) {
            ShelfStore.dropFileName("Note", extension: "txt", attempt: $0)
        }
        XCTAssertEqual(url.lastPathComponent, "Note 2.txt")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Note.txt"), encoding: .utf8), "theirs")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["Note 2.txt", "Note.txt"], "and nothing half-written is left beside them")
    }

    /// Every item of a drag is read at once, so two links to one site are written at once. The
    /// name used to be looked for first and written to after, and both found it free.
    func testDropsWrittenAtOnceUnderOneNameAreAllKept() throws {
        let folder = try scratchFolder()
        let count = 16
        var written = [URL?](repeating: nil, count: count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let url = try? IslandFiles.writeNew(Data("link \(index)".utf8), in: folder) {
                ShelfStore.dropFileName("github.com", extension: "webloc", attempt: $0)
            }
            lock.lock(); written[index] = url; lock.unlock()
        }
        let urls = written.compactMap { $0 }
        XCTAssertEqual(urls.count, count, "every one of them was written")
        XCTAssertEqual(Set(urls).count, count, "each under a name of its own")
        for (index, url) in written.enumerated() {
            XCTAssertEqual(try url.map { try String(contentsOf: $0, encoding: .utf8) }, "link \(index)",
                           "and none of them over another")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, count)
    }

    func testAWriteWithNowhereToGoLeavesNothingBehind() throws {
        let folder = try scratchFolder()
        try Data("theirs".utf8).write(to: folder.appendingPathComponent("Taken.txt"))
        XCTAssertThrowsError(try IslandFiles.writeNew(Data("mine".utf8), in: folder, attempts: 3) { _ in "Taken.txt" })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Taken.txt"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Taken.txt"), encoding: .utf8), "theirs")
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

    func testADropBiggerThanTheShelfKeepsWhatWasDraggedFirst() throws {
        let store = makeStore(maxItems: 3)
        var urls: [URL] = []
        for i in 0..<6 { urls.append(try makeFile("f\(i).txt")) }

        store.add(urls)
        XCTAssertEqual(store.items.count, 3)
        // Each goes in at the front as it comes; what did not fit is the end of the drop,
        // not the first file of it pushed off by the rest.
        XCTAssertEqual(store.items.map(\.url), [urls[2], urls[1], urls[0]])
    }

    // MARK: - The cap (pure)

    private func shelf(_ urls: [URL]) -> [ShelfItem] {
        urls.enumerated().map { ShelfItem(url: $0.element, addedAt: Date(timeIntervalSinceReferenceDate: Double(100 - $0.offset))) }
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/shelf-cap/\(name)") }

    /// Twenty-five files from Finder onto a shelf holding a snippet the island wrote: the
    /// snippet used to leave the shelf and go to the Trash, with the first file of the drop,
    /// and nothing said. Room is made only out of Finder's files, and what still does not fit
    /// is turned away from the end of the drop.
    func testADropNeverPushesTheIslandsOwnFilesOff() {
        let snippet = url("Snippet.txt"), older = url("older.pdf")
        let dropped = (0..<3).map { url("new\($0).png") }
        let admission = ShelfStore.admitting(dropped, into: shelf([snippet, older]), cap: 3,
                                             isOwned: { $0 == snippet })
        XCTAssertEqual(admission.evicted, [older], "a file from Finder makes room; it is still where it was")
        XCTAssertEqual(admission.refused, [dropped[2]], "the end of the drop is what does not fit")
        XCTAssertEqual(admission.items.map(\.url), [dropped[1], dropped[0], snippet],
                       "the island's own file stays, and the first file dragged got in")
    }

    func testAShelfFullOfTheIslandsOwnFilesTurnsTheWholeDropAway() {
        let owned = [url("a.txt"), url("b.png")]
        let dropped = [url("c.pdf"), url("d.pdf")]
        let admission = ShelfStore.admitting(dropped, into: shelf(owned), cap: 2, isOwned: { owned.contains($0) })
        XCTAssertEqual(admission.items.map(\.url), owned, "nothing of the island's is pushed off")
        XCTAssertEqual(admission.refused, dropped)
        XCTAssertTrue(admission.evicted.isEmpty)
    }

    func testADropThatFitsTakesNothingAndTurnsNothingAway() {
        let old = [url("a.pdf")]
        let dropped = [url("b.pdf"), url("c.pdf")]
        let admission = ShelfStore.admitting(dropped, into: shelf(old), cap: 24, isOwned: { _ in false })
        XCTAssertEqual(admission.items.map(\.url), [dropped[1], dropped[0], old[0]])
        XCTAssertTrue(admission.evicted.isEmpty)
        XCTAssertTrue(admission.refused.isEmpty)
    }

    func testAFileAlreadyOnAFullShelfIsNeverTurnedAway() {
        let owned = [url("a.txt"), url("b.txt")]
        let admission = ShelfStore.admitting([owned[1]], into: shelf(owned), cap: 2, isOwned: { _ in true })
        XCTAssertTrue(admission.refused.isEmpty, "dropping it again only brings it to the front")
        XCTAssertEqual(admission.items.map(\.url), [owned[1], owned[0]])
    }

    func testTheSameFileTwiceInOneDropCountsOnce() {
        let a = url("a.pdf"), b = url("b.pdf")
        let admission = ShelfStore.admitting([a, b, a], into: [], cap: 2, isOwned: { _ in false })
        XCTAssertEqual(admission.items.map(\.url), [b, a])
        XCTAssertTrue(admission.refused.isEmpty)
    }

    func testTheIslandsOwnSnippetSurvivesAFullDropOnTheStore() throws {
        let snippet = try drop(ShelfStore.write(text: "Parked for later"))
        let store = makeStore(maxItems: 3)
        store.add([snippet])
        let files = try (0..<3).map { try makeFile("finder\($0).pdf") }
        store.add(files)
        XCTAssertTrue(store.contains(snippet), "the snippet has nowhere else to live, so it stays")
        XCTAssertEqual(store.items.map(\.url), [files[1], files[0], snippet.standardizedFileURL])
    }

    func testWhatDidNotFitIsCounted() {
        XCTAssertEqual(ShelfStore.noRoomTitle(1), "1 didn't fit")
        XCTAssertEqual(ShelfStore.noRoomTitle(12), "12 didn't fit")
    }

    // MARK: - Clearing, and taking it back

    func testClearDuringAFindTakesOnlyTheMatches() throws {
        let store = makeStore()
        let files = try ["a.pdf", "b.txt", "c.pdf", "d.png"].map { try makeFile($0) }
        store.add(files)
        XCTAssertEqual(Set(ShelfStore.clearing(store.items, query: "pdf").map(\.url)), [files[0], files[2]])

        store.clear(matching: "pdf")
        XCTAssertEqual(store.items.map(\.url), [files[3], files[1]],
                       "the files the find was hiding stay where they were")
        XCTAssertEqual(Set(store.clearedItems?.map(\.url) ?? []), [files[0], files[2]])
    }

    func testClearWithNothingTypedTakesEverything() throws {
        let store = makeStore()
        store.add(try ["a.pdf", "b.txt"].map { try makeFile($0) })
        XCTAssertEqual(ShelfStore.clearing(store.items, query: nil).count, 2)
        XCTAssertEqual(ShelfStore.clearing(store.items, query: "  ").count, 2, "a field with only a space in it narrows nothing")
        store.clear(matching: nil)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testAClearCanBeTakenBackInTheOrderItWasIn() throws {
        let store = makeStore()
        store.add(try ["a.pdf", "b.txt", "c.pdf"].map { try makeFile($0) })
        let before = store.items
        store.clear(matching: "pdf")
        store.undoClear()
        XCTAssertEqual(store.items, before)
        XCTAssertNil(store.clearedItems, "the offer is spent once it is taken")
        XCTAssertEqual((defaults.array(forKey: key) as? [[String: Any]])?.count, 3, "and what is saved says so too")
    }

    /// A download or a screenshot landing on the shelf by itself a moment after a Clear took
    /// the Undo away with it, and the island's own snippets went to the Trash — well inside
    /// the twelve seconds the pill had promised.
    func testAFileLandingSinceDoesNotEndTheOffer() throws {
        let store = makeStore()
        let files = try ["a.pdf", "b.txt", "c.pdf"].map { try makeFile($0) }
        store.add(files)
        let before = store.items.map(\.url)
        store.clear(matching: "pdf")
        let since = try makeFile("since.png")
        store.add([since])
        XCTAssertEqual(Set(store.clearedItems?.map(\.url) ?? []), [files[0], files[2]], "the offer stands")
        store.undoClear()
        XCTAssertEqual(store.items.map(\.url), [since] + before,
                       "what landed since stays at the front, and the rest goes back where it was")
        XCTAssertNil(store.clearedItems)
    }

    func testDroppingAClearedFileAgainEndsTheOffer() throws {
        let store = makeStore()
        let files = try ["a.pdf", "b.txt"].map { try makeFile($0) }
        store.add(files)
        store.clear(matching: "pdf")
        store.add([files[0]])
        XCTAssertNil(store.clearedItems, "its slot is filled again, so there is nothing left to put back")
        store.undoClear()
        XCTAssertEqual(store.items.map(\.url), [files[0], files[1]])
    }

    func testAShelfFilledPastWhereTheClearedFilesWouldFitEndsTheOffer() throws {
        let store = makeStore(maxItems: 3)
        store.add(try ["a.pdf", "b.pdf"].map { try makeFile($0) })
        store.clear(matching: nil)
        let c = try makeFile("c.txt")
        store.add([c])
        XCTAssertNotNil(store.clearedItems, "one and two is three: they still fit")
        let d = try makeFile("d.txt")
        store.add([d])
        XCTAssertNil(store.clearedItems, "two and two is more than the shelf holds")
        store.undoClear()
        XCTAssertEqual(store.items.map(\.url), [d, c])
    }

    func testTheOfferStandsUntilPuttingBackWouldBeWrong() {
        let a = ShelfItem(url: url("a.pdf"), addedAt: Date()), b = ShelfItem(url: url("b.txt"), addedAt: Date())
        let since = ShelfItem(url: url("since.png"), addedAt: Date())
        XCTAssertTrue(ShelfStore.offerStands(taken: [a], on: [b, since], cap: 3), "something landed: still fits")
        XCTAssertFalse(ShelfStore.offerStands(taken: [a], on: [a, b], cap: 3), "a taken file is back")
        XCTAssertFalse(ShelfStore.offerStands(taken: [a, b], on: [since], cap: 2), "no room to put them back")
        XCTAssertTrue(ShelfStore.offerStands(taken: [a], on: [], cap: 1))
    }

    func testTakingAClearBackKeepsBothOrders() {
        let now = Date()
        let items = ["a", "b", "c", "d"].map { ShelfItem(url: url("\($0).pdf"), addedAt: now) }
        let redropped = ShelfItem(url: items[1].url, addedAt: now.addingTimeInterval(5))
        let since = ShelfItem(url: url("since.png"), addedAt: now.addingTimeInterval(3))
        // a and c were cleared; d left the shelf since, b was dropped again and something new landed.
        let restored = ShelfStore.undoing(taken: [items[0], items[2]], before: items, now: [redropped, since])
        XCTAssertEqual(restored.map(\.url), [since.url, items[0].url, items[1].url, items[2].url],
                       "the newcomer in front, the rest in the order the Clear found them, and nothing that left since")
        XCTAssertEqual(restored[2].addedAt, redropped.addedAt, "a file dropped again keeps its second landing")
    }

    // MARK: - A Clear that never settled

    func testAClearWritesDownTheFilesItIsHoldingBackAndSettlingCrossesThemOff() throws {
        let snippet = try drop(ShelfStore.write(text: "Parked for later"))
        let store = makeStore()
        store.add([snippet, try makeFile("theirs.pdf")])
        store.clear(matching: nil)
        let pending = ShelfStore.pendingTrashKey(key)
        XCTAssertEqual(defaults.stringArray(forKey: pending), [snippet.standardizedFileURL.path],
                       "only the island's own file: nobody else's is ever sent to the Trash")
        store.undoClear()
        XCTAssertNil(defaults.stringArray(forKey: pending), "taken back, nothing is waiting")
        store.clear(matching: nil)
        store.clear()
        XCTAssertNil(defaults.stringArray(forKey: pending), "settled, nothing is waiting")
    }

    /// The shelf is saved without what a Clear took at once, and the island's own files among
    /// them only went to the Trash once the offer had gone. An app that stopped inside the
    /// moment left them in Application Support for good.
    func testLaunchFinishesAClearThatNeverSettled() throws {
        let owned = ShelfStore.dropFolder.appendingPathComponent("Parked.txt")
        let back = ShelfStore.dropFolder.appendingPathComponent("Dropped again.txt")
        let theirs = dir.appendingPathComponent("theirs.pdf")
        let shelf = [ShelfItem(url: back.standardizedFileURL, addedAt: Date())]
        XCTAssertEqual(ShelfStore.orphans(in: [owned, back, theirs], onShelf: shelf), [owned.standardizedFileURL],
                       "what is on the shelf again stays, and a file from Finder is never the island's to trash")
        XCTAssertTrue(ShelfStore.orphans(in: [], onShelf: shelf).isEmpty, "nothing written down, nothing touched")

        defaults.set([owned.path], forKey: ShelfStore.pendingTrashKey(key))
        _ = makeStore()
        XCTAssertNil(defaults.stringArray(forKey: ShelfStore.pendingTrashKey(key)), "read once, then crossed off")
    }

    func testASecondClearSupersedesTheFirst() throws {
        let store = makeStore()
        let files = try ["a.pdf", "b.txt"].map { try makeFile($0) }
        store.add(files)
        store.clear(matching: "pdf")
        store.clear(matching: nil)
        XCTAssertEqual(store.clearedItems?.map(\.url), [files[1]], "one offer, for the most recent Clear")
        store.undoClear()
        XCTAssertEqual(store.items.map(\.url), [files[1]])
    }

    func testClearingTheWholeShelfFromTheMenuCannotBeTakenBack() throws {
        let store = makeStore()
        store.add([try makeFile("a.pdf"), try makeFile("b.pdf")])
        store.clear(matching: "a.pdf")
        store.clear()
        XCTAssertNil(store.clearedItems)
        store.undoClear()
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - What Space previews

    func testSpacePreviewsWhatIsPickedOutFirst() {
        let all = [url("a.pdf"), url("b.png"), url("c.pdf")]
        XCTAssertEqual(ShelfStore.quickLookTargets(selected: [all[1]], shown: all, finding: false, on: all), [all[1]])
        XCTAssertEqual(ShelfStore.quickLookTargets(selected: [all[1]], shown: [], finding: true, on: all), [all[1]],
                       "a selection wins over a find")
        XCTAssertEqual(ShelfStore.quickLookTargets(selected: [], shown: [all[0], all[2]], finding: true, on: all),
                       [all[0], all[2]], "then what a find is showing")
        XCTAssertEqual(ShelfStore.quickLookTargets(selected: [], shown: all, finding: false, on: all), all, "then everything")
        XCTAssertEqual(ShelfStore.quickLookTargets(selected: [url("gone.pdf")], shown: all, finding: false, on: all), all,
                       "a selection that has left the shelf is no selection")
    }

    /// "zzz" typed over "No matches": the narrowed list was empty, fell through, and Space
    /// previewed every file the find was hiding.
    func testAFindThatMatchesNothingPreviewsNothing() {
        let all = [url("a.pdf"), url("b.png")]
        XCTAssertTrue(ShelfStore.quickLookTargets(selected: [], shown: [], finding: true, on: all).isEmpty)
        XCTAssertTrue(ShelfStore.quickLookTargets(selected: [], shown: [url("gone.pdf")], finding: true, on: all).isEmpty,
                      "nor a match that has since left the shelf")
    }

    func testTheStoreHearsWhatTheStripHasPickedOut() throws {
        let store = makeStore()
        let files = try ["a.pdf", "b.png"].map { try makeFile($0) }
        store.add(files)
        XCTAssertEqual(store.quickLookTargets, store.urls, "nothing said yet is the whole shelf")
        store.stripChanged(selected: [files[0]], shown: store.urls, finding: false)
        XCTAssertEqual(store.quickLookTargets, [files[0]])
        store.remove([files[0]])
        XCTAssertEqual(store.quickLookTargets, [files[1]], "and never a file that has left it")
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

    // MARK: - Filing things away

    func testMovingTakesFilesOffTheShelfAndPutsThemWhereTheyWereSent() {
        let shelf = ShelfStore.shared
        shelf.clear()
        defer { shelf.clear() }
        let from = tempFolder(), to = tempFolder()
        defer { try? FileManager.default.removeItem(at: from); try? FileManager.default.removeItem(at: to) }
        let file = from.appendingPathComponent("Note.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("hello".utf8))
        shelf.add([file])
        XCTAssertEqual(shelf.items.count, 1)

        shelf.move([file], to: to)
        XCTAssertTrue(shelf.items.isEmpty, "off the shelf once it is somewhere else")
        XCTAssertTrue(FileManager.default.fileExists(atPath: to.appendingPathComponent("Note.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a move, not a copy")
    }

    func testAMoveNeverOverwritesWhatIsAlreadyThere() {
        let shelf = ShelfStore.shared
        shelf.clear()
        defer { shelf.clear() }
        let from = tempFolder(), to = tempFolder()
        defer { try? FileManager.default.removeItem(at: from); try? FileManager.default.removeItem(at: to) }
        FileManager.default.createFile(atPath: to.appendingPathComponent("Note.txt").path, contents: Data("theirs".utf8))
        let file = from.appendingPathComponent("Note.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("mine".utf8))
        shelf.add([file])
        shelf.move([file], to: to)
        let theirs = try? String(contentsOf: to.appendingPathComponent("Note.txt"), encoding: .utf8)
        XCTAssertEqual(theirs, "theirs", "what was there is untouched")
        let mine = try? String(contentsOf: to.appendingPathComponent("Note 2.txt"), encoding: .utf8)
        XCTAssertEqual(mine, "mine", "and what arrived is beside it")
    }

    func testAFileThatWillNotMoveStaysOnTheShelf() {
        let shelf = ShelfStore.shared
        shelf.clear()
        defer { shelf.clear() }
        let from = tempFolder()
        defer { try? FileManager.default.removeItem(at: from) }
        let file = from.appendingPathComponent("Note.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        shelf.add([file])
        // Nowhere to move it to: the destination does not exist.
        shelf.move([file], to: URL(fileURLWithPath: "/nowhere/at/all"))
        XCTAssertEqual(shelf.items.count, 1, "nothing is lost between the two")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
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

    // MARK: - Compressing several

    func testOneFileIsHandedToDittoAsItself() {
        let file = URL(fileURLWithPath: "/tmp/x/Report.pdf")
        let zip = URL(fileURLWithPath: "/tmp/x/Report.zip")
        XCTAssertEqual(ShelfStore.dittoArguments(archiving: [file], gatheredIn: nil, to: zip),
                       ["-c", "-k", "--sequesterRsrc", "--keepParent", "/tmp/x/Report.pdf", "/tmp/x/Report.zip"])
    }

    /// `ditto -c` takes one source. Every file used to be handed to it at once, and it refused.
    func testSeveralFilesAreHandedToDittoAsTheOneFolderTheyWereGatheredInto() {
        let files = ["a.txt", "b.txt", "c.txt"].map { URL(fileURLWithPath: "/tmp/x/" + $0) }
        let staging = URL(fileURLWithPath: "/tmp/gathered", isDirectory: true)
        let zip = URL(fileURLWithPath: "/tmp/x/x.zip")
        let arguments = ShelfStore.dittoArguments(archiving: files, gatheredIn: staging, to: zip)
        XCTAssertEqual(arguments, ["-c", "-k", "--sequesterRsrc", "/tmp/gathered", "/tmp/x/x.zip"])
        XCTAssertEqual(arguments.filter { !$0.hasPrefix("-") }.count, 2, "one source and the archive")
        XCTAssertFalse(arguments.contains("--keepParent"), "they unpack as themselves, not inside the folder")
    }

    func testGatheredFilesStepAroundEachOthersNames() {
        let files = ["/a/Notes.txt", "/b/Notes.txt", "/c/notes.txt", "/d/Folder", "/e/Folder", "/f/Plan.pdf"]
            .map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(ShelfStore.gatheredNames(for: files),
                       ["Notes.txt", "Notes 2.txt", "notes 3.txt", "Folder", "Folder 2", "Plan.pdf"],
                       "the disk does not tell Notes.txt from notes.txt, so neither does this")
    }

    /// The real thing, with the real `ditto`: two files in, one archive on the shelf, and the
    /// two files in it.
    func testSeveralFilesAreCompressedIntoOneArchiveOnTheShelf() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try ["a.txt", "b.txt"].map { name -> URL in
            let url = folder.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
        let store = makeStore()
        store.compress(files)
        let landed = XCTNSPredicateExpectation(
            predicate: NSPredicate(block: { _, _ in store.items.contains { $0.url.pathExtension == "zip" } }),
            object: nil)
        wait(for: [landed], timeout: 20)
        let archive = try XCTUnwrap(store.items.first { $0.url.pathExtension == "zip" }?.url)
        XCTAssertEqual(archive.lastPathComponent, folder.lastPathComponent + ".zip")

        let unpacked = tempFolder()
        defer { try? FileManager.default.removeItem(at: unpacked) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        // Whatever `ditto` kept of the files' attributes beside them is not one of the files.
        let unpackedNames = try FileManager.default.contentsOfDirectory(atPath: unpacked.path)
            .filter { $0 != "__MACOSX" }.sorted()
        XCTAssertEqual(unpackedNames, ["a.txt", "b.txt"])
        XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("b.txt"), encoding: .utf8), "b.txt")
    }
}
