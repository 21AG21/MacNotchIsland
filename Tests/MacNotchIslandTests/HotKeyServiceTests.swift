import XCTest
import AppKit
import Carbon
@testable import MacNotchIsland

/// Exercises the pure parts of HotKeyService: how a stored combo is rendered for the settings
/// row, and how AppKit's modifier flags become the Carbon masks RegisterEventHotKey wants.
final class HotKeyServiceTests: XCTestCase {
    // Carbon masks, spelled out so a change to the mapping shows up here.
    private let cmd = 256
    private let shift = 512
    private let option = 2048
    private let control = 4096

    // MARK: displayString

    func testDefaultComboReadsAsControlOptionSpace() {
        XCTAssertEqual(HotKeyService.displayString(keyCode: 49, carbonModifiers: control | option), "⌃⌥Space")
    }

    func testDefaultsMatchThePreferenceDefaults() {
        XCTAssertEqual(HotKeyService.defaultKeyCode, 49)
        XCTAssertEqual(HotKeyService.defaultModifiers, 6144)
        XCTAssertEqual(HotKeyService.displayString(keyCode: HotKeyService.defaultKeyCode,
                                                   carbonModifiers: HotKeyService.defaultModifiers),
                       "⌃⌥Space")
    }

    // MARK: - macOS's own shortcuts

    /// One entry of `CopySymbolicHotKeys`'s list, as the rule reads it.
    private func symbolic(_ code: Int, _ modifiers: Int, enabled: Bool) -> [String: Any] {
        [HotKeyService.symbolicCodeKey: code,
         HotKeyService.symbolicModifiersKey: modifiers,
         HotKeyService.symbolicEnabledKey: enabled]
    }

    /// With two input sources, ⌃⌥Space is "Select next source in Input menu". Registration
    /// said yes to it, so nothing ever said the shipping shortcut was macOS's.
    func testTheInputMenuShortcutIsSeenAsTaken() {
        let inputMenu = [symbolic(49, control | option, enabled: true)]
        XCTAssertTrue(HotKeyService.systemConflict(keyCode: 49, modifiers: control | option, symbolic: inputMenu))
        XCTAssertFalse(HotKeyService.systemConflict(keyCode: 49, modifiers: control, symbolic: inputMenu),
                       "a different set of modifiers is a different shortcut")
        XCTAssertFalse(HotKeyService.systemConflict(keyCode: 34, modifiers: control | option, symbolic: inputMenu),
                       "and so is a different key")
        XCTAssertFalse(HotKeyService.systemConflict(keyCode: 49, modifiers: control | option, symbolic: []),
                       "nothing listed, nothing taken")
    }

    /// macOS lists the input menu's shortcuts switched on whether there is one source to
    /// choose from or ten, and with one they take nothing. Read as taken, a Mac with one
    /// keyboard layout was moved to ⌃⌥I, and moved back at the next launch after a second
    /// source was added — or the other way about.
    func testTheInputMenuTakesNothingWithOneKeyboardSource() {
        let inputMenu = [symbolic(49, control, enabled: true), symbolic(49, control | option, enabled: true)]
        XCTAssertFalse(HotKeyService.inputMenuSwitches(keyboardSources: 1))
        XCTAssertFalse(HotKeyService.inputMenuSwitches(keyboardSources: 0), "a list that could not be read")
        XCTAssertTrue(HotKeyService.inputMenuSwitches(keyboardSources: 2))

        XCTAssertFalse(HotKeyService.systemTakes(keyCode: 49, modifiers: control | option, symbolic: inputMenu,
                                                 keyboardSources: 1), "nothing to switch to: ⌃⌥Space is free")
        XCTAssertFalse(HotKeyService.systemTakes(keyCode: 49, modifiers: control, symbolic: inputMenu,
                                                 keyboardSources: 1), "and so is ⌃Space")
        XCTAssertTrue(HotKeyService.systemTakes(keyCode: 49, modifiers: control | option, symbolic: inputMenu,
                                                keyboardSources: 2), "two sources: the input menu has it")
        XCTAssertTrue(HotKeyService.systemTakes(keyCode: 49, modifiers: (1 << 18) | (1 << 19), symbolic: inputMenu,
                                                keyboardSources: 2), "in either spelling")
        let spotlight = [symbolic(49, cmd, enabled: true)]
        XCTAssertTrue(HotKeyService.systemTakes(keyCode: 49, modifiers: cmd, symbolic: spotlight, keyboardSources: 1),
                      "every other shortcut of the system's is taken as it is listed")
        XCTAssertFalse(HotKeyService.isInputMenuCombination(keyCode: 34, modifiers: control | option))
        XCTAssertFalse(HotKeyService.isInputMenuCombination(keyCode: 49, modifiers: control | option | shift))

        let one = HotKeyService.shippingDefault(symbolic: inputMenu, keyboardSources: 1, character: TestLayout.us)
        XCTAssertEqual(one.keyCode, HotKeyService.defaultKeyCode, "one layout keeps the shortcut the README names")
        XCTAssertEqual(one.modifiers, HotKeyService.defaultModifiers)
        let two = HotKeyService.shippingDefault(symbolic: inputMenu, keyboardSources: 2, character: TestLayout.us)
        XCTAssertEqual(two.keyCode, HotKeyService.fallbackKeyCode)
        XCTAssertEqual(two.modifiers, HotKeyService.fallbackModifiers)
    }

    /// Whatever the shortcut starts at, it is written down the first time the app runs, so an
    /// input source added or taken away later cannot move it at the next launch.
    func testTheShippingShortcutIsWrittenDownOnce() {
        var asked = 0
        // What this Mac would ship with, standing in for its input sources.
        func shipping() -> (keyCode: Int, modifiers: Int) {
            asked += 1
            return (keyCode: HotKeyService.fallbackKeyCode, modifiers: HotKeyService.fallbackModifiers)
        }

        // Nothing stored: the shipping pair is used, and written down.
        let first = Preferences.startingShortcut(stored: nil, shipping: shipping())
        XCTAssertEqual(first.keyCode, Double(HotKeyService.fallbackKeyCode))
        XCTAssertEqual(first.modifiers, Double(HotKeyService.fallbackModifiers))
        XCTAssertTrue(first.writes)
        XCTAssertEqual(asked, 1)

        // The next launch finds it stored: kept, not written again, and the Mac not asked.
        let next = Preferences.startingShortcut(stored: (keyCode: first.keyCode, modifiers: first.modifiers),
                                                shipping: shipping())
        XCTAssertEqual(next.keyCode, first.keyCode)
        XCTAssertEqual(next.modifiers, first.modifiers)
        XCTAssertFalse(next.writes)
        XCTAssertEqual(asked, 1, "a stored shortcut does not ask what this Mac would ship with")

        // One recorded by hand is kept the same way, whatever the Mac would ship with now.
        let recorded = Preferences.startingShortcut(stored: (keyCode: 0, modifiers: Double(cmd | shift)),
                                                    shipping: shipping())
        XCTAssertEqual(recorded.keyCode, 0)
        XCTAssertEqual(recorded.modifiers, Double(cmd | shift))
        XCTAssertFalse(recorded.writes)
        XCTAssertEqual(asked, 1)

        // And the app, having started, has both written down.
        _ = Preferences.shared
        XCTAssertNotNil(UserDefaults.standard.object(forKey: "hotkeyKeyCode"))
        XCTAssertNotNil(UserDefaults.standard.object(forKey: "hotkeyModifiers"))
    }

    func testASystemShortcutThatIsSwitchedOffTakesNothing() {
        let off = [symbolic(49, control | option, enabled: false)]
        XCTAssertFalse(HotKeyService.systemConflict(keyCode: 49, modifiers: control | option, symbolic: off))
        let unreadable: [[String: Any]] = [[HotKeyService.symbolicCodeKey: 49]]
        XCTAssertFalse(HotKeyService.systemConflict(keyCode: 49, modifiers: control | option, symbolic: unreadable),
                       "an entry that does not say it is on is not counted as on")
    }

    func testSymbolicModifiersAreReadInEitherSpelling() {
        // Carbon's masks as they are, and AppKit's device-independent flags turned into them:
        // ⌃ is 1 << 18 and ⌥ is 1 << 19 there. Caps Lock and Fn are not part of a combination.
        XCTAssertEqual(HotKeyService.carbonModifiers(symbolic: control | option), control | option)
        XCTAssertEqual(HotKeyService.carbonModifiers(symbolic: (1 << 18) | (1 << 19)), control | option)
        XCTAssertEqual(HotKeyService.carbonModifiers(symbolic: (1 << 17) | (1 << 20)), shift | cmd)
        XCTAssertEqual(HotKeyService.carbonModifiers(symbolic: (1 << 18) | (1 << 23)), control, "Fn is dropped")
        let appKitSpelling = [symbolic(49, (1 << 18) | (1 << 19), enabled: true)]
        XCTAssertTrue(HotKeyService.systemConflict(keyCode: 49, modifiers: control | option, symbolic: appKitSpelling))
    }

    /// A Mac where macOS has ⌃⌥Space starts on ⌃⌥I, which the tour then names.
    func testTheShippingShortcutStepsAsideForTheSystem() {
        let free = HotKeyService.shippingDefault(symbolic: [], keyboardSources: 2, character: TestLayout.us)
        XCTAssertEqual(free.keyCode, HotKeyService.defaultKeyCode)
        XCTAssertEqual(free.modifiers, HotKeyService.defaultModifiers)

        let taken = HotKeyService.shippingDefault(symbolic: [symbolic(49, control | option, enabled: true)],
                                                  keyboardSources: 2, character: TestLayout.us)
        XCTAssertEqual(taken.keyCode, HotKeyService.fallbackKeyCode)
        XCTAssertEqual(taken.modifiers, HotKeyService.fallbackModifiers)
        XCTAssertEqual(HotKeyService.displayString(keyCode: taken.keyCode, carbonModifiers: taken.modifiers,
                                                   character: TestLayout.us), "⌃⌥I")
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: taken.keyCode, modifiers: taken.modifiers),
                     "and the fallback is one the recorder would have taken")

        let both = [symbolic(49, control | option, enabled: true), symbolic(34, control | option, enabled: true)]
        XCTAssertEqual(HotKeyService.shippingDefault(symbolic: both, keyboardSources: 2, character: TestLayout.us).keyCode,
                       HotKeyService.fallbackKeyCode,
                       "the fallback is not second-guessed: it is the one default there is")
    }

    func testTheRecorderSaysWhoHasTheShortcut() {
        XCTAssertNil(ShortcutRecorderView.conflictNote(registrationFailed: false, takenBySystem: false))
        XCTAssertTrue(ShortcutRecorderView.conflictNote(registrationFailed: true, takenBySystem: false)?
            .contains("Another app") == true)
        let system = ShortcutRecorderView.conflictNote(registrationFailed: false, takenBySystem: true)
        XCTAssertTrue(system?.contains("macOS") == true, "the system is named, not some other app")
        XCTAssertTrue(system?.contains("Keyboard Shortcuts") == true, "with where to turn its own one off")
        XCTAssertTrue(ShortcutRecorderView.conflictNote(registrationFailed: true, takenBySystem: true)?
            .contains("Another app") == true, "a refusal is the harder fact, and is said first")
    }

    func testModifiersUseApplesCanonicalOrder() {
        let us = TestLayout.us
        XCTAssertEqual(HotKeyService.displayString(keyCode: 40, carbonModifiers: shift | cmd, character: us), "⇧⌘K")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 0, carbonModifiers: cmd | shift | option | control, character: us),
                       "⌃⌥⇧⌘A")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 8, carbonModifiers: cmd, character: us), "⌘C")
    }

    func testNoModifiersRendersTheBareKey() {
        XCTAssertEqual(HotKeyService.displayString(keyCode: 96, carbonModifiers: 0), "F5")
    }

    func testFunctionKeys() {
        XCTAssertEqual(HotKeyService.displayString(keyCode: 122, carbonModifiers: 0), "F1")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 120, carbonModifiers: 0), "F2")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 96, carbonModifiers: control), "⌃F5")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 111, carbonModifiers: 0), "F12")
    }

    func testArrowKeys() {
        XCTAssertEqual(HotKeyService.displayString(keyCode: 123, carbonModifiers: option), "⌥←")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 126, carbonModifiers: option), "⌥↑")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 124, carbonModifiers: option), "⌥→")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 125, carbonModifiers: option), "⌥↓")
    }

    func testNamedKeys() {
        XCTAssertEqual(HotKeyService.displayString(keyCode: 36, carbonModifiers: 0), "Return")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 48, carbonModifiers: 0), "Tab")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 53, carbonModifiers: 0), "Escape")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 49, carbonModifiers: 0), "Space")
    }

    func testDigitsUseTheAnsiLayout() {
        for character in [TestLayout.us, TestLayout.unknown] {
            XCTAssertEqual(HotKeyService.displayString(keyCode: 18, carbonModifiers: 0, character: character), "1")
            XCTAssertEqual(HotKeyService.displayString(keyCode: 23, carbonModifiers: 0, character: character), "5")
            XCTAssertEqual(HotKeyService.displayString(keyCode: 22, carbonModifiers: 0, character: character), "6")
            XCTAssertEqual(HotKeyService.displayString(keyCode: 29, carbonModifiers: 0, character: character), "0")
        }
    }

    func testUnknownKeyCodesFallBackToHex() {
        XCTAssertEqual(HotKeyService.displayString(keyCode: 0x7F, carbonModifiers: control, character: TestLayout.us),
                       "⌃Key 0x7F")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 0x0A, carbonModifiers: 0, character: TestLayout.unknown), "§",
                       "the ISO key beside 1 has a name of its own, even where the layout cannot be asked")
    }

    func testEveryKindOfKeyOnTheBoardRendersAsItsOwnLegend() {
        // One from each part of the table, because the fallback below it answers for anything
        // the table has lost: a settings row reading "Key 0x31" is a shortcut nobody can say
        // out loud, and a name is the only thing that tells the two apart.
        let legends: [Int: String] = [
            0: "A", 8: "C", 17: "T", 46: "M",
            18: "1", 22: "6", 23: "5", 29: "0",
            24: "=", 33: "[", 41: ";", 50: "`",
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            96: "F5", 111: "F12", 122: "F1",
            115: "Home", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        // Asked of no layout, which is when the table is what names a key.
        for (code, legend) in legends {
            XCTAssertEqual(HotKeyService.keyName(for: code, character: TestLayout.unknown), legend, "key code \(code)")
        }
        // And the hex form is kept for a code the table really has no legend for: 0x7F is one
        // past the last key on the board, and 200 is 0xC8, two digits with nothing to pad.
        XCTAssertEqual(HotKeyService.keyName(for: 0x7F, character: TestLayout.unknown), "Key 0x7F")
        XCTAssertEqual(HotKeyService.keyName(for: 200, character: TestLayout.unknown), "Key 0xC8")
    }

    // MARK: carbonModifiers(from:)

    func testCarbonModifiersMapsEachFlag() {
        XCTAssertEqual(HotKeyService.carbonModifiers(from: .control), control)
        XCTAssertEqual(HotKeyService.carbonModifiers(from: .option), option)
        XCTAssertEqual(HotKeyService.carbonModifiers(from: .shift), shift)
        XCTAssertEqual(HotKeyService.carbonModifiers(from: .command), cmd)
    }

    func testCarbonModifiersCombines() {
        XCTAssertEqual(HotKeyService.carbonModifiers(from: [.control, .option]), 6144)
        XCTAssertEqual(HotKeyService.carbonModifiers(from: [.shift, .command]), 768)
        XCTAssertEqual(HotKeyService.carbonModifiers(from: [.control, .option, .shift, .command]), 6912)
    }

    func testCarbonModifiersIgnoresEverythingElse() {
        XCTAssertEqual(HotKeyService.carbonModifiers(from: []), 0)
        XCTAssertEqual(HotKeyService.carbonModifiers(from: [.capsLock, .function, .numericPad]), 0)
        XCTAssertEqual(HotKeyService.carbonModifiers(from: [.command, .capsLock, .function]), cmd)
    }

    func testRecordedFlagsRoundTripThroughDisplayString() {
        let recorded = HotKeyService.carbonModifiers(from: [.control, .option])
        XCTAssertEqual(HotKeyService.displayString(keyCode: 49, carbonModifiers: recorded), "⌃⌥Space")
    }

    // MARK: normalized

    func testNormalizedKeepsSaneValues() {
        XCTAssertEqual(HotKeyService.normalized(40, fallback: 49), 40)
        XCTAssertEqual(HotKeyService.normalized(0, fallback: 49), 0)
        XCTAssertEqual(HotKeyService.normalized(6144, fallback: 6144), 6144)
    }

    func testNormalizedRejectsGarbage() {
        XCTAssertEqual(HotKeyService.normalized(.nan, fallback: 49), 49)
        XCTAssertEqual(HotKeyService.normalized(.infinity, fallback: 49), 49)
        XCTAssertEqual(HotKeyService.normalized(-1, fallback: 49), 49)
        XCTAssertEqual(HotKeyService.normalized(1_000_000, fallback: 49), 49)
    }

    // MARK: - The letters

    func testTheAlphabetIsClaimedInAlphabeticalOrder() {
        // The question's keys and the fallback shortcut are found among these by the letter
        // they type, and the American A to Z is where they are looked for first.
        XCTAssertEqual(HotKeyService.letterKeyCodes.count, 26)
        XCTAssertEqual(Set(HotKeyService.letterKeyCodes).count, 26, "no key is claimed twice")
        let names = HotKeyService.letterKeyCodes.map { HotKeyService.keyName(for: $0, character: TestLayout.unknown) }
        XCTAssertEqual(names, (0..<26).map { String(UnicodeScalar(UInt8(65 + $0))) })
    }

    // MARK: - Escape and the tail of the open

    func testEscapeIsTheTailOfTheOpenOnlyRightAfterIt() {
        XCTAssertTrue(HotKeyService.escapeIsTail(sinceOpened: 0))
        XCTAssertTrue(HotKeyService.escapeIsTail(sinceOpened: 0.2))
        XCTAssertTrue(HotKeyService.escapeIsTail(sinceOpened: HotKeyService.escapeTail))
        XCTAssertFalse(HotKeyService.escapeIsTail(sinceOpened: HotKeyService.escapeTail + 0.01))
        XCTAssertFalse(HotKeyService.escapeIsTail(sinceOpened: 5))
        XCTAssertFalse(HotKeyService.escapeIsTail(sinceOpened: Date().timeIntervalSince(.distantPast)),
                       "never opened is never a tail")
    }

    func testAClockThatWentBackIsNotATail() {
        XCTAssertFalse(HotKeyService.escapeIsTail(sinceOpened: -30))
        XCTAssertFalse(HotKeyService.escapeIsTail(sinceOpened: .nan))
    }

    /// The rule is measured from the open, and only an open moves that: a step, a find left
    /// with Escape, a slider — every one of which moves the last interaction — leave it where
    /// it was. So Escape to leave a find and Escape again to close both land, and so does the
    /// Escape after Tab-Tab typed quickly.
    func testSteppingAndLeavingAFindNeverMoveWhereTheTailIsMeasuredFrom() {
        let center = ActivityCenter.shared
        center.resetForTesting()
        defer { center.resetForTesting() }
        center.open(.home(tab: HomeSection.music.rawValue), panel: "main")
        let opened = center.openedAt
        XCTAssertNotEqual(opened, .distantPast, "an open is when the tail starts")
        center.step(forward: true, wrap: true)
        center.step(forward: true, wrap: true)
        _ = center.endFind()
        center.setControlDragging(true)
        center.setControlDragging(false)
        XCTAssertEqual(center.openedAt, opened)
    }

    // MARK: - What the island may take out of the world

    /// Every way of asking, with everything else right.
    private func claim(pinnedOpen: Bool = true, holdsKeyboard: Bool = true, textFieldUp: Bool = false,
                       listSection: Bool = true, enabled: Bool = true) -> HotKeyService.KeyClaim {
        HotKeyService.claim(pinnedOpen: pinnedOpen, holdsKeyboard: holdsKeyboard,
                            textFieldUp: textFieldUp, listSection: listSection, enabled: enabled)
    }

    func testTheIslandNeverTakesALetterMeantForSomebodyElsesTextField() {
        // The bug this rule exists for. These keys are registered with Carbon, which takes them
        // from every application at once. A pinned panel does not activate its app, so clicking
        // the island used to leave Mail frontmost with the insertion point still blinking in a
        // half-written reply — and the whole alphabet claimed. Every letter typed next went
        // into a find in the island instead of into the reply.
        XCTAssertEqual(claim(holdsKeyboard: false), .nothing,
                       "open, but the keyboard belongs to the app in front")
    }

    func testNoKeyClassIsTreatedAsHarmlessWhenTheKeyboardIsNotOurs() {
        // A digit or Space does less damage than a letter — a caret moved, a track paused —
        // but each is still a keystroke somebody pressed while looking somewhere else.
        let none = claim(holdsKeyboard: false, listSection: false)
        XCTAssertFalse(none.bareKeys)
        XCTAssertFalse(none.letters)
    }

    func testTheKeysAreOnlyOursWhileWeAreHoldingTheKeyboard() {
        XCTAssertTrue(claim().bareKeys, "pinned, holding the keyboard, nothing being typed into")
        XCTAssertEqual(claim(pinnedOpen: false), .nothing, "a peek takes nothing")
        XCTAssertEqual(claim(textFieldUp: true), .nothing, "nor does the island's own text field")
        XCTAssertEqual(claim(enabled: false), .nothing, "nor when the user switched them off")
    }

    func testTheAlphabetIsOnlyWorthClaimingWhereThereIsAListToSearch() {
        // On Now Playing or Stats a letter is nobody's to take, but the arrows and digits still
        // step and jump, so the two halves of the claim are answered separately.
        let notAList = claim(listSection: false)
        XCTAssertTrue(notAList.bareKeys)
        XCTAssertFalse(notAList.letters)
        XCTAssertTrue(claim(listSection: true).letters)
    }

    func testLettersAreNeverClaimedWithoutTheKeysUnderThem() {
        // Twenty-six global hot keys with no licence behind them is the worst version of this
        // bug, so no combination may produce letters without the rest.
        for pinned in [true, false] {
            for holds in [true, false] {
                for typing in [true, false] {
                    for on in [true, false] {
                        let c = claim(pinnedOpen: pinned, holdsKeyboard: holds,
                                      textFieldUp: typing, listSection: true, enabled: on)
                        if c.letters { XCTAssertTrue(c.bareKeys, "letters without the bare keys") }
                    }
                }
            }
        }
    }

    // MARK: - What a key types, not where it is

    private typealias Role = HotKeyService.KeyRole

    /// A press as the handler reads it: what the layout types on the key, and the figure
    /// printed on it where it has one, on a list, on Now Playing, or on Actions.
    private func role(_ typed: String?, digit: Int? = nil, on section: HomeSection) -> Role {
        HotKeyService.keyRole(typed: typed, digit: digit,
                              searchable: PanelFind.searches(section), takesEntry: PanelFind.takesEntry(section))
    }

    func testAnAmericanKeyboardDoesWhatItAlwaysDid() {
        // The letters find, the figures jump the switcher or type a timer, zero has no slot.
        XCTAssertEqual(role(TestLayout.us(kVK_ANSI_A), on: .clipboard), .find("a"))
        XCTAssertEqual(role(TestLayout.us(kVK_ANSI_2), digit: 2, on: .clipboard), .slot(1))
        XCTAssertEqual(role(TestLayout.us(kVK_ANSI_2), digit: 2, on: .music), .slot(1))
        XCTAssertEqual(role(TestLayout.us(kVK_ANSI_0), digit: 0, on: .clipboard), .nothing)
        XCTAssertEqual(role(TestLayout.us(kVK_ANSI_2), digit: 2, on: .actions), .entry("2"))
        XCTAssertEqual(role(TestLayout.us(kVK_ANSI_0), digit: 0, on: .actions), .entry("0"))
        XCTAssertEqual(role(TestLayout.us(kVK_ANSI_A), on: .music), .nothing, "no list, no find")
        XCTAssertEqual(role(TestLayout.us(kVK_ANSI_Semicolon), on: .clipboard), .nothing)
    }

    /// The French number row types é è ç à without Shift. Those jumped the switcher on a list
    /// rather than starting a find, and Shift, which is how the figures are typed there, was
    /// never claimed at all.
    func testALetterOnTheNumberRowFindsWhereThereIsAList() {
        let azerty = TestLayout.azerty
        XCTAssertEqual(role(azerty(kVK_ANSI_2), digit: 2, on: .windows), .find("é"))
        XCTAssertEqual(role(azerty(kVK_ANSI_9), digit: 9, on: .windows), .find("ç"))
        XCTAssertEqual(role(azerty(kVK_ANSI_2), digit: 2, on: .music), .slot(1),
                       "nothing to search: the key is the figure printed on it")
        XCTAssertEqual(role(azerty(kVK_ANSI_2), digit: 2, on: .actions), .entry("2"),
                       "and on Actions it types that figure, as the field then reads the rest of the row")
        XCTAssertEqual(role(azerty(kVK_ANSI_3), digit: 3, on: .windows), .slot(2), "a \" is no letter")
        // Shift and the key: the French way of typing a figure.
        XCTAssertEqual(role(TestLayout.azertyShifted(kVK_ANSI_2), digit: 2, on: .windows), .slot(1))
        XCTAssertEqual(role(TestLayout.azertyShifted(kVK_ANSI_2), digit: 2, on: .actions), .entry("2"))
        // Czech: ě š č ř ž ý á í é on 2 to 0.
        XCTAssertEqual(role("ř", digit: 5, on: .shelf), .find("ř"))
        XCTAssertEqual(role("ř", digit: 5, on: .actions), .entry("5"))
    }

    func testALetterBesideTheAlphabetFinds() {
        XCTAssertEqual(role(TestLayout.azerty(kVK_ANSI_Semicolon), on: .notifications), .find("m"), "the French M")
        XCTAssertEqual(role(TestLayout.azerty(kVK_ANSI_M), on: .notifications), .nothing,
                       "and the key an American M is on types a comma there")
        XCTAssertEqual(role(TestLayout.german(kVK_ANSI_Semicolon), on: .clipboard), .find("ö"))
        XCTAssertEqual(role(TestLayout.german(kVK_ANSI_Quote), on: .clipboard), .find("ä"))
        XCTAssertEqual(role(TestLayout.german(kVK_ANSI_Minus), on: .clipboard), .find("ß"))
        XCTAssertEqual(role(TestLayout.german(kVK_ANSI_Y), on: .clipboard), .find("z"))
        XCTAssertEqual(role(TestLayout.dvorak(kVK_ANSI_Semicolon), on: .clipboard), .find("s"))
        XCTAssertEqual(role(TestLayout.dvorak(kVK_ANSI_Slash), on: .clipboard), .find("z"))
        XCTAssertEqual(role(TestLayout.dvorak(kVK_ANSI_Q), on: .clipboard), .nothing, "Dvorak's ' is no letter")
        XCTAssertEqual(role("ж", on: .windows), .find("ж"))
    }

    func testAFigureIsWhateverTheLayoutTypesOrWhatIsPrintedOnTheKey() {
        XCTAssertEqual(role("٢", digit: 2, on: .music), .slot(1), "an Arabic two")
        XCTAssertEqual(role("٢", digit: 2, on: .actions), .entry("2"), "typed into the field as a Western one")
        XCTAssertEqual(role(nil, digit: 3, on: .actions), .entry("3"), "a layout that cannot be asked")
        XCTAssertEqual(role(nil, on: .clipboard), .nothing)
        XCTAssertEqual(role("5", digit: 5, on: .music), .slot(4), "the keypad's 5")
        XCTAssertEqual(HotKeyService.figure("５"), 5)
        XCTAssertEqual(HotKeyService.figure("7"), 7)
        XCTAssertNil(HotKeyService.figure("²"), "a superscript is not a figure anybody typed")
        XCTAssertNil(HotKeyService.figure("Ⅻ"))
        XCTAssertNil(HotKeyService.figure("12"))
        XCTAssertNil(HotKeyService.figure("é"))
        XCTAssertNil(HotKeyService.figure(nil))
    }

    // MARK: - What is claimed

    /// Every typing key claimed on a layout, with the letters or without.
    private func claimed(_ plain: (Int) -> String?, shifted: (Int) -> String?, letters: Bool) -> [HotKeyService.TypingKey] {
        HotKeyService.typingKeys.filter { key in
            let typed = key.kind == .shiftedNumberRow ? shifted(key.keyCode) : plain(key.keyCode)
            return HotKeyService.claims(key.kind, letters: letters, typed: typed)
        }
    }

    func testAnAmericanKeyboardLosesNothingMoreThanTheKeypad() {
        // What was claimed before: nine switcher digits, zero, and the twenty-six letters. The
        // keypad's ten figures are the one addition; ⇧2 is still an @ and ; still a ;.
        let list = claimed(TestLayout.us, shifted: TestLayout.usShifted, letters: true)
        XCTAssertEqual(list.filter { $0.kind != .keypad }.count, 36)
        XCTAssertEqual(list.filter { $0.kind == .keypad }.count, 10)
        XCTAssertFalse(list.contains { $0.kind == .shiftedNumberRow || $0.kind == .punctuation })
        XCTAssertEqual(claimed(TestLayout.us, shifted: TestLayout.usShifted, letters: false).count, 20,
                       "without a list, the number row and the keypad")
    }

    func testTheKeysAroundTheAlphabetAreClaimedWhereTheyTypeALetter() {
        let french = claimed(TestLayout.azerty, shifted: TestLayout.azertyShifted, letters: true)
        XCTAssertEqual(Set(french.filter { $0.kind == .punctuation }.map(\.keyCode)), [kVK_ANSI_Semicolon, kVK_ANSI_Quote],
                       "the M and the ù")
        XCTAssertEqual(french.filter { $0.kind == .shiftedNumberRow }.count, 10, "Shift types the figures there")
        let german = claimed(TestLayout.german, shifted: TestLayout.germanShifted, letters: true)
        XCTAssertEqual(Set(german.filter { $0.kind == .punctuation }.map(\.keyCode)),
                       [kVK_ANSI_LeftBracket, kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Minus], "Ü, Ö, Ä and ß")
        XCTAssertTrue(german.filter { $0.kind == .shiftedNumberRow }.isEmpty, "German Shift types punctuation")
        let dvorak = claimed(TestLayout.dvorak, shifted: TestLayout.usShifted, letters: true)
        XCTAssertEqual(Set(dvorak.filter { $0.kind == .punctuation }.map(\.keyCode)),
                       [kVK_ANSI_Semicolon, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash], "Dvorak's S, W, V and Z")
        XCTAssertTrue(claimed(TestLayout.german, shifted: TestLayout.germanShifted, letters: false)
            .allSatisfy { $0.kind == .numberRow || $0.kind == .keypad }, "no list, no letters wherever they are")
    }

    func testEveryTypingKeyHasAnIdOfItsOwn() {
        let keys = HotKeyService.typingKeys
        XCTAssertEqual(keys.count, 10 + 10 + 10 + 26 + 12)
        for (index, key) in keys.enumerated() {
            XCTAssertEqual(HotKeyService.typingKey(id: HotKeyService.typingKeyIDBase + UInt32(index)), key)
        }
        XCTAssertNil(HotKeyService.typingKey(id: HotKeyService.typingKeyIDBase - 1), "the named slots stay theirs")
        XCTAssertNil(HotKeyService.typingKey(id: HotKeyService.typingKeyIDBase + UInt32(keys.count)))
        XCTAssertEqual(keys.filter { $0.kind == .numberRow }.map(\.digit), [1, 2, 3, 4, 5, 6, 7, 8, 9, 0])
        XCTAssertEqual(keys.filter { $0.kind == .keypad }.map(\.digit), [1, 2, 3, 4, 5, 6, 7, 8, 9, 0])
        XCTAssertTrue(keys.filter { $0.kind == .shiftedNumberRow }.allSatisfy { $0.modifiers == shift })
        XCTAssertTrue(keys.filter { $0.kind != .shiftedNumberRow }.allSatisfy { $0.modifiers == 0 })
        let pairs = keys.map { "\($0.keyCode)-\($0.modifiers)" }
        XCTAssertEqual(Set(pairs).count, pairs.count, "no key and modifiers are registered twice")
    }

    // MARK: - Naming a key by what it types

    func testAShortcutIsNamedByWhatItsKeyTypes() {
        let controlOption = control | option
        XCTAssertEqual(HotKeyService.displayString(keyCode: kVK_ANSI_Z, carbonModifiers: controlOption,
                                                   character: TestLayout.us), "⌃⌥Z")
        XCTAssertEqual(HotKeyService.displayString(keyCode: kVK_ANSI_Y, carbonModifiers: controlOption,
                                                   character: TestLayout.german), "⌃⌥Z", "the German Z is the American Y")
        XCTAssertEqual(HotKeyService.displayString(keyCode: kVK_ANSI_Z, carbonModifiers: controlOption,
                                                   character: TestLayout.german), "⌃⌥Y")
        XCTAssertEqual(HotKeyService.displayString(keyCode: kVK_ANSI_Q, carbonModifiers: controlOption,
                                                   character: TestLayout.azerty), "⌃⌥A", "the French A is the American Q")
        XCTAssertEqual(HotKeyService.displayString(keyCode: kVK_ANSI_I, carbonModifiers: controlOption,
                                                   character: TestLayout.dvorak), "⌃⌥C")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_ANSI_Semicolon, character: TestLayout.german), "Ö")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_ANSI_Minus, character: TestLayout.german), "ß",
                       "a capital that would be two letters keeps its own form")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_ANSI_2, character: TestLayout.azerty), "É")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_ISO_Section, character: TestLayout.us), "§")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_JIS_Yen, character: TestLayout.unknown), "¥")
    }

    func testKeysThatTypeNothingKeepTheirNames() {
        // A layout that answers "x" for every key, which none of these may believe.
        let everything: (Int) -> String? = { _ in "x" }
        XCTAssertEqual(HotKeyService.keyName(for: kVK_Space, character: everything), "Space")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_Return, character: everything), "Return")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_Tab, character: everything), "Tab")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_F5, character: everything), "F5")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_LeftArrow, character: everything), "←")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_ANSI_Keypad1, character: everything), "Key 0x53",
                       "the keypad is not named by its figure, which would read as the number row's")
        // And what types nothing printable leaves the name to the table.
        XCTAssertEqual(HotKeyService.keyName(for: kVK_ANSI_A, character: { _ in "\u{10}" }), "A")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_ANSI_A, character: { _ in " " }), "A")
        XCTAssertEqual(HotKeyService.keyName(for: kVK_ANSI_A, character: { _ in "" }), "A")
        XCTAssertNil(HotKeyService.legend(typed: nil))
        XCTAssertEqual(HotKeyService.legend(typed: "ж"), "Ж")
    }

    // MARK: - Input methods

    /// Under Pinyin, Kotoeri or Korean 2-Set a key is the start of a composition, and the hot
    /// key takes it before the input method sees it: the find opened with a bare Latin letter
    /// outside the composition. There the field opens empty instead.
    func testAnInputMethodOpensTheFindEmpty() {
        XCTAssertTrue(KeyLayout.prefillsFind(sourceType: kTISTypeKeyboardLayout as String), "a plain layout keeps the letter")
        XCTAssertFalse(KeyLayout.prefillsFind(sourceType: kTISTypeKeyboardInputMode as String), "Pinyin, Hiragana, 2-Set")
        XCTAssertFalse(KeyLayout.prefillsFind(sourceType: kTISTypeKeyboardInputMethodWithoutModes as String))
        XCTAssertFalse(KeyLayout.prefillsFind(sourceType: kTISTypeKeyboardInputMethodModeEnabled as String))
        XCTAssertTrue(KeyLayout.prefillsFind(sourceType: nil), "a source that cannot be asked keeps what it did")
    }

    /// The Text Input Sources calls trap off the main thread on recent macOS; asked from
    /// another, the layout says nothing and whoever asked falls back to the American legend.
    func testTheLayoutIsOnlyAskedOnTheMainThread() {
        let asked = expectation(description: "asked from a background queue")
        DispatchQueue.global().async {
            XCTAssertNil(KeyLayout.character(for: kVK_ANSI_A))
            XCTAssertNil(KeyLayout.character(for: kVK_ANSI_2, modifiers: shiftKey))
            XCTAssertTrue(KeyLayout.characters(for: HotKeyService.numberRowKeyCodes).isEmpty)
            XCTAssertTrue(TimerEntry.numberRowOnThisMac.isEmpty)
            XCTAssertEqual(HotKeyService.keyName(for: kVK_ANSI_A), "A")
            asked.fulfill()
        }
        wait(for: [asked], timeout: 5)
    }

    // MARK: - The fallback shortcut is the key that types I

    func testTheFallbackIsTheKeyThatTypesAnI() {
        XCTAssertEqual(HotKeyService.fallbackKey(character: TestLayout.us), kVK_ANSI_I)
        XCTAssertEqual(HotKeyService.fallbackKey(character: TestLayout.german), kVK_ANSI_I)
        XCTAssertEqual(HotKeyService.fallbackKey(character: TestLayout.azerty), kVK_ANSI_I)
        XCTAssertEqual(HotKeyService.fallbackKey(character: TestLayout.dvorak), kVK_ANSI_G,
                       "where I sits on an American keyboard types C on a Dvorak one")
        XCTAssertEqual(HotKeyService.fallbackKey(character: TestLayout.colemak), kVK_ANSI_L,
                       "and U on a Colemak one")
        XCTAssertEqual(HotKeyService.fallbackKey(character: TestLayout.turkishQ), kVK_ANSI_Quote,
                       "the Turkish dotted i is beside the L")
        XCTAssertEqual(HotKeyService.fallbackKey(character: { _ in "ж" }), HotKeyService.fallbackKeyCode,
                       "no key types an I: the American place")
        XCTAssertEqual(HotKeyService.fallbackKey(character: TestLayout.unknown), HotKeyService.fallbackKeyCode)

        for layout in [TestLayout.us, TestLayout.german, TestLayout.azerty, TestLayout.dvorak, TestLayout.colemak] {
            XCTAssertEqual(HotKeyService.fallbackDisplay(character: layout), "⌃⌥I", "named by what it types")
        }
        let taken = [symbolic(49, control | option, enabled: true)]
        XCTAssertEqual(HotKeyService.shippingDefault(symbolic: taken, keyboardSources: 2, character: TestLayout.dvorak).keyCode,
                       kVK_ANSI_G, "a Dvorak Mac starts on the key it types I with")
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_G, modifiers: HotKeyService.fallbackModifiers))
    }
}

/// Keyboard layouts as `KeyLayout` would answer for them, for the rules that ask one: what
/// each key types with nothing held, and for the number row with Shift. Only the keys the
/// tests ask about need be right, and the American one is complete.
enum TestLayout {
    private static let american: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_S: "s", kVK_ANSI_D: "d", kVK_ANSI_F: "f", kVK_ANSI_H: "h", kVK_ANSI_G: "g",
        kVK_ANSI_Z: "z", kVK_ANSI_X: "x", kVK_ANSI_C: "c", kVK_ANSI_V: "v", kVK_ANSI_B: "b", kVK_ANSI_Q: "q",
        kVK_ANSI_W: "w", kVK_ANSI_E: "e", kVK_ANSI_R: "r", kVK_ANSI_Y: "y", kVK_ANSI_T: "t", kVK_ANSI_O: "o",
        kVK_ANSI_U: "u", kVK_ANSI_I: "i", kVK_ANSI_P: "p", kVK_ANSI_L: "l", kVK_ANSI_J: "j", kVK_ANSI_K: "k",
        kVK_ANSI_N: "n", kVK_ANSI_M: "m",
        kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
        kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0",
        kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_RightBracket: "]", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
        kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`", kVK_ISO_Section: "§",
    ]

    private static func table(_ changes: [Int: String]) -> (Int) -> String? {
        let merged = american.merging(changes) { _, new in new }
        return { merged[$0] }
    }

    static let us: (Int) -> String? = table([:])
    static let usShifted: (Int) -> String? = { code in
        [kVK_ANSI_1: "!", kVK_ANSI_2: "@", kVK_ANSI_3: "#", kVK_ANSI_4: "$", kVK_ANSI_5: "%",
         kVK_ANSI_6: "^", kVK_ANSI_7: "&", kVK_ANSI_8: "*", kVK_ANSI_9: "(", kVK_ANSI_0: ")"][code]
    }
    /// A layout that cannot be asked.
    static let unknown: (Int) -> String? = { _ in nil }

    /// German QWERTZ: Y and Z change places, and Ü Ö Ä ß are beside the letters.
    static let german: (Int) -> String? = table([
        kVK_ANSI_Y: "z", kVK_ANSI_Z: "y", kVK_ANSI_LeftBracket: "ü", kVK_ANSI_RightBracket: "+",
        kVK_ANSI_Semicolon: "ö", kVK_ANSI_Quote: "ä", kVK_ANSI_Minus: "ß", kVK_ANSI_Equal: "´",
        kVK_ANSI_Backslash: "#", kVK_ANSI_Slash: "-", kVK_ANSI_Grave: "<", kVK_ISO_Section: "^",
    ])
    static let germanShifted: (Int) -> String? = { code in
        [kVK_ANSI_1: "!", kVK_ANSI_2: "\"", kVK_ANSI_3: "§", kVK_ANSI_4: "$", kVK_ANSI_5: "%",
         kVK_ANSI_6: "&", kVK_ANSI_7: "/", kVK_ANSI_8: "(", kVK_ANSI_9: ")", kVK_ANSI_0: "="][code]
    }

    /// French AZERTY: A and Q, Z and W change places, M is beside the L, and the number row
    /// types its punctuation and é è ç à without Shift, its figures with it.
    static let azerty: (Int) -> String? = table([
        kVK_ANSI_Q: "a", kVK_ANSI_W: "z", kVK_ANSI_A: "q", kVK_ANSI_Z: "w", kVK_ANSI_Semicolon: "m",
        kVK_ANSI_M: ",", kVK_ANSI_Comma: ";", kVK_ANSI_Period: ":", kVK_ANSI_Slash: "=", kVK_ANSI_Quote: "ù",
        kVK_ANSI_LeftBracket: "^", kVK_ANSI_RightBracket: "$", kVK_ANSI_Minus: ")", kVK_ANSI_Equal: "-",
        kVK_ANSI_Backslash: "`", kVK_ANSI_Grave: "<", kVK_ISO_Section: "@",
        kVK_ANSI_1: "&", kVK_ANSI_2: "é", kVK_ANSI_3: "\"", kVK_ANSI_4: "'", kVK_ANSI_5: "(",
        kVK_ANSI_6: "§", kVK_ANSI_7: "è", kVK_ANSI_8: "!", kVK_ANSI_9: "ç", kVK_ANSI_0: "à",
    ])
    static let azertyShifted: (Int) -> String? = { code in
        [kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
         kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0"][code]
    }

    /// Dvorak: the same number row, and every letter somewhere else.
    static let dvorak: (Int) -> String? = table([
        kVK_ANSI_Q: "'", kVK_ANSI_W: ",", kVK_ANSI_E: ".", kVK_ANSI_R: "p", kVK_ANSI_T: "y", kVK_ANSI_Y: "f",
        kVK_ANSI_U: "g", kVK_ANSI_I: "c", kVK_ANSI_O: "r", kVK_ANSI_P: "l", kVK_ANSI_LeftBracket: "/",
        kVK_ANSI_RightBracket: "=", kVK_ANSI_A: "a", kVK_ANSI_S: "o", kVK_ANSI_D: "e", kVK_ANSI_F: "u",
        kVK_ANSI_G: "i", kVK_ANSI_H: "d", kVK_ANSI_J: "h", kVK_ANSI_K: "t", kVK_ANSI_L: "n",
        kVK_ANSI_Semicolon: "s", kVK_ANSI_Quote: "-", kVK_ANSI_Z: ";", kVK_ANSI_X: "q", kVK_ANSI_C: "j",
        kVK_ANSI_V: "k", kVK_ANSI_B: "x", kVK_ANSI_N: "b", kVK_ANSI_M: "m", kVK_ANSI_Comma: "w",
        kVK_ANSI_Period: "v", kVK_ANSI_Slash: "z", kVK_ANSI_Minus: "[", kVK_ANSI_Equal: "]",
    ])

    /// Colemak, as far as the I and the U go.
    static let colemak: (Int) -> String? = table([kVK_ANSI_I: "u", kVK_ANSI_L: "i", kVK_ANSI_U: "l"])

    /// Turkish Q: the I key types a dotless ı, and the dotted i is beside the L.
    static let turkishQ: (Int) -> String? = table([kVK_ANSI_I: "ı", kVK_ANSI_Quote: "i", kVK_ANSI_Semicolon: "ş"])
}
