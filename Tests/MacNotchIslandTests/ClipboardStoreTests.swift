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

    // MARK: - What a click says it does

    /// A click pastes into the app in front with "Paste after picking an item" on and
    /// Accessibility allowed, and the row said "copy again" either way.
    func testARowSaysWhetherAClickPastesOrCopies() {
        XCTAssertEqual(ClipboardStore.pickHint(pastes: true), "Pastes it where you were typing")
        XCTAssertEqual(ClipboardStore.pickHint(pastes: false), "Copies it again")
        XCTAssertTrue(ClipboardStore.pickHelp(pastes: true).hasPrefix("Click to paste it where you were typing"))
        XCTAssertTrue(ClipboardStore.pickHelp(pastes: false).hasPrefix("Click to copy it again"))
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

    // MARK: - Clearing, and taking it back

    func testClearKeepsThePinnedCopies() {
        let pinned = [item("address", pinned: true, at: 3), item("token", pinned: true, at: 1)]
        let loose = [item("a line", at: 4), item("another", at: 2)]
        let going = ClipboardStore.clearing([loose[0], pinned[0], loose[1], pinned[1]], query: nil)
        XCTAssertEqual(Set(going.map { $0.id }), Set(loose.map { $0.id }),
                       "a pin is somebody saying keep this, and Clear is not them taking it back")
        XCTAssertTrue(ClipboardStore.clearing(pinned, query: nil).isEmpty, "a list of pins has nothing to clear")
    }

    func testClearDuringAFindTakesOnlyTheMatchesThatAreNotPinned() {
        let invoice = item("invoice 42", at: 3)
        let pinnedInvoice = item("invoice 41", pinned: true, at: 2)
        let other = item("lunch?", at: 1)
        let going = ClipboardStore.clearing([invoice, pinnedInvoice, other], query: "invoice")
        XCTAssertEqual(going.map { $0.id }, [invoice.id])
    }

    func testUndoPutsWhatWasClearedBackBesideWhatWasCopiedSince() {
        let older = item("older", at: 10)
        let oldest = item("oldest", at: 5)
        let pin = item("pinned", pinned: true, at: 7)
        let since = item("copied since", at: 20)
        let restored = ClipboardStore.restoring([older, oldest], into: [since, pin], limit: 50)
        XCTAssertEqual(restored.map { $0.text }, ["copied since", "older", "pinned", "oldest"],
                       "each back where its time puts it, and nothing copied since is moved")
    }

    func testUndoDoesNotPutBackWhatIsAlreadyThere() {
        let kept = item("kept", at: 10)
        let restored = ClipboardStore.restoring([kept], into: [kept], limit: 50)
        XCTAssertEqual(restored.count, 1)
    }

    func testUndoStillHonoursTheLimit() {
        let cleared = [item("a", at: 3), item("b", at: 2)]
        let restored = ClipboardStore.restoring(cleared, into: [item("new", at: 9)], limit: 2)
        XCTAssertEqual(restored.map { $0.text }, ["new", "a"])
    }

    func testTheSectionsClearCanBeTakenBack() {
        let previousOverride = IslandFiles.overrideFolder
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipboard-clear-\(UUID().uuidString)", isDirectory: true)
        let wasGallery = RenderMode.isGallery
        let store = ClipboardStore.shared
        IslandFiles.overrideFolder = folder
        RenderMode.isGallery = true
        defer {
            store.seedForGallery([])
            // Anything on its way to the disk lands in the folder made for this test.
            store.flush()
            RenderMode.isGallery = wasGallery
            IslandFiles.overrideFolder = previousOverride
            try? FileManager.default.removeItem(at: folder)
        }
        let pin = item("keep me", pinned: true, at: 2)
        let loose = item("let me go", at: 1)
        store.seedForGallery([pin, loose])

        store.clear(matching: nil)
        XCTAssertEqual(store.items.map { $0.id }, [pin.id], "the pin stays")
        XCTAssertEqual(store.clearedItems?.map { $0.id }, [loose.id])
        store.undoClear()
        XCTAssertEqual(store.items.map { $0.id }, [pin.id, loose.id])
        XCTAssertNil(store.clearedItems, "the offer is spent once it is taken")
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

    func testLoweringTheLimitTrimsWhatIsAlreadyKept() {
        // "Items kept" is what is kept now: lowering it used to change nothing until the next
        // copy. The same rule as a copy's: oldest unpinned first, pins and the newest never.
        let items = [item("t4", at: 4), item("t3", at: 3), item("p", pinned: true, at: 2),
                     item("t1", at: 1), item("t0", at: 0)]
        XCTAssertEqual(ClipboardStore.capped(items, limit: 3).map(\.text), ["t4", "t3", "p"])
        XCTAssertEqual(ClipboardStore.capped(items, limit: 1).map(\.text), ["t4", "p"])
        XCTAssertEqual(ClipboardStore.capped(items, limit: 10), items, "a limit raised takes nothing")
    }

    func testALimitThatIsNotANumberIsNotACrash() {
        XCTAssertEqual(ClipboardStore.itemLimit(50), 50)
        XCTAssertEqual(ClipboardStore.itemLimit(.nan), 50)
        XCTAssertEqual(ClipboardStore.itemLimit(.infinity), 50)
        XCTAssertEqual(ClipboardStore.itemLimit(-4), 1)
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

    /// The first line is found by walking to it rather than by splitting the whole copy, and it
    /// is the line the split gave: blank lines before it skipped, any line break ending it, and
    /// a first line of nothing but spaces falling back to the whole copy, trimmed.
    func testThePreviewIsTheFirstLineWithAnythingOnIt() {
        XCTAssertEqual(item("\n\nhello\nworld").preview, "hello")
        XCTAssertEqual(item("one\rtwo").preview, "one")
        XCTAssertEqual(item("\r\n  indented  \r\nnext").preview, "indented")
        XCTAssertEqual(item("   \nsecond\nthird").preview, "second\nthird")
        XCTAssertEqual(item("single").preview, "single")
        XCTAssertEqual(item("").preview, "")
        let long = String(repeating: "a", count: 100_000)
        XCTAssertEqual(item(long + "\n" + long).preview, long)
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

    func testNothingIsWrittenDownUnlessTheHistoryIsKeptAcrossRelaunches() {
        // On out of the box, and held in memory: written down, it is everything somebody
        // copied that a password manager did not mark, in a file that outlives the moment.
        let items = [item("a password nobody marked"), ClipboardItem(kind: .image, text: "Image", imageData: Data([1]))]
        XCTAssertNil(ClipboardStore.toPersist(items, keeping: false))
        XCTAssertEqual(ClipboardStore.toPersist(items, keeping: true)?.map(\.kind), [.text],
                       "and when it is kept, never a picture")
    }

    // MARK: - Row formatting

    func testAgeIsCompact() {
        let now = Date(timeIntervalSinceReferenceDate: 200_000)
        XCTAssertEqual(item("x", at: 200_000 - 10).age(at: now), "now")
        XCTAssertEqual(item("x", at: 200_000 - 300).age(at: now), "5m")
        XCTAssertEqual(item("x", at: 200_000 - 7_200).age(at: now), "2h")
        XCTAssertEqual(item("x", at: 200_000 - 172_800).age(at: now), "2d")
    }

    /// "4m" is "4 metres" to a speech synthesiser, and it was what VoiceOver was handed for the
    /// clipboard's rows, the Notifications section's and the shelf's tiles. The row keeps the
    /// short form; what is said is the same figure in words.
    func testAgeIsSpokenInWords() {
        let now = Date(timeIntervalSinceReferenceDate: 200_000)
        XCTAssertEqual(item("x", at: 200_000 - 10).spokenAge(at: now), "just now")
        XCTAssertEqual(item("x", at: 200_000 - 60).spokenAge(at: now), "1 minute ago")
        XCTAssertEqual(item("x", at: 200_000 - 300).spokenAge(at: now), "5 minutes ago")
        XCTAssertEqual(item("x", at: 200_000 - 3_600).spokenAge(at: now), "1 hour ago")
        XCTAssertEqual(item("x", at: 200_000 - 7_200).spokenAge(at: now), "2 hours ago")
        XCTAssertEqual(item("x", at: 200_000 - 86_400).spokenAge(at: now), "1 day ago")
        XCTAssertEqual(item("x", at: 200_000 - 172_800).spokenAge(at: now), "2 days ago")
    }

    /// One rule for the two forms, so the figure said is always the figure shown.
    func testTheSpokenAgeIsTheClippedOneSpelledOut() {
        let now = Date(timeIntervalSinceReferenceDate: 200_000)
        let pairs = [(59.0, "now", "just now"), (119, "1m", "1 minute ago"), (3_599, "59m", "59 minutes ago"),
                     (5_400, "1h", "1 hour ago"), (86_399, "23h", "23 hours ago"), (1_000_000, "11d", "11 days ago")]
        for (seconds, clipped, spoken) in pairs {
            let then = now.addingTimeInterval(-seconds)
            XCTAssertEqual(RelativeAge.clipped(since: then, at: now), clipped)
            XCTAssertEqual(RelativeAge.spoken(since: then, at: now), spoken)
        }
    }

    func testAnAgeFromTheFutureOrFromNowhereIsNow() {
        let now = Date(timeIntervalSinceReferenceDate: 200_000)
        XCTAssertEqual(RelativeAge.clipped(since: now.addingTimeInterval(600), at: now), "now", "a clock set back")
        XCTAssertEqual(RelativeAge.spoken(since: now.addingTimeInterval(600), at: now), "just now")
        XCTAssertTrue(RelativeAge.clipped(since: Date(timeIntervalSinceReferenceDate: -1e300), at: now).hasSuffix("d"),
                      "a date too far back to count does not trap on its way into an Int")
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

    // MARK: - Where it came from

    func testACopyRemembersTheAppItCameFrom() {
        let snapshot = ClipboardSnapshot(types: [], text: "hello")
        let item = ClipboardStore.item(from: snapshot, app: "Safari")
        XCTAssertEqual(item?.app, "Safari")
    }

    func testTheAppIsSearchedAlongsideTheWords() {
        let now = Date()
        let items = [
            ClipboardItem(kind: .url, text: "https://example.com/a", date: now, app: "Safari"),
            ClipboardItem(kind: .text, text: "let x = 1", date: now, app: "Xcode"),
        ]
        XCTAssertEqual(ClipboardView.ordered(items, query: "safari").map(\.kind), [.url])
        XCTAssertEqual(ClipboardView.ordered(items, query: "xcode").map(\.kind), [.text])
        XCTAssertEqual(ClipboardView.ordered(items, query: "example").map(\.kind), [.url],
                       "and the words still work")
    }

    func testAnEntryWrittenBeforeThisExistedStillReadsBack() {
        // The app was added to what is persisted; older files simply do not carry it.
        let json = Data("""
        [{"id":"\(UUID().uuidString)","kind":"text","text":"old","date":0,"pinned":false}]
        """.utf8)
        let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: json)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertNil(decoded?.first?.app)
    }

    // MARK: - Rows whose files have gone

    /// The question used to be put to the file system from inside the row's own body, which is
    /// run again on every hover and every scroll of a fifty-row list. A sweep asks it once per
    /// file instead, and what a row reads is the answer the last sweep left behind.
    func testASweepAsksTheDiskOncePerFileAndTheRowOnlyReadsTheAnswer() throws {
        var asked = 0
        let entry = item("/tmp/one.txt\n/tmp/two.txt", kind: .file)
        _ = ClipboardStore.filesAreGone(urls: entry.fileURLs, exists: { _ in
            asked += 1
            return false
        })
        XCTAssertEqual(asked, 2, "one question per file, and only while a sweep is running")

        // And the answers themselves, put in front of the store the one way anything outside
        // it can: a history handed in, and swept against the files really under it.
        let there = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipboard-sweep-\(UUID().uuidString).txt")
        try Data("still here".utf8).write(to: there)
        defer { try? FileManager.default.removeItem(at: there) }
        let alive = item(there.path, kind: .file, at: 1)
        let gone = item("/tmp/no-such-file-\(UUID().uuidString).txt", kind: .file, at: 2)

        let store = ClipboardStore.shared
        let wasGallery = RenderMode.isGallery
        RenderMode.isGallery = true
        defer {
            store.seedForGallery([])
            RenderMode.isGallery = wasGallery
        }
        XCTAssertFalse(store.filesAreGone(gone), "an entry nobody has swept yet is not called dead")

        store.seedForGallery([alive, gone])
        // The sweep runs off the main thread and posts its answers back, so the run loop is
        // pumped until they land rather than for a guessed number of milliseconds: a slow disk
        // is a slower test, not a failed one, and a sweep that never lands is a failure here.
        let swept = XCTNSPredicateExpectation(predicate: NSPredicate(block: { _, _ in store.filesAreGone(gone) }),
                                              object: nil)
        wait(for: [swept], timeout: 5)
        XCTAssertTrue(store.filesAreGone(gone), "the file it pointed at has gone, so the row says so")
        XCTAssertFalse(store.filesAreGone(alive), "and the one that is still there is left alone")
    }

    /// `loadIfNeeded` is called by the delegate rather than from `init`, and reads once.
    ///
    /// A second launch asks the copy already running to quit, and that copy writes its history
    /// — everything copied in its last few seconds — on the way out. The whole history is one
    /// file, rewritten whole, so a new copy that read it again afterwards would hold the older
    /// copy's version of it and put that back, with those seconds gone and both files
    /// perfectly well-formed.
    func testTheHistoryOnDiskIsNeverPutBackOnTopOfWhatTheStoreIsHolding() throws {
        let previousOverride = IslandFiles.overrideFolder
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipboard-tests-\(UUID().uuidString)", isDirectory: true)
        let wasGallery = RenderMode.isGallery
        let store = ClipboardStore.shared
        IslandFiles.overrideFolder = folder
        RenderMode.isGallery = true
        defer {
            store.seedForGallery([])
            RenderMode.isGallery = wasGallery
            IslandFiles.overrideFolder = previousOverride
            try? FileManager.default.removeItem(at: folder)
        }

        // What the copy that is quitting left behind.
        try IslandFiles.write(try JSONEncoder().encode([item("what the last launch kept", at: 1)]),
                              to: "clipboard.json")
        // Nothing has been copied, so there is nothing to write: the half of this that loses
        // the last few seconds is the writing, not the reading.
        store.flush()
        XCTAssertEqual(try texts(inHistoryOf: folder), ["what the last launch kept"],
                       "a history nobody has copied into writes nothing over the file")

        // Once it is holding a history, the file is no longer its business.
        store.seedForGallery([item("already in hand", at: 2)])
        store.loadIfNeeded()
        XCTAssertEqual(store.items.map { $0.text }, ["already in hand"],
                       "a store that has its history does not read another one over it")

        // And having been handed one is not a change either, so nothing goes back the other way.
        store.flush()
        XCTAssertEqual(try texts(inHistoryOf: folder), ["what the last launch kept"],
                       "reading a history is not copying something, so the file is left as it was")
    }

    // MARK: - A history this build cannot read

    /// A folder of the test's own for the history, put back however the test ends.
    private func withHistoryFolder(_ body: (URL) throws -> Void) throws {
        let previousOverride = IslandFiles.overrideFolder
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipboard-readback-\(UUID().uuidString)", isDirectory: true)
        IslandFiles.overrideFolder = folder
        defer {
            IslandFiles.overrideFolder = previousOverride
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try body(folder)
    }

    func testAHistoryIsReadBackWithoutItsPictures() throws {
        try withHistoryFolder { _ in
            XCTAssertEqual(ClipboardStore.readHistory(), .missing, "no file yet is no history, and nothing moved")
            let kept = [item("kept", at: 1), item("Image", kind: .image, at: 2)]
            try IslandFiles.write(try JSONEncoder().encode(kept), to: "clipboard.json")
            XCTAssertEqual(ClipboardStore.readHistory(), .value([kept[0]]))
        }
    }

    /// A newer build that knows a kind of entry this one does not writes a file this one cannot
    /// read. It used to read as an empty history, and the next copy wrote that over the file.
    func testAHistoryThisBuildCannotReadIsMovedAsideRatherThanWrittenOver() throws {
        try withHistoryFolder { folder in
            let file = folder.appendingPathComponent("clipboard.json")
            let newer = Data(#"[{"id":"4C5A3F0E-8D9B-4E4C-9C43-1F2A6B7D8E90","kind":"colour","text":"red","date":0,"pinned":false}]"#.utf8)
            try newer.write(to: file)

            let when = Date(timeIntervalSince1970: 1_790_000_000)
            let name = IslandFiles.unreadableName(for: "clipboard.json", at: when)
            XCTAssertTrue(name.hasPrefix("clipboard.json.unreadable-"), name)
            XCTAssertEqual(ClipboardStore.readHistory(now: when), .unreadable(.moved(name)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                           "out of the way before anything can be saved over it")
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), newer, "kept byte for byte")
            XCTAssertEqual(ClipboardStore.readHistory(now: when), .missing, "and the history starts empty")

            // Another in the same second does not land on the first.
            try newer.write(to: file)
            XCTAssertEqual(ClipboardStore.readHistory(now: when), .unreadable(.moved(name + "-2")))
        }
    }

    /// The history as it really is on disk, for the tests that keep an eye on the file itself.
    private func texts(inHistoryOf folder: URL) throws -> [String] {
        let data = try Data(contentsOf: folder.appendingPathComponent("clipboard.json"))
        return try JSONDecoder().decode([ClipboardItem].self, from: data).map { $0.text }
    }

    func testOnlyEntriesThatPointAtFilesAreEverAskedAbout() {
        var picture = ClipboardItem(kind: .image, text: "Image")
        picture.imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let files = item("/tmp/one.txt\n/tmp/two.txt", kind: .file)
        let entries = ClipboardStore.fileEntries(in: [item("hello"),
                                                      item("https://example.com", kind: .url),
                                                      picture,
                                                      files])
        XCTAssertEqual(entries.map { $0.id }, [files.id], "text, links and pictures are answered from memory")
        XCTAssertEqual(entries.first?.urls.count, 2)
    }

    func testASetOfCopiedFilesIsGoneOnlyWhenEveryOneOfThemIs() {
        let one = URL(fileURLWithPath: "/tmp/one.txt")
        let two = URL(fileURLWithPath: "/tmp/two.txt")
        XCTAssertTrue(ClipboardStore.filesAreGone(urls: [one, two], exists: { _ in false }))
        XCTAssertFalse(ClipboardStore.filesAreGone(urls: [one, two], exists: { $0 == two }),
                       "one survivor is still worth putting back on the pasteboard")
        XCTAssertFalse(ClipboardStore.filesAreGone(urls: [], exists: { _ in false }),
                       "a copy that is not files at all is never dead")
    }

    func testTheAnswerIsKeptByEntryAndSurvivesTheHistoryBeingReadBack() throws {
        let gone = item("/tmp/gone.txt", kind: .file, at: 10)
        let there = item("/tmp/there.txt", kind: .file, at: 20)
        let answers: Set<UUID> = [gone.id]

        let reloaded = try JSONDecoder().decode([ClipboardItem].self,
                                                from: JSONEncoder().encode([gone, there]))
        XCTAssertEqual(ClipboardStore.pruned(answers, to: reloaded), answers,
                       "an entry's id goes to disk with it, so the answer still points at the same row")
        XCTAssertEqual(ClipboardStore.pruned(answers, to: [there]), Set<UUID>(),
                       "and an answer for an entry that has been deleted goes with it")
    }

    // MARK: - Pictures: what they weigh, and where they are made ready

    private func picture(_ label: String, bytes: Int, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(kind: .image, text: label, pinned: pinned, imageData: Data(count: bytes))
    }

    /// A little bitmap, `width` by `height`, as AppKit would put it on a pasteboard.
    private func bitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    }

    func testAPictureFitsOnlyWhileTheBudgetHasRoomForIt() {
        XCTAssertTrue(ClipboardStore.imageFits(bytes: 10, keptImageBytes: 50, budget: 64))
        XCTAssertTrue(ClipboardStore.imageFits(bytes: 14, keptImageBytes: 50, budget: 64), "filling it exactly still fits")
        XCTAssertFalse(ClipboardStore.imageFits(bytes: 15, keptImageBytes: 50, budget: 64))
    }

    /// Counted from the newest, the first picture that does not fit goes, and so does every
    /// picture older than it — even one small enough to have squeezed in — the way the ring
    /// buffer drops from the old end rather than picking holes in the middle.
    func testTheOldestPicturesGoOnceTheyArePastTheBudget() {
        let items = [picture("a", bytes: 30), item("t"), picture("b", bytes: 30), picture("c", bytes: 10),
                     picture("d", bytes: 2), item("u")]
        let kept = ClipboardStore.withinImageBudget(items, budget: 64)
        XCTAssertEqual(kept.map(\.text), ["a", "t", "b", "u"], "text is never taken for room")
    }

    func testTheNewestPictureStaysWhateverItWeighs() {
        let huge = picture("just copied", bytes: 100)
        XCTAssertEqual(ClipboardStore.withinImageBudget([huge], budget: 64).map(\.text), ["just copied"])
        XCTAssertEqual(ClipboardStore.withinImageBudget([huge, picture("older", bytes: 1)], budget: 64).map(\.text),
                       ["just copied"], "but it counts, and what is older makes way for it")
    }

    func testAPinnedPictureIsNeverTakenForRoomButCountsAllTheSame() {
        let items = [picture("new", bytes: 40), picture("pinned", bytes: 40, pinned: true), picture("old", bytes: 1)]
        XCTAssertEqual(ClipboardStore.withinImageBudget(items, budget: 64).map(\.text), ["new", "pinned"])
    }

    func testAHistoryWithNoPicturesIsLeftAlone() {
        let items = [item("a", at: 2), item("b", at: 1), item("https://example.com", kind: .url)]
        XCTAssertEqual(ClipboardStore.withinImageBudget(items, budget: 0), items)
    }

    /// The budget is part of what "fits" means everywhere the list is capped — a copy, a
    /// lowered limit and an Undo Clear — so a new copy takes the oldest picture with it.
    func testCappingTheListKeepsItToTheBudgetToo() {
        XCTAssertEqual(ClipboardStore.capped([picture("new", bytes: 40), picture("old", bytes: 40)],
                                             limit: 10, imageBudget: 64).map(\.text), ["new"])
        let half = ClipboardStore.imageBudget / 2 + 1
        let history = ClipboardStore.inserting(picture("new", bytes: half), into: [picture("old", bytes: half)], limit: 50)
        XCTAssertEqual(history.map(\.text), ["new"], "a copy is held to the real budget")
    }

    /// A picture offered only as TIFF is kept as PNG, and its size comes out of the header.
    /// Both used to be done on the main thread, by decoding the whole picture to count it.
    func testATIFFIsKeptAsAPNGAndMeasuredFromItsHeader() throws {
        let tiff = try XCTUnwrap(try bitmap(width: 12, height: 7).tiffRepresentation)
        let ready = ClipboardStore.finishingImage(ClipboardSnapshot(types: ["public.tiff"], tiffData: tiff))
        let png = try XCTUnwrap(ready.imageData)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "kept as PNG")
        XCTAssertNil(ready.tiffData, "the TIFF is not held on to once it has been turned")
        XCTAssertEqual(ready.imagePixelSize, CGSize(width: 12, height: 7))
        XCTAssertEqual(ClipboardStore.item(from: ready)?.preview, "Image 12 × 7")
    }

    func testAPNGIsKeptAsItCameAndMeasuredWithoutBeingDecoded() throws {
        let png = try XCTUnwrap(try bitmap(width: 30, height: 20).representation(using: .png, properties: [:]))
        XCTAssertEqual(ClipboardStore.pixelSize(of: png), CGSize(width: 30, height: 20))
        let ready = ClipboardStore.finishingImage(ClipboardSnapshot(types: ["public.png"], imageData: png))
        XCTAssertEqual(ready.imageData, png, "the bytes on the pasteboard are the bytes kept")
        XCTAssertEqual(ready.imagePixelSize, CGSize(width: 30, height: 20))
    }

    func testBytesThatAreNotAPictureAreNotRecordedAsOne() {
        let ready = ClipboardStore.finishingImage(ClipboardSnapshot(types: ["public.png"], imageData: Data([1, 2, 3])))
        XCTAssertNil(ready.imageData)
        XCTAssertNil(ClipboardStore.item(from: ready), "nothing to show, so nothing is recorded")
    }

    /// A copy through conversion waits in `Arrivals` for whichever takes it first: its own hop
    /// to the main queue, or a `flush` at quit, where that hop is queued behind `terminate` and
    /// never runs. Whichever it is, the copies come out in the order they were made, once.
    func testCopiesThroughConversionAreHandedOverInOrderAndOnce() {
        let arrivals = ClipboardStore.Arrivals()
        XCTAssertEqual(arrivals.takeAll(), [], "nothing through yet")
        let first = item("copied first", at: 1)
        let second = item("copied second", at: 2)
        arrivals.add(first)
        arrivals.add(second)
        XCTAssertEqual(arrivals.takeAll().map(\.text), ["copied first", "copied second"])
        XCTAssertEqual(arrivals.takeAll(), [], "the hop that comes after a flush finds nothing left to add twice")
    }

    /// Added on the conversion queue and taken on the main thread, as the store does: nothing is
    /// lost between them and nothing reordered.
    func testCopiesAddedOnOneQueueAreAllTakenOnAnother() {
        let arrivals = ClipboardStore.Arrivals()
        let converter = DispatchQueue(label: "clipboard-arrivals-test")
        var taken: [String] = []
        for index in 0..<200 {
            let copy = item("copy \(index)", at: TimeInterval(index))
            converter.async { arrivals.add(copy) }
            if index % 17 == 0 { taken += arrivals.takeAll().map(\.text) }
        }
        converter.sync {}
        taken += arrivals.takeAll().map(\.text)
        XCTAssertEqual(taken, (0..<200).map { "copy \($0)" })
    }
}
