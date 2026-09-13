import Carbon.HIToolbox
import XCTest
@testable import MacNotchIsland

/// The recorder's one rule: which pressed combinations it will not take, and why. A recorded
/// combination is claimed from every app on the Mac, and the service registers whatever it is
/// handed, so the rule is the only thing between a slip of the fingers and a key nobody can type.
final class ShortcutRecorderTests: XCTestCase {
    // Carbon masks, spelled out so a change to the mapping shows up here.
    private let cmd = 256
    private let shift = 512
    private let option = 2048
    private let control = 4096

    private typealias Rejection = ShortcutRecorderView.Rejection

    func testABareKeyIsRefused() {
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_A, modifiers: 0), Rejection.bareKey)
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_F5, modifiers: 0), Rejection.bareKey,
                       "a function key on its own is still a key every app may want")
        XCTAssertEqual(Rejection.bareKey.message, "Add Control, Option, Shift or Command.",
                       "the line the row has always shown for this")
    }

    func testShiftAloneWithAKeyThatTypesIsRefused() {
        // ⇧A recorded here is a Mac on which nobody can type a capital A.
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_A, modifiers: shift), Rejection.shiftAlone)
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_1, modifiers: shift), Rejection.shiftAlone,
                       "⇧1 is an exclamation mark")
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_Semicolon, modifiers: shift), Rejection.shiftAlone,
                       "⇧; is a colon")
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_Space, modifiers: shift), Rejection.shiftAlone)
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_UpArrow, modifiers: shift), Rejection.shiftAlone,
                       "⇧↑ extends a selection in every text field")
    }

    func testShiftAloneWithAFunctionKeyIsAllowed() {
        // The function keys type nothing, so Shift with one of them is a shortcut and nothing else.
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_F5, modifiers: shift))
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_F19, modifiers: shift))
        XCTAssertEqual(ShortcutRecorderView.functionKeys.count, 20, "F1 to F20")
    }

    func testShiftBesideAnotherModifierIsAllowed() {
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_A, modifiers: shift | cmd))
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_A, modifiers: shift | control))
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_1, modifiers: shift | option))
    }

    func testTheIslandsOwnStepsAreRefusedWhateverIsHeld() {
        // The next section is registered on Tab, and the sideways steps on the arrows, with
        // the recorded combination's own modifiers — so any of these would be the shortcut
        // and the step at once, and the second to be registered would lose in silence.
        for modifiers in [control | option, cmd, control, option | shift, shift, control | option | shift | cmd] {
            XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_Tab, modifiers: modifiers), Rejection.ownStep,
                           "Tab with \(modifiers)")
            XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_LeftArrow, modifiers: modifiers), Rejection.ownStep,
                           "← with \(modifiers)")
            XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_RightArrow, modifiers: modifiers), Rejection.ownStep,
                           "→ with \(modifiers)")
        }
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_Tab, modifiers: HotKeyService.defaultModifiers),
                       Rejection.ownStep, "⌃⌥Tab is the shipping step to the next section")
        XCTAssertEqual(ShortcutRecorderView.ownStepKeys, Set([kVK_Tab, kVK_LeftArrow, kVK_RightArrow]),
                       "the three keys the pane lists under Next section and Step sideways")
    }

    func testOrdinaryCombinationsAreTaken() {
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: HotKeyService.defaultKeyCode,
                                                    modifiers: HotKeyService.defaultModifiers),
                     "the shipping shortcut passes its own rule")
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_K, modifiers: cmd | shift))
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_UpArrow, modifiers: control | option),
                     "the vertical arrows are nobody's step")
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_Escape, modifiers: cmd),
                     "Escape is claimed bare, and only while something is open; with a modifier it is free")
    }

    func testEveryRefusalSaysSomethingAPersonCanActOn() {
        for refusal in [Rejection.bareKey, .shiftAlone, .ownStep] {
            XCTAssertFalse(refusal.message.isEmpty)
            XCTAssertTrue(refusal.message.hasSuffix("."), "\"\(refusal.message)\" should read as a sentence")
            XCTAssertTrue(refusal.message.contains("Add") || refusal.message.contains("Choose"),
                          "\"\(refusal.message)\" should say what to do instead")
        }
    }
}
