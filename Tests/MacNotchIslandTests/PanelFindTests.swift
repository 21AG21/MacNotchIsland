import AppKit
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
        for section in [HomeSection.windows, .clipboard, .shelf, .notifications] {
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
        // The live rule, asked with the keyboard held. `panelKeysActive` would answer for the
        // real app, but a test run has no key window, so it is false throughout and would pin
        // nothing about the find. Everything else here is the island's actual state.
        func claimed() -> Bool {
            HotKeyService.claim(pinnedOpen: center.openView != nil,
                                holdsKeyboard: true,
                                textFieldUp: center.wantsKeyboard,
                                listSection: PanelFind.searches(center.openSection),
                                enabled: true).bareKeys
        }
        center.open(.home(tab: HomeSection.clipboard.rawValue))
        XCTAssertFalse(center.wantsKeyboard, "the clipboard is a list until somebody starts typing")
        XCTAssertTrue(claimed(), "so the arrows and the digits are the island's")
        center.beginFind(with: "a")
        XCTAssertTrue(center.wantsKeyboard, "the field needs the keys the island was holding")
        XCTAssertFalse(claimed())
        XCTAssertTrue(center.endFind())
        XCTAssertFalse(center.wantsKeyboard)
        XCTAssertTrue(claimed())
    }

    func testTheIslandAdvertisesNoKeyItHasNotActuallyClaimed() {
        // `panelKeysActive` is what puts a slot's number beside its name in the switcher. It
        // now answers the whole question, key status included, so the digits are never offered
        // while the keyboard still belongs to the app in front — an offer the island could not
        // have honoured, made to somebody typing somewhere else.
        center.open(.home(tab: HomeSection.clipboard.rawValue))
        XCTAssertFalse(center.holdsKeyboard, "nothing is the key window in a test run")
        XCTAssertFalse(center.panelKeysActive)
    }

    func testAPinnedPanelAsksForTheKeyboardAndAPeekDoesNot() {
        // Holding the keyboard is what makes the claim honest, so a pinned panel asks for it.
        // A peek follows the pointer and takes nothing.
        center.open(.home(tab: HomeSection.clipboard.rawValue))
        XCTAssertTrue(center.wantsPanelKeyboard)
        center.collapse(reason: "test")
        XCTAssertFalse(center.wantsPanelKeyboard)
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
        // Asked of the rule with the keyboard held. `panelKeysActive` is false on the
        // scratchpad and false everywhere else in a test run, because nothing is ever the key
        // window here, so asking it pins nothing about the scratchpad.
        XCTAssertEqual(HotKeyService.claim(pinnedOpen: true,
                                          holdsKeyboard: true,
                                          textFieldUp: center.wantsKeyboard,
                                          listSection: PanelFind.searches(center.openSection),
                                          enabled: true),
                       .nothing,
                       "a key taken as a hot key never reaches the note it was typed into")
        center.beginFind(with: "m")
        XCTAssertNil(center.findQuery, "a letter typed in the scratchpad is part of the note")
    }

    // MARK: - When one of our own windows has the keyboard

    /// The island wants the keyboard whenever the panel is pinned, and asks for it again on
    /// every published change. Taking it back off Settings left a window with a dead title bar
    /// that would not accept a keystroke and no way out of it, because none of the three
    /// things that close the panel fire for our own windows; Space on the shelf did the same
    /// to Quick Look. Wanting the keyboard is not being owed it by our own windows.
    func testTheIslandLeavesTheKeyboardWithWhicheverOfOurOwnWindowsHasIt() {
        XCTAssertFalse(NotchPanel.holdsKeyboardElsewhere([]),
                       "no windows at all, so nobody is holding it")
        XCTAssertFalse(NotchPanel.holdsKeyboardElsewhere([(isKey: true, isPanel: true)]),
                       "an island panel holding the keyboard is the island holding it")
        XCTAssertTrue(NotchPanel.holdsKeyboardElsewhere([(isKey: true, isPanel: false)]),
                      "Settings, or a Quick Look panel: the island must not take it straight back")
        XCTAssertTrue(NotchPanel.holdsKeyboardElsewhere([(isKey: true, isPanel: true),
                                                         (isKey: true, isPanel: false)]),
                      "and a panel of ours being key as well is no licence to take it")
        XCTAssertFalse(NotchPanel.holdsKeyboardElsewhere([(isKey: false, isPanel: false),
                                                          (isKey: false, isPanel: true)]),
                       "a window that is not key is not holding the keyboard")
    }

    // MARK: - Walking the matches

    func testTheArrowsWalkTheMatchesAndWrapAtBothEnds() {
        center.open(.home(tab: HomeSection.windows.rawValue))
        center.beginFind(with: "e")
        XCTAssertEqual(center.findTarget(of: 3), 0, "a find starts on the first of them")
        center.moveFind(by: 1, count: 3)
        XCTAssertEqual(center.findTarget(of: 3), 1)
        center.moveFind(by: 1, count: 3)
        center.moveFind(by: 1, count: 3)
        XCTAssertEqual(center.findTarget(of: 3), 0, "past the end is the top again")
        center.moveFind(by: -1, count: 3)
        XCTAssertEqual(center.findTarget(of: 3), 2, "and back off the top is the bottom")
    }

    func testTypingStartsTheWalkAgain() {
        center.open(.home(tab: HomeSection.windows.rawValue))
        center.beginFind(with: "e")
        center.moveFind(by: 2, count: 5)
        XCTAssertEqual(center.findTarget(of: 5), 2)
        center.updateFind("ex")
        XCTAssertEqual(center.findTarget(of: 5), 0, "a narrower list is walked from the top")
    }

    func testTheMarkNeverPointsPastTheEndOfAListThatShrank() {
        center.open(.home(tab: HomeSection.windows.rawValue))
        center.beginFind(with: "e")
        center.moveFind(by: 4, count: 5)
        XCTAssertEqual(center.findTarget(of: 5), 4)
        XCTAssertEqual(center.findTarget(of: 2), 1, "brought back to the last row there is")
        XCTAssertNil(center.findTarget(of: 0), "and nothing at all points nowhere")
    }

    func testThereIsNoMarkWithoutAFind() {
        center.open(.home(tab: HomeSection.windows.rawValue))
        XCTAssertNil(center.findTarget(of: 4))
        center.moveFind(by: 1, count: 4)
        XCTAssertEqual(center.findIndex, 0, "the arrows are the panel's until a find takes them")
    }

    func testWrappingIsSoundForAnythingItIsGiven() {
        XCTAssertEqual(ActivityCenter.wrapped(0, count: 3), 0)
        XCTAssertEqual(ActivityCenter.wrapped(-1, count: 3), 2)
        XCTAssertEqual(ActivityCenter.wrapped(-4, count: 3), 2)
        XCTAssertEqual(ActivityCenter.wrapped(7, count: 3), 1)
        XCTAssertEqual(ActivityCenter.wrapped(5, count: 0), 0, "no rows, no division by zero")
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
