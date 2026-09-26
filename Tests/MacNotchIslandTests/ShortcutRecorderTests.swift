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
        XCTAssertEqual(Rejection.bareKey.message, "Add two of Control, Option and Command.",
                       "what the recorder takes now, rather than one modifier it would refuse next")
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

    func testShiftAloneWithAFunctionKeyIsRefusedForItsSteps() {
        // The function keys type nothing, so ⇧F5 takes no capital from anyone — but the steps
        // would be ⇧Tab and ⇧← and ⇧→, which go back a field and extend a selection everywhere.
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_F5, modifiers: shift), Rejection.tooFewModifiers)
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_F19, modifiers: shift), Rejection.tooFewModifiers)
        XCTAssertEqual(ShortcutRecorderView.functionKeys.count, 20, "F1 to F20")
    }

    func testShiftBesideTwoOfTheOthersIsAllowed() {
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_A, modifiers: shift | cmd | control))
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_A, modifiers: shift | control | option))
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_1, modifiers: shift | option | cmd))
    }

    func testFewerThanTwoOfControlOptionAndCommandIsRefused() {
        // Each of these took the editing keys its steps sit on from every app on the Mac.
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_K, modifiers: control), Rejection.tooFewModifiers,
                       "⌃K: ⌃Tab switches tabs in every browser and in Xcode")
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_Space, modifiers: option), Rejection.tooFewModifiers,
                       "⌥Space: ⌥← and ⌥→ jump a word")
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_K, modifiers: cmd), Rejection.tooFewModifiers,
                       "⌘K: ⌘← and ⌘→ go to either end of the line")
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_A, modifiers: shift | cmd), Rejection.tooFewModifiers,
                       "Shift is not one of the two")
        XCTAssertEqual(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_A, modifiers: shift), Rejection.shiftAlone,
                       "Shift alone with a key that types still says so, which is the truer thing to say")
    }

    /// The rule the service registers the steps by, and the recorder refuses by.
    func testTheStepsAreRegisteredOnlyWithTwoOfControlOptionAndCommand() {
        XCTAssertTrue(HotKeyService.stepsAreSafe(modifiers: control | option))
        XCTAssertTrue(HotKeyService.stepsAreSafe(modifiers: control | cmd))
        XCTAssertTrue(HotKeyService.stepsAreSafe(modifiers: option | cmd | shift))
        XCTAssertTrue(HotKeyService.stepsAreSafe(modifiers: control | option | cmd))
        XCTAssertTrue(HotKeyService.stepsAreSafe(modifiers: HotKeyService.defaultModifiers), "⌃⌥Space steps on ⌃⌥Tab")
        XCTAssertTrue(HotKeyService.stepsAreSafe(modifiers: HotKeyService.fallbackModifiers), "and ⌃⌥I on the same")
        for single in [control, option, cmd, shift] {
            XCTAssertFalse(HotKeyService.stepsAreSafe(modifiers: single), "\(single) alone keeps its toggle, not its steps")
        }
        XCTAssertFalse(HotKeyService.stepsAreSafe(modifiers: cmd | shift), "Shift is half of the backward step already")
        XCTAssertFalse(HotKeyService.stepsAreSafe(modifiers: control | shift))
        XCTAssertFalse(HotKeyService.stepsAreSafe(modifiers: 0))
    }

    func testTheRowSaysWhenAStoredShortcutHasLostItsSteps() {
        // A combination recorded before the rule still opens and closes the island; the row
        // says where its steps went.
        let note = ShortcutRecorderView.conflictNote(registrationFailed: false, takenBySystem: false, stepsWithheld: true)
        XCTAssertTrue(note?.contains("Tab") == true)
        XCTAssertTrue(note?.contains("Choose") == true, "with what to do about it")
        XCTAssertNil(ShortcutRecorderView.conflictNote(registrationFailed: false, takenBySystem: false, stepsWithheld: false))
        XCTAssertTrue(ShortcutRecorderView.conflictNote(registrationFailed: true, takenBySystem: false, stepsWithheld: true)?
            .contains("Another app") == true, "a refusal is the harder fact, and is said first")
        XCTAssertTrue(ShortcutRecorderView.conflictNote(registrationFailed: false, takenBySystem: true, stepsWithheld: true)?
            .contains("macOS") == true, "and so is the system answering the shortcut itself")
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
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_ANSI_K, modifiers: cmd | option))
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_UpArrow, modifiers: control | option),
                     "the vertical arrows are nobody's step")
        XCTAssertNil(ShortcutRecorderView.rejection(keyCode: kVK_Escape, modifiers: control | option),
                     "Escape is claimed bare, and only while something is open; with modifiers it is free")
    }

    func testEveryRefusalSaysSomethingAPersonCanActOn() {
        for refusal in [Rejection.bareKey, .shiftAlone, .ownStep, .tooFewModifiers] {
            XCTAssertFalse(refusal.message.isEmpty)
            XCTAssertTrue(refusal.message.hasSuffix("."), "\"\(refusal.message)\" should read as a sentence")
            XCTAssertTrue(refusal.message.contains("Add") || refusal.message.contains("Choose"),
                          "\"\(refusal.message)\" should say what to do instead")
        }
    }
}
