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

    // MARK: - Whether the microphone is on at all

    /// AirPods and most USB headsets are one device for both directions, and "running somewhere"
    /// is a property of the whole device: music on them read as a microphone in use, lit the
    /// dot, and left a call started on them with nothing to notice.
    func testMusicOnAHeadsetIsNotTheMicrophone() {
        XCTAssertFalse(AudioMonitor.micInUse(deviceRunning: true, hasOutput: true, recorders: []),
                       "a headset playing, with nobody recording, is a headset playing")
        XCTAssertTrue(AudioMonitor.micInUse(deviceRunning: true, hasOutput: true, recorders: [zoom]))
        XCTAssertTrue(AudioMonitor.micInUse(deviceRunning: false, hasOutput: false, recorders: ["pid 4321"]),
                      "a recorder with no bundle has the microphone all the same")
    }

    func testWithoutTheRecordersOnlyAMicrophoneThatIsOnlyAMicrophoneIsBelieved() {
        XCTAssertTrue(AudioMonitor.micInUse(deviceRunning: true, hasOutput: false, recorders: nil),
                      "the built-in microphone runs only while something records from it")
        XCTAssertFalse(AudioMonitor.micInUse(deviceRunning: true, hasOutput: true, recorders: nil),
                       "a headset running may only be playing")
        XCTAssertFalse(AudioMonitor.micInUse(deviceRunning: false, hasOutput: false, recorders: nil))
    }

    // MARK: - Looking again

    /// The Bool alone was the key, so a microphone already on when a call started — Dictation
    /// left running, a voice memo — never had the call looked at.
    func testANewRecorderWhileTheMicrophoneIsAlreadyOnIsLookedAt() {
        let memo = AudioMonitor.Microphone(inUse: true, recorders: ["com.apple.VoiceMemos"])
        let call = AudioMonitor.Microphone(inUse: true, recorders: ["com.apple.VoiceMemos", zoom])
        XCTAssertTrue(CallDetector.reexamines(from: memo, to: call), "the Bool did not move; the recorders did")
        XCTAssertEqual(CallDetector.step(inUse: true, evidence: .recording(["com.apple.VoiceMemos", zoom]),
                                         running: [zoom], current: nil),
                       .begin(zoom))
    }

    func testTheSameRecordersInAnotherOrderAreNoChange() {
        let one = AudioMonitor.Microphone(inUse: true, recorders: [zoom, "com.apple.VoiceMemos"])
        let other = AudioMonitor.Microphone(inUse: true, recorders: ["com.apple.VoiceMemos", zoom])
        XCTAssertFalse(CallDetector.reexamines(from: one, to: other))
    }

    func testACallGoesOnWhileItsAppIsStillRecording() {
        let both = CallDetector.Evidence.recording(["com.apple.VoiceMemos", "\(zoom).helper"])
        XCTAssertEqual(CallDetector.step(inUse: true, evidence: both, running: [zoom], current: zoom), .keep,
                       "a voice memo starting in the middle of a call is not a new call")
        XCTAssertEqual(CallDetector.step(inUse: true, evidence: .recording([slack, zoom]), running: [slack, zoom],
                                         current: zoom),
                       .keep, "and a second call app recording does not take the card from the first")
    }

    /// A card used to outlive its call for as long as something else kept the microphone on.
    func testACallEndsWhenItsAppStopsRecordingWhateverElseStillIs() {
        XCTAssertEqual(CallDetector.step(inUse: true, evidence: .recording(["com.apple.VoiceMemos"]),
                                         running: [zoom], current: zoom),
                       .end)
        XCTAssertEqual(CallDetector.step(inUse: true, evidence: .recording([slack]), running: [slack, zoom],
                                         current: zoom),
                       .begin(slack), "one call hung up and another answered")
        XCTAssertEqual(CallDetector.step(inUse: false, evidence: .recording([]), running: [zoom], current: zoom), .end)
        XCTAssertEqual(CallDetector.step(inUse: false, evidence: .recording([]), running: [zoom], current: nil), .keep)
    }

    func testWithoutTheRecordersACallLastsAsLongAsTheMicrophone() {
        XCTAssertEqual(CallDetector.step(inUse: true, evidence: .frontmost("com.apple.TextEdit"), running: [zoom],
                                         current: zoom),
                       .keep, "switching away from the call is not hanging up")
        XCTAssertEqual(CallDetector.step(inUse: true, evidence: .unknown, running: [zoom], current: zoom), .keep)
        XCTAssertEqual(CallDetector.step(inUse: false, evidence: .frontmost(zoom), running: [zoom], current: zoom), .end)
    }
}
