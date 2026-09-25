import XCTest
@testable import MacNotchIsland

/// The scratchpad is written eight tenths of a second after the last keystroke, and a quit
/// from the menu bar is quicker than that. These pin down the flush that closes the gap — and
/// the ways a scratchpad used to go without a word: a write that failed, a folder that could
/// not be made, and a file that could not be read and was written over.
final class NotesStoreTests: XCTestCase {
    private var folder: URL!
    private var previousOverride: URL?
    private var previousText: String = ""

    private var file: URL { folder.appendingPathComponent("notes.txt") }

    override func setUp() {
        super.setUp()
        previousOverride = IslandFiles.overrideFolder
        previousText = NotesStore.shared.text
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notes-tests-\(UUID().uuidString)", isDirectory: true)
        IslandFiles.overrideFolder = folder
        // The store is a singleton, so each test starts from an empty scratchpad with no
        // standing offer to take a Clear back.
        NotesStore.shared.text = ""
        NotesStore.shared.clear()
    }

    override func tearDown() {
        // Put the scratchpad back and flush inside the override, so no delayed write is left
        // pointing at the real folder once the override goes away.
        NotesStore.shared.text = previousText
        NotesStore.shared.flush()
        IslandFiles.overrideFolder = previousOverride
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testTheLastSentenceSurvivesAQuit() throws {
        NotesStore.shared.text = "half a thought"
        // Still waiting: the write is most of a second away.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        NotesStore.shared.flush()
        let written = try XCTUnwrap(String(data: Data(contentsOf: file), encoding: .utf8))
        XCTAssertEqual(written, "half a thought")
    }

    func testClearingTheScratchpadIsSavedToo() throws {
        NotesStore.shared.text = "something to forget"
        NotesStore.shared.flush()
        NotesStore.shared.clear()
        NotesStore.shared.flush()
        // Not the old text: an emptied scratchpad that came back on the next launch would be
        // the same bug the other way round.
        XCTAssertEqual(try String(data: Data(contentsOf: file), encoding: .utf8), "")
    }

    // MARK: - Taking a Clear back

    func testClearCanBeUndone() {
        NotesStore.shared.text = "a week of jottings"
        NotesStore.shared.clear()
        XCTAssertEqual(NotesStore.shared.text, "")
        XCTAssertEqual(NotesStore.shared.clearedText, "a week of jottings")
        NotesStore.shared.undoClear()
        XCTAssertEqual(NotesStore.shared.text, "a week of jottings")
        XCTAssertNil(NotesStore.shared.clearedText, "the offer is spent once it is taken")
    }

    func testClearingAnEmptyScratchpadOffersNothing() {
        NotesStore.shared.text = ""
        NotesStore.shared.clear()
        XCTAssertNil(NotesStore.shared.clearedText)
    }

    func testUndoNeverOverwritesSomethingTypedSince() {
        NotesStore.shared.text = "the old note"
        NotesStore.shared.clear()
        NotesStore.shared.text = "a new one"
        NotesStore.shared.undoClear()
        XCTAssertEqual(NotesStore.shared.text, "a new one")
    }

    // MARK: - Reading it back at launch

    /// The scratchpad is read when the delegate says so and never from `init`, and it is read
    /// once. A second launch asks the copy already running to quit, and that copy writes its
    /// last save on the way out; a new copy that had read the file before that landed would
    /// hold the old text and write it straight back over the new one.
    ///
    /// This is the only call to `loadIfNeeded` in the suite and has to stay that way: the store
    /// is a singleton that cannot be un-read, so a second one anywhere else would quietly turn
    /// the middle of this test into a test of nothing.
    func testTheScratchpadIsReadBackOnceAndLeftAloneUntilItIs() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Whatever `setUp` left waiting is written now, so what follows is a store with
        // nothing of its own to say — a copy that has only just started up.
        NotesStore.shared.flush()
        try Data("a week of jottings".utf8).write(to: file)

        NotesStore.shared.flush()
        XCTAssertEqual(try String(data: Data(contentsOf: file), encoding: .utf8), "a week of jottings",
                       "a scratchpad that has not been read is not a scratchpad to write out")

        NotesStore.shared.loadIfNeeded()
        XCTAssertEqual(NotesStore.shared.text, "a week of jottings", "and it is read when it is asked for")

        // A second call is not a second read — and the file changing underneath is exactly what
        // the copy being replaced is doing while this one starts.
        try Data("what the older copy wrote on its way out".utf8).write(to: file)
        NotesStore.shared.text = "typed since"
        NotesStore.shared.loadIfNeeded()
        XCTAssertEqual(NotesStore.shared.text, "typed since",
                       "what is in front of the user is never replaced by what is on disk")
    }

    func testAScratchpadNobodyTouchedWritesNothing() {
        NotesStore.shared.text = "touched"
        NotesStore.shared.flush()
        try? FileManager.default.removeItem(at: file)
        // Nothing is waiting now, so the flush on the way out has nothing to write and does
        // not put a file back for a feature that is not in use.
        NotesStore.shared.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - A write that does not land

    /// A file where the folder should be. Nothing can be made or written under it by anybody
    /// who runs the suite — root included, which a folder with its permissions taken away
    /// would not stop.
    private func blockedFolder() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appendingPathComponent("in-the-way")
        try Data("x".utf8).write(to: blocker)
        return blocker
    }

    func testAFailedSaveIsSaidAndWhatWasTypedWaitsForTheNextOne() throws {
        IslandFiles.overrideFolder = try blockedFolder().appendingPathComponent("support", isDirectory: true)
        defer { IslandFiles.overrideFolder = folder }

        NotesStore.shared.text = "a thought with nowhere to go"
        NotesStore.shared.flush()
        let reason = try XCTUnwrap(NotesStore.shared.saveFailed, "a write that failed says so")
        XCTAssertFalse(reason.isEmpty)

        // The disk comes back. The next flush — the pill's click, or the quit — still has the
        // text to write, and the pill goes once it lands.
        IslandFiles.overrideFolder = folder
        NotesStore.shared.flush()
        XCTAssertNil(NotesStore.shared.saveFailed)
        XCTAssertEqual(try String(data: Data(contentsOf: file), encoding: .utf8), "a thought with nowhere to go")
    }

    func testAFolderThatCannotBeMadeIsReportedRatherThanHandedBack() throws {
        IslandFiles.overrideFolder = try blockedFolder()
        defer { IslandFiles.overrideFolder = folder }
        XCTAssertNil(IslandFiles.makeFolder(), "a path with a file at it is not a folder")
        XCTAssertNil(IslandFiles.makeFolder("Shelf"))
        XCTAssertThrowsError(try IslandFiles.prepareFolder())
        XCTAssertThrowsError(try IslandFiles.write(Data("x".utf8), to: "notes.txt"))

        IslandFiles.overrideFolder = folder
        XCTAssertEqual(IslandFiles.makeFolder(), folder, "and one that can be made still is")
    }

    func testTheReasonIsTheFewWordsAPillHasRoomFor() {
        XCTAssertEqual(NotesStore.saveFailedReason(for: CocoaError(.fileWriteOutOfSpace)), "Disk full")
        XCTAssertEqual(NotesStore.saveFailedReason(for: POSIXError(.ENOSPC)), "Disk full")
        XCTAssertEqual(NotesStore.saveFailedReason(for: CocoaError(.fileWriteVolumeReadOnly)), "Disk is read-only")
        XCTAssertEqual(NotesStore.saveFailedReason(for: CocoaError(.fileWriteNoPermission)), "No permission")
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES) as NSError])
        XCTAssertEqual(NotesStore.saveFailedReason(for: wrapped), "No permission",
                       "the system's own answer, under Foundation's")
        XCTAssertEqual(NotesStore.saveFailedReason(for: URLError(.unknown)), "Could not write")
        XCTAssertLessThanOrEqual(NotesStore.heldBackReason.count, 20, "a pill, not a sentence")
    }

    // MARK: - A scratchpad that cannot be read

    func testAScratchpadThatIsTextIsReadAsItIsAndLeftWhereItIs() throws {
        XCTAssertEqual(NotesStore.readScratchpad(), .text(""), "no scratchpad yet is an empty one")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("café, and a list".utf8).write(to: file)
        XCTAssertEqual(NotesStore.readScratchpad(), .text("café, and a list"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["notes.txt"],
                       "nothing set aside")
    }

    /// Saved from another editor in Latin-1, say. It used to read as an empty scratchpad, and
    /// the first keystroke wrote that over it.
    func testAScratchpadThatIsNotUTF8IsMovedAsideRatherThanWrittenOver() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = try XCTUnwrap("Café au lait, and the rest of the week".data(using: .isoLatin1))
        XCTAssertNil(String(data: bytes, encoding: .utf8), "the premise: this is not UTF-8")
        try bytes.write(to: file)

        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let name = NotesStore.unreadableName(at: when)
        XCTAssertEqual(NotesStore.readScratchpad(now: when), .setAside(name))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "out of the way before anything can be typed over it")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), bytes, "kept byte for byte")
        XCTAssertEqual(NotesStore.readScratchpad(now: when), .text(""), "and the scratchpad starts empty")

        // Another in the same second does not land on the first.
        try bytes.write(to: file)
        XCTAssertEqual(NotesStore.readScratchpad(now: when), .setAside(name + "-2"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), bytes)
    }

    func testTheNameItIsKeptUnderSaysWhatItWasAndWhen() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(NotesStore.unreadableName(at: Date(timeIntervalSince1970: 0), timeZone: utc),
                       "notes.txt.unreadable-1970-01-01-000000")
    }
}
