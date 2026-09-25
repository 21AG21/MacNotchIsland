import AppKit
import XCTest
@testable import MacNotchIsland

/// The microphone mute, the call card's controls, keeping the island out of a screen share,
/// and the screen recorder: every decision among them that can be read back without a
/// microphone, a call or a screen to record.
final class MicrophoneAndRecordingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let utc = TimeZone(identifier: "UTC")!
    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                         notchWidth: 200, notchHeight: 32, hasPhysicalNotch: true)

    // MARK: - Mute, or fall back to the level

    func testAMicrophoneWithAMuteIsMutedByIt() {
        XCTAssertEqual(MicrophoneControl.route(muteSettable: true, volumeSettable: false), .mute)
        // The mute first, always: a level at zero is a mute that forgets where it was.
        XCTAssertEqual(MicrophoneControl.route(muteSettable: true, volumeSettable: true), .mute)
    }

    func testAMicrophoneWithOnlyALevelIsMutedByTurningItDown() {
        XCTAssertEqual(MicrophoneControl.route(muteSettable: false, volumeSettable: true), .volume)
    }

    func testAMicrophoneWithNeitherCannotBeMutedFromHere() {
        XCTAssertEqual(MicrophoneControl.route(muteSettable: false, volumeSettable: false), .unavailable)
    }

    func testWhetherItReadsAsMutedFollowsTheRouteItIsMutedBy() {
        XCTAssertTrue(MicrophoneControl.isMuted(route: .mute, mute: true, level: 0.8))
        XCTAssertFalse(MicrophoneControl.isMuted(route: .mute, mute: false, level: 0),
                       "a device with a mute is muted by its mute, not by its level")
        XCTAssertFalse(MicrophoneControl.isMuted(route: .mute, mute: nil, level: nil), "unreadable is not muted")
        XCTAssertTrue(MicrophoneControl.isMuted(route: .volume, mute: nil, level: 0))
        XCTAssertFalse(MicrophoneControl.isMuted(route: .volume, mute: nil, level: 0.5))
        XCTAssertFalse(MicrophoneControl.isMuted(route: .volume, mute: nil, level: nil),
                       "a level that cannot be read is not claimed to be silence")
        XCTAssertFalse(MicrophoneControl.isMuted(route: .unavailable, mute: true, level: 0))
    }

    func testUnmutingByLevelPutsBackTheLevelItHad() {
        XCTAssertEqual(MicrophoneControl.restoredLevel(saved: 0.42), 0.42, accuracy: 0.0001)
        XCTAssertEqual(MicrophoneControl.restoredLevel(saved: 1.4), 1, accuracy: 0.0001, "never past the top")
    }

    func testALevelNeverSeenComesBackPlainlyOn() {
        // Already at nothing when the island first met it: silence is not a level to restore.
        for saved: Float32? in [nil, 0, 0.0005, Float32.nan, -0.3] {
            XCTAssertEqual(MicrophoneControl.restoredLevel(saved: saved), MicrophoneControl.defaultLevel,
                           "\(String(describing: saved))")
        }
        XCTAssertGreaterThan(MicrophoneControl.defaultLevel, 0.5)
        XCTAssertLessThan(MicrophoneControl.defaultLevel, 1)
    }

    // MARK: - The call card and pill

    func testTheCallCardIsTallEnoughForItsControls() {
        let call = ActivityContent.call(CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: now))
        XCTAssertEqual(ActivityContent.cardCallControls, 8 + 28, "8 pt of air and a 28 pt row of pills")
        XCTAssertEqual(call.cardHeight, 12 + 44 + 8 + 28 + 16)
        XCTAssertEqual(call.cardHeight, ActivityContent.cardRow + ActivityContent.cardCallControls)
        XCTAssertLessThanOrEqual(IslandLayout.cardTopBand(geometry) + call.cardHeight, NotchPanel.canvasHeight,
                                 "the card still fits the window it is drawn in")
    }

    func testAMutedCallSaysSo() {
        let call = CallState(appName: "FaceTime", bundleID: "com.apple.FaceTime", startedAt: now.addingTimeInterval(-130))
        XCTAssertEqual(IslandAccessibility.compactLabel(for: .call(call), at: now, micMuted: true),
                       "Call with FaceTime, 2:10, microphone muted")
        XCTAssertEqual(IslandAccessibility.compactLabel(for: .call(call), at: now), "Call with FaceTime, 2:10")
        // Anything else is not a call, and a muted microphone is not its news.
        XCTAssertEqual(IslandAccessibility.compactLabel(for: .custom(CustomActivity(title: "Build")), at: now, micMuted: true),
                       "Build")
    }

    // MARK: - Out of a screen share

    func testTheIslandIsSharedOnlyWhenNothingSaysToHideIt() {
        XCTAssertEqual(NotchPanel.sharesScreen(hidden: false, duringCalls: false, inCall: false), .readOnly)
        XCTAssertEqual(NotchPanel.sharesScreen(hidden: false, duringCalls: false, inCall: true), .readOnly,
                       "a call hides nothing unless that was asked for")
        XCTAssertEqual(NotchPanel.sharesScreen(hidden: false, duringCalls: true, inCall: false), .readOnly,
                       "during calls means during calls")
        XCTAssertEqual(NotchPanel.sharesScreen(hidden: false, duringCalls: true, inCall: true), NSWindow.SharingType.none)
        for duringCalls in [false, true] {
            for inCall in [false, true] {
                XCTAssertEqual(NotchPanel.sharesScreen(hidden: true, duringCalls: duringCalls, inCall: inCall),
                               NSWindow.SharingType.none, "hidden always is hidden always")
            }
        }
    }

    func testTheShippingChoiceReadsAsBothSwitchesOn() {
        // Not always, but during calls: the main switch on, and "Only during calls" on.
        let shown = ScreenSharingSwitches.shown(hidden: false, duringCalls: true)
        XCTAssertTrue(shown.hide)
        XCTAssertTrue(shown.onlyDuringCalls)
    }

    func testTheSwitchesAndThePreferencesAgree() {
        let off = ScreenSharingSwitches.shown(hidden: false, duringCalls: false)
        XCTAssertFalse(off.hide)
        XCTAssertFalse(off.onlyDuringCalls)
        let always = ScreenSharingSwitches.shown(hidden: true, duringCalls: false)
        XCTAssertTrue(always.hide)
        XCTAssertFalse(always.onlyDuringCalls)
        // Both stored — by hand, in defaults — is always, which is what the panel does with it.
        let both = ScreenSharingSwitches.shown(hidden: true, duringCalls: true)
        XCTAssertTrue(both.hide)
        XCTAssertFalse(both.onlyDuringCalls)

        // Every choice the switches can make is stored as something that reads back the same.
        for (hide, only) in [(false, false), (true, false), (true, true)] {
            let stored = ScreenSharingSwitches.stored(hide: hide, onlyDuringCalls: only)
            let read = ScreenSharingSwitches.shown(hidden: stored.hidden, duringCalls: stored.duringCalls)
            XCTAssertEqual(read.hide, hide, "\(hide) \(only)")
            XCTAssertEqual(read.onlyDuringCalls, hide && only, "\(hide) \(only)")
        }
        let cleared = ScreenSharingSwitches.stored(hide: false, onlyDuringCalls: true)
        XCTAssertFalse(cleared.hidden)
        XCTAssertFalse(cleared.duringCalls, "switching it off switches all of it off")
    }

    // MARK: - The recorder

    func testARecordingIsNamedTheWayMacOSNamesOne() {
        let name = ScreenRecorder.fileName(at: now, timeZone: utc)
        XCTAssertEqual(name, "Screen Recording 2026-09-21 at 14.13.20.mov")
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot(name))
        XCTAssertTrue(ScreenshotMonitor.isCandidate(name: name), "so the shelf and the card take it as a capture")
    }

    func testASecondRecordingInTheSameSecondDoesNotOverwriteTheFirst() {
        let folder = URL(fileURLWithPath: "/Users/you/Desktop", isDirectory: true)
        let first = folder.appendingPathComponent("Screen Recording 2026-09-21 at 14.13.20.mov")
        XCTAssertEqual(ScreenRecorder.unique(first, exists: { _ in false }), first)
        let taken: Set<String> = [first.path, folder.appendingPathComponent("Screen Recording 2026-09-21 at 14.13.20 2.mov").path]
        XCTAssertEqual(ScreenRecorder.unique(first, exists: { taken.contains($0) }).lastPathComponent,
                       "Screen Recording 2026-09-21 at 14.13.20 3.mov")
    }

    func testItIsApplesOwnToolAskedForAMovie() {
        let file = URL(fileURLWithPath: "/Users/you/Desktop/Screen Recording.mov")
        XCTAssertEqual(ScreenRecorder.tool, "/usr/sbin/screencapture")
        XCTAssertEqual(ScreenRecorder.arguments(for: file), ["-v", "/Users/you/Desktop/Screen Recording.mov"])
    }

    func testAMovieWithAnythingInItIsKept() {
        XCTAssertEqual(ScreenRecorder.outcome(fileSize: 1_048_576), .saved)
        XCTAssertEqual(ScreenRecorder.outcome(fileSize: 1), .saved)
        XCTAssertEqual(ScreenRecorder.outcome(fileSize: 0), .nothingRecorded, "an empty file is not a recording")
        XCTAssertEqual(ScreenRecorder.outcome(fileSize: nil), .nothingRecorded)
    }

    func testTheRecordingRunsItsClockAndCarriesStop() {
        let recording = ScreenRecorder.activity(since: now, saving: false, folder: "Desktop")
        XCTAssertEqual(recording.title, "Recording")
        XCTAssertEqual(recording.subtitle, "To Desktop")
        XCTAssertEqual(recording.tint, "red")
        XCTAssertEqual(recording.countsUpFrom, now)
        XCTAssertEqual(recording.actions.count, 1)
        XCTAssertEqual(recording.actions.first?.command, .stopRecording)
        XCTAssertTrue(recording.actions.first?.isUsable ?? false, "a button that only runs a command is a button")
        XCTAssertEqual(ActivityContent.custom(recording).compactWidths.trailing, 60, "the call's slot, for the call's digits")
        XCTAssertEqual(IslandAccessibility.compactLabel(for: .custom(recording), at: now.addingTimeInterval(65)),
                       "Recording, 1:05")
        XCTAssertEqual(ActivityContent.custom(recording).cardHeight, ActivityContent.cardRow)
    }

    func testWhileTheMovieIsBeingFinishedThereIsNoStopToPressTwice() {
        let saving = ScreenRecorder.activity(since: now, saving: true, folder: "Desktop")
        XCTAssertTrue(saving.actions.isEmpty)
        XCTAssertNil(saving.countsUpFrom)
        XCTAssertEqual(saving.trailingText, "Saving")
    }

    func testARefusalSaysWhereThePermissionIs() {
        let action = ScreenRecorder.refusal.actions.first
        XCTAssertEqual(action?.url?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertNil(action?.command)
        XCTAssertLessThanOrEqual(ScreenRecorder.refusal.actions.count, LiveActivityAPI.maxActions)
    }

    func testTheWatcherLeavesAClaimedFileAlone() {
        let file = URL(fileURLWithPath: "/tmp/claimed-\(UUID().uuidString)/Screen Recording 2026-09-21 at 14.13.20.mov")
        XCTAssertFalse(ScreenshotMonitor.isClaimed(file.path))
        ScreenshotMonitor.claim(file)
        XCTAssertTrue(ScreenshotMonitor.isClaimed(file.path))
    }

    /// The claim is only worth anything if the watcher's walk reads it. This is the filter the
    /// walk runs on a folder's entries, before it asks the file system about any of them.
    func testTheWatchersCandidateListSkipsAClaimedFile() {
        let folder = URL(fileURLWithPath: "/tmp/claimed-\(UUID().uuidString)", isDirectory: true)
        let movie = folder.appendingPathComponent("Screen Recording 2026-09-21 at 14.13.20.mov")
        let shot = folder.appendingPathComponent("Screenshot 2026-09-21 at 14.13.21.png")
        let notes = folder.appendingPathComponent("Notes.txt")
        let items = [movie, shot, notes]

        XCTAssertEqual(ScreenshotMonitor.unhandled(items, seen: [], settling: []), [movie, shot],
                       "unclaimed, a half-made movie looks exactly like a capture that has just landed")
        ScreenshotMonitor.claim(movie)
        XCTAssertEqual(ScreenshotMonitor.unhandled(items, seen: [], settling: []), [shot],
                       "claimed, it is walked past, and the screenshot beside it is not")
        // And the two other reasons to walk past an entry are still the watcher's own.
        XCTAssertEqual(ScreenshotMonitor.unhandled(items, seen: [shot.path], settling: []), [])
        XCTAssertEqual(ScreenshotMonitor.unhandled(items, seen: [], settling: [shot.path]), [])
    }

    // MARK: - The system's own keystrokes

    func testTheLockIsControlCommandQ() {
        XCTAssertEqual(SystemActions.lockKeyCode, 0x0C, "Q's position on the keyboard")
        XCTAssertTrue(SystemActions.lockFlags.contains(.maskControl))
        XCTAssertTrue(SystemActions.lockFlags.contains(.maskCommand))
        XCTAssertFalse(SystemActions.lockFlags.contains(.maskShift), "Shift makes it Log Out")
        XCTAssertFalse(SystemActions.lockFlags.contains(.maskAlternate))
    }
}
