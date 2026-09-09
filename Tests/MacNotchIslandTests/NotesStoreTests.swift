import XCTest
@testable import MacNotchIsland

/// The scratchpad is written eight tenths of a second after the last keystroke, and a quit
/// from the menu bar is quicker than that. These pin down the flush that closes the gap.
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

    func testAScratchpadNobodyTouchedWritesNothing() {
        NotesStore.shared.text = "touched"
        NotesStore.shared.flush()
        try? FileManager.default.removeItem(at: file)
        // Nothing is waiting now, so the flush on the way out has nothing to write and does
        // not put a file back for a feature that is not in use.
        NotesStore.shared.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
