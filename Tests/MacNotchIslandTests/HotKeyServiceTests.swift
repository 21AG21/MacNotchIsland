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

    func testNoKeyNameIsEmpty() {
        // Every mapped key must render as something the settings row can show.
        for code in 0...126 {
            XCTAssertFalse(HotKeyService.keyName(for: code).isEmpty, "key code \(code) rendered as nothing")
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
}
