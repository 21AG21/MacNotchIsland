import XCTest
import AppKit
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

        let one = HotKeyService.shippingDefault(symbolic: inputMenu, keyboardSources: 1)
        XCTAssertEqual(one.keyCode, HotKeyService.defaultKeyCode, "one layout keeps the shortcut the README names")
        XCTAssertEqual(one.modifiers, HotKeyService.defaultModifiers)
        let two = HotKeyService.shippingDefault(symbolic: inputMenu, keyboardSources: 2)
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
        let free = HotKeyService.shippingDefault(symbolic: [], keyboardSources: 2)
        XCTAssertEqual(free.keyCode, HotKeyService.defaultKeyCode)
        XCTAssertEqual(free.modifiers, HotKeyService.defaultModifiers)

        let taken = HotKeyService.shippingDefault(symbolic: [symbolic(49, control | option, enabled: true)],
                                                  keyboardSources: 2)
        XCTAssertEqual(taken.keyCode, HotKeyService.fallbackKeyCode)
        XCTAssertEqual(taken.modifiers, HotKeyService.fallbackModifiers)
        XCTAssertEqual(HotKeyService.displayString(keyCode: taken.keyCode, carbonModifiers: taken.modifiers), "⌃⌥I")
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: taken.keyCode, modifiers: taken.modifiers),
                     "and the fallback is one the recorder would have taken")

        let both = [symbolic(49, control | option, enabled: true), symbolic(34, control | option, enabled: true)]
        XCTAssertEqual(HotKeyService.shippingDefault(symbolic: both, keyboardSources: 2).keyCode, HotKeyService.fallbackKeyCode,
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
        XCTAssertEqual(HotKeyService.displayString(keyCode: 40, carbonModifiers: shift | cmd), "⇧⌘K")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 0, carbonModifiers: cmd | shift | option | control), "⌃⌥⇧⌘A")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 8, carbonModifiers: cmd), "⌘C")
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
        XCTAssertEqual(HotKeyService.displayString(keyCode: 18, carbonModifiers: 0), "1")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 23, carbonModifiers: 0), "5")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 22, carbonModifiers: 0), "6")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 29, carbonModifiers: 0), "0")
    }

    func testUnknownKeyCodesFallBackToHex() {
        XCTAssertEqual(HotKeyService.displayString(keyCode: 0x7F, carbonModifiers: control), "⌃Key 0x7F")
        XCTAssertEqual(HotKeyService.displayString(keyCode: 0x0A, carbonModifiers: 0), "Key 0x0A")
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
        for (code, legend) in legends {
            XCTAssertEqual(HotKeyService.keyName(for: code), legend, "key code \(code)")
        }
        // And the hex form is kept for a code the table really has no legend for: 0x7F is one
        // past the last key on the board, and 200 is 0xC8, two digits with nothing to pad.
        XCTAssertEqual(HotKeyService.keyName(for: 0x7F), "Key 0x7F")
        XCTAssertEqual(HotKeyService.keyName(for: 200), "Key 0xC8")
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
        // The slot a letter key is registered in is its position in this list, so the list
        // being A to Z is what makes a key press come back as the right letter.
        XCTAssertEqual(HotKeyService.letterKeyCodes.count, 26)
        XCTAssertEqual(Set(HotKeyService.letterKeyCodes).count, 26, "no key is claimed twice")
        let names = HotKeyService.letterKeyCodes.map { HotKeyService.keyName(for: $0) }
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
}
