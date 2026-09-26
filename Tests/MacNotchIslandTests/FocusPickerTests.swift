import XCTest
@testable import MacNotchIsland

/// The rail's Focus popover: reading this Mac's modes out of the Focus database, what the popover
/// lists from them, and how a pick is handed to the "Set Focus" shortcut.
final class FocusPickerTests: XCTestCase {
    /// `~/Library/DoNotDisturb/DB/ModeConfigurations.json`, cut down to what is read, in the
    /// shape macOS writes it: a dictionary of configurations keyed by identifier, so in no
    /// order at all. Work's name is missing its colour; the second entry repeats Sleep; one mode
    /// has no name, and one is not a mode.
    private let fixture = """
    {"data":[{"modeConfigurations":{
      "com.apple.focus.work":{"mode":{"name":"Work","modeIdentifier":"com.apple.focus.work",
        "symbolImageName":"briefcase.fill","semanticType":3}},
      "com.apple.donotdisturb.mode.default":{"mode":{"name":"Do Not Disturb",
        "modeIdentifier":"com.apple.donotdisturb.mode.default","symbolImageName":"moon.fill",
        "tintColorName":"systemIndigoColor"}},
      "com.apple.sleep.sleep-mode":{"mode":{"name":"Sleep","modeIdentifier":"com.apple.sleep.sleep-mode",
        "symbolImageName":"bed.double.fill","tintColorName":"systemTealColor"}},
      "com.apple.focus.personal":{"mode":{"name":"personal","modeIdentifier":"com.apple.focus.personal",
        "symbolImageName":"person.fill","tintColorName":"purple"}},
      "com.apple.focus.nameless":{"mode":{"name":"  ","modeIdentifier":"com.apple.focus.nameless"}},
      "com.apple.focus.broken":"not a configuration"
    }},{"modeConfigurations":{
      "com.apple.sleep.sleep-mode":{"mode":{"name":"Sleep again","modeIdentifier":"com.apple.sleep.sleep-mode"}}
    }}]}
    """

    private var modes: [FocusMode] { FocusMode.decode(Data(fixture.utf8)) }

    // MARK: - Reading the modes

    func testTheModesAreReadDoNotDisturbFirstThenByName() {
        XCTAssertEqual(modes.map(\.name), ["Do Not Disturb", "personal", "Sleep", "Work"])
        XCTAssertEqual(modes.first, FocusMode(identifier: "com.apple.donotdisturb.mode.default", name: "Do Not Disturb",
                                              symbol: "moon.fill", tint: "indigo"))
    }

    /// A Focus named in French sorts among the Es, as Finder and the Focus pane sort it, rather
    /// than after "Work" where a comparison of bare code points put the É; and a number in a
    /// name is counted, so "Study 2" comes before "Study 10".
    func testTheModesAreSortedAsFinderSortsNames() {
        func mode(_ name: String) -> String {
            #""m.\#(name)":{"mode":{"name":"\#(name)","modeIdentifier":"m.\#(name)"}}"#
        }
        let names = ["Work", "Écriture", "Study 10", "Driving", "Study 2", "exercise"]
        let json = #"{"data":[{"modeConfigurations":{"# + names.map(mode).joined(separator: ",") + "}}]}"
        XCTAssertEqual(FocusMode.decode(Data(json.utf8)).map(\.name),
                       ["Driving", "Écriture", "exercise", "Study 2", "Study 10", "Work"])
    }

    func testEachModeKeepsItsGlyphAndColour() {
        let sleep = modes.first { $0.identifier == "com.apple.sleep.sleep-mode" }
        XCTAssertEqual(sleep?.name, "Sleep", "listed once, as it is first described")
        XCTAssertEqual(sleep?.symbol, "bed.double.fill")
        XCTAssertEqual(sleep?.tint, "teal")
        let work = modes.first { $0.identifier == "com.apple.focus.work" }
        XCTAssertEqual(work?.tint, "indigo", "no colour is the Focus colour")
        XCTAssertEqual(modes.first { $0.identifier == "com.apple.focus.personal" }?.tint, "purple")
    }

    func testAModeWithNoNameIsNotOffered() {
        // The name is the one thing a pick can hand the shortcut.
        XCTAssertFalse(modes.contains { $0.identifier == "com.apple.focus.nameless" })
        XCTAssertFalse(modes.contains { $0.identifier == "com.apple.focus.broken" })
    }

    func testDoNotDisturbKeepsItsNameWhenTheFileLeavesItOut() {
        let json = #"{"data":[{"modeConfigurations":{"com.apple.donotdisturb.mode.default":{"mode":{}}}}]}"#
        XCTAssertEqual(FocusMode.decode(Data(json.utf8)).map(\.name), ["Do Not Disturb"])
    }

    func testAnythingElseIsNoModes() {
        XCTAssertEqual(FocusMode.decode(Data()), [])
        XCTAssertEqual(FocusMode.decode(Data("[]".utf8)), [])
        XCTAssertEqual(FocusMode.decode(Data(#"{"data":{}}"#.utf8)), [])
        XCTAssertEqual(FocusMode.decode(Data(#"{"data":[{"modeConfigurations":[]}]}"#.utf8)), [])
    }

    func testTheDatabasesColourNamesAreTheIslands() {
        XCTAssertEqual(FocusMode.tint(from: "systemIndigoColor"), "indigo")
        XCTAssertEqual(FocusMode.tint(from: "systemGrayColor"), "gray")
        XCTAssertEqual(FocusMode.tint(from: "Orange"), "orange")
        XCTAssertEqual(FocusMode.tint(from: "#34C759"), "#34C759")
        XCTAssertEqual(FocusMode.tint(from: nil), "indigo")
        XCTAssertEqual(FocusMode.tint(from: "systemColor"), "indigo")
    }

    func testAModeTheFileDoesNotDescribeIsStillNamed() {
        XCTAssertEqual(FocusMode.describe("com.apple.focus.work", in: modes).name, "Work")
        XCTAssertEqual(FocusMode.describe("com.apple.donotdisturb.mode.default", in: []).name, "Do Not Disturb")
        let unknown = FocusMode.describe("com.example.new", in: modes)
        XCTAssertEqual(unknown.name, "Focus")
        XCTAssertEqual(unknown.symbol, "moon.fill")
    }

    // MARK: - What the popover lists

    func testOffFirstThenEveryModeWithTheOneThatIsOnMarked() {
        let picker = FocusPickerRows(modes: modes, active: "com.apple.focus.work", hasShortcut: true)
        XCTAssertEqual(picker.rows.map(\.title), ["Off", "Do Not Disturb", "personal", "Sleep", "Work"])
        XCTAssertEqual(picker.rows.filter(\.isActive).map(\.title), ["Work"])
        XCTAssertFalse(picker.needsShortcut)
        XCTAssertFalse(picker.modesUnread)
        let work = picker.rows.last
        XCTAssertNil(work?.input, "the Focus that is on is already on")
        XCTAssertEqual(work?.spokenValue, "On")
        XCTAssertEqual(picker.rows.first?.input, FocusPickerRows.offInput)
        XCTAssertEqual(picker.rows[3].input, "Sleep", "a mode is handed to the shortcut by name")
    }

    func testWithNoFocusOnOffIsTheOneMarked() {
        let picker = FocusPickerRows(modes: modes, active: nil, hasShortcut: true)
        XCTAssertEqual(picker.rows.filter(\.isActive).map(\.id), [FocusPickerRows.offID])
        XCTAssertNil(picker.rows.first?.input)
        XCTAssertEqual(picker.rows.dropFirst().compactMap(\.input), ["Do Not Disturb", "personal", "Sleep", "Work"])
    }

    func testAFocusTheListDoesNotHaveMarksNothing() {
        let picker = FocusPickerRows(modes: modes, active: "com.example.new", hasShortcut: true)
        XCTAssertTrue(picker.rows.allSatisfy { !$0.isActive })
        XCTAssertEqual(picker.rows.first?.input, "Off", "and it can still be turned off")
    }

    func testWithoutTheShortcutTheListStillSaysWhatIsOnButSetsNothing() {
        let picker = FocusPickerRows(modes: modes, active: "com.apple.sleep.sleep-mode", hasShortcut: false)
        XCTAssertTrue(picker.needsShortcut)
        XCTAssertTrue(picker.rows.allSatisfy { $0.input == nil })
        XCTAssertEqual(picker.rows.filter(\.isActive).map(\.title), ["Sleep"])
        XCTAssertTrue(picker.rows.allSatisfy { $0.spokenHint != nil && $0.help == $0.spokenHint })
        XCTAssertEqual(FocusPickerRows.setupNote,
                       "Make a shortcut named \u{201C}Set Focus\u{201D} that sets Focus from its input")
    }

    func testUnreadTheListIsDoNotDisturbAndNothingIsClaimedToBeOn() {
        // The folder that lists the modes is the one that says which is on.
        let picker = FocusPickerRows(modes: [], active: nil, hasShortcut: true)
        XCTAssertTrue(picker.modesUnread)
        XCTAssertEqual(picker.rows.map(\.title), ["Off", "Do Not Disturb"])
        XCTAssertTrue(picker.rows.allSatisfy { !$0.isActive })
        XCTAssertEqual(picker.rows.compactMap(\.input), ["Off", "Do Not Disturb"])
    }

    func testEveryRowIsNamedForVoiceOver() {
        let picker = FocusPickerRows(modes: modes, active: "com.apple.focus.work", hasShortcut: true)
        XCTAssertTrue(picker.rows.allSatisfy { !$0.spokenLabel.isEmpty })
        XCTAssertEqual(picker.rows.first?.spokenLabel, "Focus off", "a lone Off says nothing about what is off")
        XCTAssertEqual(picker.rows.last?.spokenLabel, "Work")
        XCTAssertEqual(picker.rows.first?.help, "Turn Focus off")
        XCTAssertEqual(picker.rows.last?.help, "Work is on")
        XCTAssertEqual(picker.rows[1].help, "Turn on Do Not Disturb")
        XCTAssertEqual(Set(picker.rows.map(\.id)).count, picker.rows.count, "rows SwiftUI can tell apart")
    }

    // MARK: - Handing a pick to the shortcut

    func testTheShortcutIsFoundAsTheListNamesIt() {
        XCTAssertEqual(FocusSetter.shortcut(in: ["Morning", "Set Focus"]), "Set Focus")
        XCTAssertEqual(FocusSetter.shortcut(in: ["set focus "]), "set focus ", "run by the name the list gave")
        XCTAssertNil(FocusSetter.shortcut(in: ["Set Focus Mode", "Focus"]))
        XCTAssertNil(FocusSetter.shortcut(in: []))
    }

    func testTheInputFileIsNamedAfterTheMode() {
        XCTAssertEqual(FocusSetter.inputFileName(for: "Work"), "Work.txt")
        XCTAssertEqual(FocusSetter.inputFileName(for: FocusPickerRows.offInput), "Off.txt")
        XCTAssertEqual(FocusSetter.inputFileName(for: "Work/Life: Balance"), "Work-Life- Balance.txt")
        XCTAssertEqual(FocusSetter.inputFileName(for: "..hidden"), "hidden.txt")
        XCTAssertEqual(FocusSetter.inputFileName(for: " . "), "Focus.txt")
    }
}
