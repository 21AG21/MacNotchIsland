import AppKit
import XCTest
@testable import MacNotchIsland

/// A transport command and the backend's report of it race; these pin down which one the
/// island believes and for how long.
final class NowPlayingReconcileTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func info(_ title: String = "Song", playing: Bool, elapsed: TimeInterval = 30, at date: Date? = nil) -> NowPlayingInfo {
        NowPlayingInfo(title: title, artist: "Band", album: "", duration: 200, elapsed: elapsed, timestamp: date ?? t0,
                       isPlaying: playing, bundleID: "com.apple.Music", artwork: nil, artworkID: 0, accent: .white)
    }

    /// A cover found for a track a player never gave one for has to survive that player's
    /// next report, or it would flash on and off once a second.
    func testAFoundCoverSurvivesTheNextReport() {
        let cover = NSImage(size: NSSize(width: 10, height: 10))
        var withCover = info(playing: true)
        withCover.artwork = cover
        withCover.artworkID = 7
        withCover.accent = .systemPink

        let bare = info(playing: true, elapsed: 31)
        let result = NowPlayingService.reconcile(incoming: bare, current: withCover, optimistic: nil, now: t0 + 1)
        XCTAssertTrue(result.artwork === cover, "the same track keeps the cover we found for it")
        XCTAssertEqual(result.artworkID, 7)
        XCTAssertEqual(result.elapsed, 31, "and the report is believed about everything else")

        let nextTrack = info("Another", playing: true)
        let switched = NowPlayingService.reconcile(incoming: nextTrack, current: withCover, optimistic: nil, now: t0 + 1)
        XCTAssertNil(switched.artwork, "a different track does not inherit it")
    }

    /// A player that does hand over its own artwork always wins.
    func testAPlayersOwnCoverIsNeverReplaced() {
        let mine = NSImage(size: NSSize(width: 10, height: 10))
        let theirs = NSImage(size: NSSize(width: 20, height: 20))
        var current = info(playing: true)
        current.artwork = mine
        var incoming = info(playing: true, elapsed: 31)
        incoming.artwork = theirs
        let result = NowPlayingService.reconcile(incoming: incoming, current: current, optimistic: nil, now: t0 + 1)
        XCTAssertTrue(result.artwork === theirs)
    }

    func testStaleReportInsideWindowKeepsTheUsersState() {
        let current = info(playing: false, elapsed: 30)                       // user just paused
        let pending = NowPlayingService.Optimistic(isPlaying: false, elapsed: nil, at: t0, until: t0 + 1.2)
        let stale = info(playing: true, elapsed: 30)                          // backend has not caught up
        let result = NowPlayingService.reconcile(incoming: stale, current: current, optimistic: pending, now: t0 + 0.3)
        XCTAssertFalse(result.isPlaying)
        XCTAssertEqual(result.elapsed, 30, accuracy: 0.01, "paused: the clock stays where the user left it")
    }

    func testReportAfterWindowIsBelieved() {
        let current = info(playing: false)
        let pending = NowPlayingService.Optimistic(isPlaying: false, elapsed: nil, at: t0, until: t0 + 1.2)
        let late = info(playing: true)
        XCTAssertTrue(NowPlayingService.reconcile(incoming: late, current: current, optimistic: pending, now: t0 + 2).isPlaying)
    }

    func testDifferentTrackIsAlwaysBelieved() {
        let current = info(playing: false)
        let pending = NowPlayingService.Optimistic(isPlaying: false, elapsed: nil, at: t0, until: t0 + 1.2)
        let next = info("Other", playing: true)
        XCTAssertTrue(NowPlayingService.reconcile(incoming: next, current: current, optimistic: pending, now: t0 + 0.1).isPlaying)
    }

    func testAgreementEndsTheWindowEarly() {
        let pending = NowPlayingService.Optimistic(isPlaying: false, elapsed: nil, at: t0, until: t0 + 1.2)
        XCTAssertTrue(NowPlayingService.agrees(info(playing: false), with: pending, now: t0))
        XCTAssertFalse(NowPlayingService.agrees(info(playing: true), with: pending, now: t0))
        let seek = NowPlayingService.Optimistic(isPlaying: nil, elapsed: 90, at: t0, until: t0 + 1.2)
        XCTAssertTrue(NowPlayingService.agrees(info(playing: true, elapsed: 90.4), with: seek, now: t0))
        XCTAssertFalse(NowPlayingService.agrees(info(playing: true, elapsed: 30), with: seek, now: t0))
    }

    func testSeekIsNotUndoneByAStaleElapsedTime() {
        let current = info(playing: true, elapsed: 90, at: t0)                // user just seeked to 1:30
        let pending = NowPlayingService.Optimistic(isPlaying: nil, elapsed: 90, at: t0, until: t0 + 1.2)
        let stale = info(playing: true, elapsed: 30, at: t0)
        let result = NowPlayingService.reconcile(incoming: stale, current: current, optimistic: pending, now: t0 + 0.2)
        XCTAssertEqual(result.position(at: t0 + 0.2), 90.2, accuracy: 0.05, "the seek target, advanced by the time since")
    }
}
