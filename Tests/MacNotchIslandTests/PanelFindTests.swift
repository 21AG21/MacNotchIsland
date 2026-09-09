import XCTest
@testable import MacNotchIsland

/// Type-to-find: which sections take the letters, what counts as a match, and how a find
/// begins and ends.
final class PanelFindTests: XCTestCase {
    private var center: ActivityCenter { ActivityCenter.shared }

    override func setUp() {
        super.setUp()
        center.resetForTesting()
        let p = Preferences.shared
        p.panelKeysEnabled = true
        HomeSection.allCases.forEach { $0.setEnabled(true, in: p) }
    }

    override func tearDown() {
        center.resetForTesting()
        super.tearDown()
    }

    // MARK: - The rule

    func testOnlyTheSectionsThatAreListsTakeTheLetters() {
        for section in [HomeSection.windows, .clipboard, .shelf] {
            XCTAssertTrue(PanelFind.searches(section), "\(section) is a list of things")
        }
        for section in [HomeSection.music, .today, .actions, .notes, .stats] {
            XCTAssertFalse(PanelFind.searches(section), "\(section) is not a list to look through")
        }
        XCTAssertFalse(PanelFind.searches(nil), "nothing is open")
    }

    func testNoQueryMatchesEverything() {
        XCTAssertTrue(PanelFind.matches(["Mail"], query: nil))
        XCTAssertTrue(PanelFind.matches(["Mail"], query: ""))
        XCTAssertTrue(PanelFind.matches(["Mail"], query: "   "), "spaces are not a search")
    }

    func testAnyFieldWillDo() {
        // Half the time what you want is "the other Safari one", so the app's name finds it
        // as readily as the title does.
        XCTAssertTrue(PanelFind.matches(["Safari", "Notch Island — Design"], query: "saf"))
        XCTAssertTrue(PanelFind.matches(["Safari", "Notch Island — Design"], query: "design"))
        XCTAssertFalse(PanelFind.matches(["Safari", "Notch Island — Design"], query: "mail"))
    }

    func testTheComparisonIsTheOneTheRestOfTheMacUses() {
        XCTAssertTrue(PanelFind.matches(["MAIL"], query: "mail"), "case is not part of it")
        XCTAssertTrue(PanelFind.matches(["Café Terrace"], query: "cafe"), "nor are the accents")
    }

    func testOnlyALetterOpensAFind() {
        XCTAssertTrue(PanelFind.opensFind("m"))
        XCTAssertTrue(PanelFind.opensFind("é"))
        XCTAssertFalse(PanelFind.opensFind("4"), "the digits go to the switcher")
        XCTAssertFalse(PanelFind.opensFind(" "), "Space plays and pauses")
        XCTAssertFalse(PanelFind.opensFind(""))
        XCTAssertFalse(PanelFind.opensFind("ma"), "one key, one character")
    }

    // MARK: - Beginning and ending

    func testTypingOnAListOpensTheField() {
        center.open(.home(tab: HomeSection.windows.rawValue))
        center.beginFind(with: "m")
        XCTAssertEqual(center.findQuery, "m")
        center.updateFind("ma")
        XCTAssertEqual(center.findQuery, "ma")
    }

    func testTypingOnAnythingElseIsLeftAlone() {
        center.open(.home(tab: HomeSection.music.rawValue))
        center.beginFind(with: "m")
        XCTAssertNil(center.findQuery, "the letters were never claimed here")
    }

    func testTheGlassOpensAnEmptyField() {
        center.open(.home(tab: HomeSection.shelf.rawValue))
        center.beginFind()
        XCTAssertEqual(center.findQuery, "")
        // A second click is not a second field: the caret is already in the first one.
        center.updateFind("re")
        center.beginFind()
        XCTAssertEqual(center.findQuery, "re")
    }

    func testAFindAsksForTheKeyboardAndGivesItBack() {
        center.open(.home(tab: HomeSection.clipboard.rawValue))
        XCTAssertFalse(center.wantsKeyboard, "the clipboard is a list until somebody starts typing")
        XCTAssertTrue(center.panelKeysActive, "so the arrows and the digits are the island's")
        center.beginFind(with: "a")
        XCTAssertTrue(center.wantsKeyboard, "the field needs the keys the island was holding")
        XCTAssertFalse(center.panelKeysActive)
        XCTAssertTrue(center.endFind())
        XCTAssertFalse(center.wantsKeyboard)
        XCTAssertTrue(center.panelKeysActive)
    }

    func testEscapeLeavesTheFindBeforeItClosesThePanel() {
        center.open(.home(tab: HomeSection.windows.rawValue))
        XCTAssertFalse(center.endFind(), "nothing to leave, so Escape closes the panel instead")
        center.beginFind(with: "m")
        XCTAssertTrue(center.endFind(), "Escape spent itself on the find")
        XCTAssertNotNil(center.openView, "and the panel stayed where it was")
    }

    func testAFindBelongsToTheListItWasTypedInto() {
        center.open(.home(tab: HomeSection.windows.rawValue))
        center.beginFind(with: "m")
        center.open(.home(tab: HomeSection.shelf.rawValue))
        XCTAssertNil(center.findQuery, "stepping to the next section starts again")
        center.beginFind(with: "r")
        center.collapse(reason: "test")
        XCTAssertNil(center.findQuery, "and closing the panel takes it with it")
    }

    func testNotesStillOwnsEveryKeyItself() {
        center.open(.home(tab: HomeSection.notes.rawValue))
        XCTAssertTrue(center.wantsKeyboard)
        XCTAssertFalse(center.panelKeysActive)
        center.beginFind(with: "m")
        XCTAssertNil(center.findQuery, "a letter typed in the scratchpad is part of the note")
    }

    // MARK: - What the sections show

    func testTheClipboardKeepsItsPinnedRowsFirstWhileItNarrows() {
        let now = Date()
        let items = [
            ClipboardItem(kind: .text, text: "Rosebery Avenue", date: now),
            ClipboardItem(kind: .url, text: "https://developer.apple.com", date: now.addingTimeInterval(-60), pinned: true),
        ]
        let all = ClipboardView.ordered(items, query: nil)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all[0].pinned, "pinned rows come first whatever the search")
        let found = ClipboardView.ordered(items, query: "apple")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .url)
        XCTAssertTrue(ClipboardView.ordered(items, query: "zzz").isEmpty)
    }

    func testAWindowIsFoundByItsAppOrItsTitle() {
        let windows = WindowsSectionView.sampleWindows
        func names(_ query: String) -> [String] {
            windows.filter { PanelFind.matches([$0.appName, $0.label], query: query) }.map(\.appName)
        }
        XCTAssertEqual(names("ma"), ["Mail"])
        XCTAssertEqual(names("design"), ["Safari"], "found by what the window is showing")
        XCTAssertEqual(names("island"), ["Xcode", "Safari"], "a word in two of them finds both")
        XCTAssertTrue(names("zzz").isEmpty)
    }
}
