import XCTest
@testable import MacNotchIsland

/// The island from the keyboard and to VoiceOver: where the panel's own keys go first with
/// Full Keyboard Access on, which of them go on answering when held, and what VoiceOver is told
/// when a timer rings or a script asks a question.
final class KeyboardAccessTests: XCTestCase {
    private typealias Key = HotKeyService.PanelKey

    /// A figure of the number row, standing for every key that types something.
    private var typingKey: Key {
        guard let two = HotKeyService.typingKeys.first(where: { $0.kind == .numberRow && $0.digit == 2 }) else {
            XCTFail("the number row has a 2")
            return .left
        }
        return .typing(two)
    }

    // MARK: - Where a key goes first

    /// With Full Keyboard Access off, nothing on the panel takes the focus from a click, and
    /// every key is the island's first, as it was when they were hot keys.
    func testWithoutFullKeyboardAccessEveryPanelKeyIsTheIslandsFirst() {
        for key in [Key.left, .right, .volumeUp, .volumeDown, .playPause, typingKey] {
            XCTAssertEqual(NotchPanel.route(key, fullKeyboardAccess: false, somethingFocused: true), .island, "\(key)")
            XCTAssertEqual(NotchPanel.route(key, fullKeyboardAccess: false, somethingFocused: false), .island, "\(key)")
        }
    }

    /// With it on, Space is how the button with the focus is pressed, and the arrows are how
    /// a slider or a list with the focus moves; taken first, Space played the music instead.
    func testWithFullKeyboardAccessSpaceAndTheArrowsGoToTheFocusFirst() {
        for key in [Key.left, .right, .volumeUp, .volumeDown, .playPause] {
            XCTAssertEqual(NotchPanel.route(key, fullKeyboardAccess: true, somethingFocused: true), .focusFirst, "\(key)")
        }
        XCTAssertEqual(NotchPanel.route(typingKey, fullKeyboardAccess: true, somethingFocused: true), .island,
                       "nothing the panel focuses types a figure or a letter")
    }

    /// A window that is its own first responder has nothing focused to hand a key to.
    func testWithNothingFocusedTheIslandAnswersFirstEvenWithFullKeyboardAccess() {
        for key in [Key.left, .right, .volumeUp, .volumeDown, .playPause, typingKey] {
            XCTAssertEqual(NotchPanel.route(key, fullKeyboardAccess: true, somethingFocused: false), .island, "\(key)")
        }
    }

    func testOnlyTheVolumeGoesOnAnsweringWhenHeld() {
        XCTAssertTrue(Key.volumeUp.repeats)
        XCTAssertTrue(Key.volumeDown.repeats)
        for key in [Key.left, .right, .playPause, typingKey] {
            XCTAssertFalse(key.repeats, "\(key) held down is one press")
        }
    }

    // MARK: - What VoiceOver is told

    func testATimerThatRingsIsSaidByItsName() {
        XCTAssertEqual(IslandTimer.finishedAnnouncement(label: "Pasta"), "Pasta timer finished")
        XCTAssertEqual(IslandTimer.finishedAnnouncement(label: " Pasta "), "Pasta timer finished")
        XCTAssertEqual(IslandTimer.finishedAnnouncement(label: "Timer"), "Timer finished", "no name of its own")
        XCTAssertEqual(IslandTimer.finishedAnnouncement(label: ""), "Timer finished")
        let phase = PomodoroPhase(kind: .focus, cycle: 2, cycles: 4, work: 25 * 60, rest: 5 * 60)
        XCTAssertEqual(IslandTimer.finishedAnnouncement(label: phase.label, phase: phase),
                       "Focus finished, session 2 of 4")
        // The time is handed in as the Mac's clock would write it, so nothing here depends on
        // the clock or the region the tests run under.
        XCTAssertEqual(IslandTimer.finishedAnnouncement(label: IslandAlarm.defaultLabel, alarmTime: "7:30"),
                       "Alarm ringing, 7:30")
        XCTAssertEqual(IslandTimer.finishedAnnouncement(label: "Gym", alarmTime: "7:30"), "Gym alarm ringing, 7:30")
    }

    func testAQuestionIsSaidWithHowToAnswerIt() {
        let request = AskRequest(title: "Deploy to production?", detail: "main at 4f2c1", yes: "Deploy", no: "Wait",
                                 timeout: 60, reply: nil)
        XCTAssertEqual(request.announcement(keysHeld: true),
                       "Deploy to production? main at 4f2c1. Press Control-Y for Deploy or Control-N for Wait.")
        XCTAssertEqual(request.announcement(keysHeld: false),
                       "Deploy to production? main at 4f2c1. Answer Deploy or Wait on the island.",
                       "keys another app holds are not offered, as the card does not offer them")
        let bare = AskRequest(title: "Ship it", detail: nil, yes: "Yes", no: "No", timeout: 60, reply: nil)
        XCTAssertEqual(bare.announcement(keysHeld: true), "Ship it. Press Control-Y for Yes or Control-N for No.")
    }
}
