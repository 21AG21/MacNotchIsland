import AppKit
import Combine

/// Publishes what's playing system-wide and exposes transport controls.
///
/// Three backends, best first:
/// 1. MediaRemoteAdapter running inside /usr/bin/perl (works on every macOS version and
///    for every app, because the host process is Apple-signed).
/// 2. MediaRemote called directly (works before macOS 15.4).
/// 3. An AppleScript poller for Music and Spotify, only while nothing else delivers.
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    enum Backend { case inactive, adapter, mediaRemote, appleScript }

    @Published private(set) var info: NowPlayingInfo?

    private let adapter = AdapterBackend()
    private let mediaRemote = MediaRemoteBackend()
    private let appleScript = AppleScriptBackend()
    private var running = false
    private var pollTimer: Timer?
    private var pausedSince: Date?
    private var ticks = 0
    private(set) var activeBackend: Backend = .inactive
    /// What the user just asked for, held against stale backend reports for a moment.
    private var optimistic: Optimistic?
    /// A pending removal of the Now Playing card, see `clearGrace`.
    private var clearWork: DispatchWorkItem?

    /// A transport command takes a few hundred milliseconds to round-trip through
    /// MediaRemote, and the first report after it can still carry the old state (the playback
    /// rate and the elapsed time arrive separately from the is-playing notification). Until
    /// `until`, reports for the same track are read with this state instead, so the button
    /// never flips back and forth.
    struct Optimistic: Equatable {
        var isPlaying: Bool?
        /// Where the user put the playhead, as of `at`.
        var elapsed: TimeInterval?
        var at: Date
        var until: Date

        /// Where the playhead should be now if the backend had kept up.
        func expectedPosition(at now: Date, playing: Bool) -> TimeInterval? {
            guard let elapsed else { return nil }
            return elapsed + (playing ? max(0, now.timeIntervalSince(at)) : 0)
        }
    }

    static let optimisticWindow: TimeInterval = 1.2

    /// MediaRemote hands out an empty report for a moment between tracks and whenever a player
    /// rebuilds its state. Ending the card on the first one would flash the island, and close
    /// the expanded view if it was open, several times an album. An empty report has to hold
    /// this long before the card goes.
    static let clearGrace: TimeInterval = 2.5

    private init() {}

    /// `NOTCH_FAKE_TRACK=1` in the environment plays a made-up track with artwork instead of
    /// asking any player, so the Now Playing card can be exercised on a machine (CI) with
    /// nothing playing.
    static var fakesTrack: Bool { ProcessInfo.processInfo.environment["NOTCH_FAKE_TRACK"] == "1" }

    static func fakeTrack() -> NowPlayingInfo {
        let image = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(starting: .systemPink, ending: .systemIndigo)?.draw(in: rect, angle: 45)
            return true
        }
        return NowPlayingInfo(title: "Smoke Test", artist: "Notch Island", album: "Continuous Integration",
                              duration: 214, elapsed: 61, timestamp: Date(), isPlaying: true, bundleID: "com.apple.Music",
                              artwork: image, artworkID: 1, accent: image.dominantColor())
    }

    func start() {
        guard !running else { return }
        running = true
        if Self.fakesTrack {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.handle(Self.fakeTrack(), from: .adapter) }
            return
        }
        adapter.onUpdate = { [weak self] info in self?.handle(info, from: .adapter) }
        adapter.start()
        mediaRemote.onUpdate = { [weak self] info in
            DispatchQueue.main.async { self?.handle(info, from: .mediaRemote) }
        }
        mediaRemote.start()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        pollTimer?.tolerance = 0.2
    }

    func stop() {
        guard running else { return }
        running = false
        pollTimer?.invalidate()
        pollTimer = nil
        appleScript.cancel()
        adapter.stop()
        mediaRemote.stop()
        clear()
    }

    private func tick() {
        ticks += 1
        // AppleScript polling spawns a real process; keep it off entirely while asleep, and
        // back off to every 4s (instead of 2s) on battery.
        let energy = EnergyPolicy.shared
        let pollEvery = energy.isOnBattery ? 4 : 2
        // Answering, not playing. A helper that is alive and says nothing is playing has told
        // us the truth, and there is nothing for AppleScript to add — asking it anyway meant a
        // working Mac with the music stopped fired a round trip at Music and at Spotify every
        // two seconds for as long as it was switched on, each one able to raise an Automation
        // prompt. The fallback is for a backend that has gone quiet, which is a different thing.
        if !energy.isAsleep, !adapter.isAnswering, !mediaRemote.isHealthy, ticks % pollEvery == 0 {
            appleScript.poll { [weak self] info in self?.handle(info, from: .appleScript) }
        } else if activeBackend == .mediaRemote {
            // Refresh periodically so elapsed time can't drift after seeks made elsewhere.
            mediaRemote.refreshIfStale()
        }
        if let info, !info.isPlaying, let since = pausedSince, !ActivityCenter.shared.isPanelShowing {
            // 0 means "clear as soon as playback pauses"; otherwise keep the paused track around.
            // Never while the user has the card open in front of them.
            let limit = Preferences.shared.keepPausedMinutes * 60
            if limit <= 0 || Date().timeIntervalSince(since) > limit { clear() }
        }
    }

    private func handle(_ new: NowPlayingInfo?, from backend: Backend) {
        guard running else { return }   // a late poll must not bring the pill back after stop()
        // Lower-ranked backends stay quiet once a better one is delivering.
        if backend == .appleScript && (adapter.isAnswering || mediaRemote.isHealthy) { return }
        if backend == .mediaRemote && adapter.isAnswering { return }

        guard let new = new.map(Self.sanitized) else {
            if activeBackend == backend || activeBackend == .inactive { scheduleClear() }
            return
        }
        clearWork?.cancel()
        clearWork = nil
        activeBackend = backend
        let now = Date()
        let reconciled = Self.reconcile(incoming: new, current: info, optimistic: optimistic, now: now)
        if let pending = optimistic, pending.until <= now || Self.agrees(new, with: pending, now: now) {
            optimistic = nil
        }
        if reconciled.isPlaying {
            pausedSince = nil
        } else if pausedSince == nil {
            pausedSince = now
        }
        let previous = info
        if info != reconciled { info = reconciled }
        publish()
        lookUpArtworkIfMissing(for: reconciled)
        if Self.isNewTrack(reconciled, after: previous) { peek(reconciled) }
    }

    /// Fills in a cover the player did not give us, see `ArtworkFetcher`. A track that already
    /// has artwork, or a player the user asked not to look up, is left alone.
    private func lookUpArtworkIfMissing(for track: NowPlayingInfo) {
        guard Preferences.shared.artworkLookupEnabled, track.artwork == nil, !track.title.isEmpty else { return }
        ArtworkFetcher.shared.artwork(for: track) { [weak self] image in
            guard let self, var current = self.info, Self.sameTrack(current, track), current.artwork == nil else { return }
            current.artwork = image
            current.artworkID = ArtworkFetcher.Key(track).hashValue
            current.accent = image.dominantColor()
            self.info = current
            self.publish()
        }
    }

    /// The alert id of the sneak peek: the compact pill widened for a moment with the title
    /// and artist of a track that just started.
    static let peekAlertID = "nowplaying-peek"

    /// A track worth announcing: playing, and not the one that was playing a moment ago.
    static func isNewTrack(_ new: NowPlayingInfo, after previous: NowPlayingInfo?) -> Bool {
        guard new.isPlaying, !new.title.isEmpty else { return false }
        guard let previous else { return true }
        return !sameTrack(new, previous)
    }

    private func peek(_ track: NowPlayingInfo) {
        guard Preferences.shared.sneakPeekEnabled, !ActivityCenter.shared.isPanelShowing else { return }
        let alert = IslandActivity(id: Self.peekAlertID, kind: .nowPlaying, content: .nowPlaying(track), priority: 60)
        ActivityCenter.shared.showAlert(alert, duration: 2.4, haptic: false)
    }

    /// A report as the island can use it. Players hand out infinite durations for live
    /// streams, NaN positions for tracks they have not measured, and timestamps from nowhere;
    /// none of those may reach arithmetic that ends in an `Int`, so they are zeroed here, once,
    /// at the boundary.
    static func sanitized(_ info: NowPlayingInfo) -> NowPlayingInfo {
        var result = info
        if !result.duration.isFinite || result.duration < 0 { result.duration = 0 }
        if !result.elapsed.isFinite || result.elapsed < 0 { result.elapsed = 0 }
        if !result.timestamp.timeIntervalSinceReferenceDate.isFinite { result.timestamp = Date() }
        return result
    }

    /// The report the island should believe. Inside the optimistic window, a report about the
    /// same track that contradicts what the user just did is corrected to the user's state; a
    /// different track, or anything after the window, is taken as is.
    static func reconcile(incoming: NowPlayingInfo, current: NowPlayingInfo?, optimistic: Optimistic?, now: Date) -> NowPlayingInfo {
        let incoming = carryingArtwork(into: incoming, from: current)
        guard let optimistic, now < optimistic.until, let current, sameTrack(incoming, current) else { return incoming }
        var result = incoming
        if let isPlaying = optimistic.isPlaying, incoming.isPlaying != isPlaying {
            result.isPlaying = isPlaying
            // Keep the clock the user is looking at, not the stale one the backend still holds.
            result.elapsed = current.position(at: now)
            result.timestamp = now
        }
        if let expected = optimistic.expectedPosition(at: now, playing: result.isPlaying),
           abs(incoming.position(at: now) - expected) > 1.5 {
            result.elapsed = expected
            result.timestamp = now
        }
        return result
    }

    /// A cover found for the track that is playing survives the next report about it.
    ///
    /// The players that hand over no artwork hand over none every second, and `ArtworkFetcher`
    /// only fills the gap once. Without this the cover would appear and vanish on every poll.
    static func carryingArtwork(into incoming: NowPlayingInfo, from current: NowPlayingInfo?) -> NowPlayingInfo {
        guard incoming.artwork == nil, let current, current.artwork != nil, sameTrack(incoming, current) else { return incoming }
        var result = incoming
        result.artwork = current.artwork
        result.artworkID = current.artworkID
        result.accent = current.accent
        return result
    }

    static func sameTrack(_ a: NowPlayingInfo, _ b: NowPlayingInfo) -> Bool {
        a.title == b.title && a.artist == b.artist && a.bundleID == b.bundleID
    }

    /// True once the backend has caught up with the user's request.
    static func agrees(_ report: NowPlayingInfo, with pending: Optimistic, now: Date) -> Bool {
        if let isPlaying = pending.isPlaying, report.isPlaying != isPlaying { return false }
        if let expected = pending.expectedPosition(at: now, playing: report.isPlaying),
           abs(report.position(at: now) - expected) > 1.5 { return false }
        return true
    }

    private func scheduleClear() {
        guard clearWork == nil, info != nil || ActivityCenter.shared.activity(id: "nowplaying") != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.clearWork = nil
            self?.clear()
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearGrace, execute: work)
    }

    private func clear() {
        clearWork?.cancel()
        clearWork = nil
        guard info != nil || ActivityCenter.shared.activity(id: "nowplaying") != nil else { return }
        info = nil
        pausedSince = nil
        activeBackend = .inactive
        ActivityCenter.shared.end(id: "nowplaying")
    }

    private func publish() {
        guard let info else { return }
        var activity = IslandActivity(id: "nowplaying", kind: .nowPlaying, content: .nowPlaying(info), priority: 50)
        if let bundle = info.bundleID { activity.openAction = .app(bundleID: bundle) }
        ActivityCenter.shared.upsert(activity)
    }

    // MARK: Controls

    func togglePlayPause() {
        switch activeBackend {
        case .appleScript: appleScript.command(.togglePlayPause, bundleID: info?.bundleID)
        case .adapter: adapter.send("toggle")
        default: mediaRemote.send(.togglePlayPause)
        }
        optimisticallyToggle()
    }

    /// Stops whatever is playing, and does nothing at all when nothing is. What a sleep timer
    /// asks for at the end of it: `togglePlayPause` on a Mac that has already gone quiet would
    /// start the music up again, which is the one thing it must not do.
    func pauseIfPlaying() {
        guard info?.isPlaying == true else { return }
        togglePlayPause()
    }

    func next() {
        switch activeBackend {
        case .appleScript: appleScript.command(.next, bundleID: info?.bundleID)
        case .adapter: adapter.send("next")
        default: mediaRemote.send(.nextTrack)
        }
    }

    func previous() {
        switch activeBackend {
        case .appleScript: appleScript.command(.previous, bundleID: info?.bundleID)
        case .adapter: adapter.send("previous")
        default: mediaRemote.send(.previousTrack)
        }
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        switch activeBackend {
        case .appleScript: appleScript.seek(to: seconds, bundleID: info?.bundleID)
        case .adapter: adapter.send("seek \(Int(seconds))")
        default: mediaRemote.seek(to: seconds)
        }
        if var i = info {
            let now = Date()
            i.elapsed = seconds
            i.timestamp = now
            info = i
            optimistic = Optimistic(isPlaying: optimistic?.isPlaying, elapsed: seconds, at: now, until: now + Self.optimisticWindow)
            publish()
        }
    }

    func openApp() {
        if let bundle = info?.bundleID { OpenAction.app(bundleID: bundle).perform() }
    }

    private func optimisticallyToggle() {
        guard var i = info else { return }
        let now = Date()
        i.elapsed = i.position(at: now)
        i.timestamp = now
        i.isPlaying.toggle()
        info = i
        optimistic = Optimistic(isPlaying: i.isPlaying, elapsed: nil, at: now, until: now + Self.optimisticWindow)
        publish()
    }
}
