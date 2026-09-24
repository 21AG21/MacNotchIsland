import XCTest
@testable import MacNotchIsland

/// Whose microphone it is. The card used to go to the first call app running whenever the
/// microphone came on, so an idle Slack in the background turned Dictation, a voice memo or a
/// call in a browser tab into a "Slack" call at the island's highest priority.
final class CallDetectorTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"
    private let zoom = "us.zoom.xos"
    private let meet = "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"

    // MARK: - macOS 14.2 and later: who is recording

    func testACallAppMerelyRunningIsNotACall() {
        let recording = CallDetector.Evidence.recording(["com.apple.VoiceMemos"])
        XCTAssertNil(CallDetector.callApp(recording, running: [slack, "com.apple.VoiceMemos"]),
                     "a voice memo with Slack open is a voice memo")
        XCTAssertNil(CallDetector.callApp(.recording([]), running: [slack]),
                     "nobody recording is nobody's call")
    }

    func testTheCallAppThatIsRecordingGetsTheCard() {
        XCTAssertEqual(CallDetector.callApp(.recording([zoom]), running: [slack, zoom]), zoom,
                       "the one with the microphone, not the first one running")
    }

    func testAnAppThatRecordsInAHelperIsStillThatApp() {
        XCTAssertEqual(CallDetector.callApp(.recording(["\(slack).helper"]), running: [slack]), slack)
        XCTAssertEqual(CallDetector.callApp(.recording(["com.microsoft.teams2.helper"]), running: []),
                       "com.microsoft.teams2", "and one app's name inside another's is not a match")
    }

    func testFaceTimesDaemonCountsOnlyWhileFaceTimeIsOpen() {
        let daemon = CallDetector.Evidence.recording(["com.apple.avconferenced"])
        XCTAssertEqual(CallDetector.callApp(daemon, running: ["com.apple.FaceTime"]), "com.apple.FaceTime")
        XCTAssertNil(CallDetector.callApp(daemon, running: [slack]))
    }

    func testAWebAppRecordsInItsBrowser() {
        let chrome = CallDetector.Evidence.recording(["com.google.Chrome.helper"])
        XCTAssertEqual(CallDetector.callApp(chrome, running: ["com.google.Chrome", meet]), meet)
        XCTAssertNil(CallDetector.callApp(chrome, running: ["com.google.Chrome", slack]),
                     "a call in a browser tab is not Slack's")
    }

    // MARK: - macOS 14.0 and 14.1: only who is in front

    func testWithoutTheRecordersTheCallAppHasToBeInFront() {
        XCTAssertEqual(CallDetector.callApp(.frontmost(zoom), running: [slack, zoom]), zoom)
        XCTAssertNil(CallDetector.callApp(.frontmost("com.apple.TextEdit"), running: [slack]),
                     "Dictation into TextEdit with Slack in the background")
        XCTAssertNil(CallDetector.callApp(.frontmost(nil), running: [slack]))
    }

    // MARK: - A question macOS would not answer

    func testAnUnansweredQuestionKeepsTheOldRule() {
        XCTAssertEqual(CallDetector.callApp(.unknown, running: ["com.apple.Safari", slack, zoom]), slack)
        XCTAssertNil(CallDetector.callApp(.unknown, running: ["com.apple.Safari"]))
    }
}
