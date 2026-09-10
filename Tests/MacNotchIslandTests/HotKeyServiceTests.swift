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
            123: "←", 126: "↑",
        ]
        for (code, legend) in legends {
            XCTAssertEqual(HotKeyService.keyName(for: code), legend, "key code \(code)")
            XCTAssertFalse(HotKeyService.keyName(for: code).hasPrefix("Key 0x"),
                           "key code \(code) fell through to the hex form, which is the table having gone")
        }
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
