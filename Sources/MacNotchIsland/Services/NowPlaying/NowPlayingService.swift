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

    /// What a backend can be said to be doing, in the terms the Settings pane puts to the user.
    ///
    /// Four words — live, answering with nothing, given up, unavailable — were not enough. Two
    /// of the three backends are deliberately not asked while a better one is answering:
    /// MediaRemote's reports are dropped behind the helper, AppleScript's behind both. A
    /// backend that is not being asked is neither broken nor idle, and calling it "not
    /// answering" would send people to restart a thing that is fine, on every healthy Mac.
    enum Health: Equatable {
        /// Answering, and the last answer was a track. This is where the card comes from.
        case live
        /// Answering, and the last answer was that there is no track. A healthy Mac with the
        /// music off looks like this — and on macOS 15.4 and later so does MediaRemote itself
        /// whatever is playing, which is the whole reason the helper exists.
        case idle
        /// Held back, because a better backend is answering.
        case standingBy
        /// Switched on and not heard from: a helper that has died and is waiting to be tried
        /// again, or a framework that has stopped answering.
        case givenUp
        /// Cannot run on this Mac.
        case unavailable
    }

    @Published private(set) var info: NowPlayingInfo?

    /// The word for each backend, see `Health`. Refreshed on every tick, and empty while Now
    /// Playing is switched off: nothing honest can be said about backends that have not been
    /// asked. Written on the main queue only, like everything else this class publishes.
    @Published private(set) var health: [Backend: Health] = [:]

    private let adapter = AdapterBackend()
    private let mediaRemote = MediaRemoteBackend()
    private let appleScript = AppleScriptBackend()
    private var running = false
    private var pollTimer: Timer?
    private var pausedSince: Date?
    /// The paused track "Keep paused music for" last took off the island, see `staysDismissed`.
    private var dismissedPaused: NowPlayingInfo?
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
        /// The shuffle and the repeat the user just asked for. They round-trip the same way the
        /// play button does, and the glyph must not flick back to the old mode meanwhile.
        var shuffle: Bool? = nil
        var repeatMode: NowPlayingInfo.RepeatMode? = nil

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
        refreshHealth()
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
        // Switched back on, the paused track is news again.
        dismissedPaused = nil
        scriptedModes = nil
        refreshHealth()
    }

    /// Quits the helper and starts it again, now, at the user's request.
    ///
    /// `AdapterBackend` restarts a dead helper on its own, but after a run of crashes it rests
    /// for five minutes first, and somebody looking at a blank card in Settings should not have
    /// to sit that out. Starting the backend afresh wipes its count of deaths, which is what
    /// makes this the way past a rest rather than one more turn of it. The card is left as it
    /// is: the new helper says what is playing within its first beat, and that replaces it.
    func restartHelper() {
        guard running, !Self.fakesTrack else { return }
        IslandLog.media.notice("restarting the adapter helper at the user's request")
        adapter.stop()
        adapter.start()
        refreshHealth()
    }

    /// Read afresh from the backends' own flags rather than kept up as they change. Health is
    /// a fact about the last few seconds, and the only way for the pane to lag behind it is to
    /// be told by something that forgot to say.
    private func refreshHealth() {
        let fresh: [Backend: Health] = running ? [
            .adapter: Self.backendHealth(available: adapter.isAvailable, answering: adapter.isAnswering,
                                         deliveringTrack: adapter.isDeliveringTrack, outranked: false),
            // MediaRemote ships with every macOS; a copy that would not load is one that never
            // answers, and that is what the pane will say of it. It is asked only while the
            // helper is not answering, which is exactly what outranks it in `handle`.
            .mediaRemote: Self.backendHealth(available: true, answering: mediaRemote.isAnswering,
                                             deliveringTrack: mediaRemote.isHealthy, outranked: adapter.isAnswering),
            // AppleScript has no health of its own: a poll always comes back, with a track or
            // with nothing, so it is answering whenever it is asked — and it is asked only
            // while neither of the others answers, the same gate `tick` polls it behind.
            .appleScript: Self.backendHealth(available: true, answering: true,
                                             deliveringTrack: activeBackend == .appleScript,
                                             outranked: adapter.isAnswering || mediaRemote.isAnswering),
        ] : [:]
        if health != fresh { health = fresh }
    }

    /// The one rule that turns a backend's flags into a word, see `Health`.
    ///
    /// Unavailable comes first because it is permanent: a helper this Mac cannot run is not
    /// standing by for anything. Outranked comes before the flags because a backend that is
    /// not being asked has flags that mean nothing — MediaRemote's freshness lapses fifteen
    /// seconds after the last track change while the helper is doing all the work, and read on
    /// its own it would say "not answering" on every Mac where the helper works. A track from a
    /// backend that is no longer answering is old news, not a live one.
    static func backendHealth(available: Bool, answering: Bool, deliveringTrack: Bool, outranked: Bool) -> Health {
        guard available else { return .unavailable }
        guard !outranked else { return .standingBy }
        guard answering else { return .givenUp }
        return deliveringTrack ? .live : .idle
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
        // prompt. The fallback is for a backend that has gone quiet, which is a different thing
        // — and a helper that was asleep with the Mac has not, so for its first silence window
        // after a wake it still counts as answering, see `AdapterBackend.isOverdue`.
        if !energy.isAsleep, !adapter.isAnswering, !mediaRemote.isAnswering, ticks % pollEvery == 0 {
            appleScript.poll { [weak self] info in self?.handle(info, from: .appleScript) }
        } else if activeBackend == .mediaRemote {
            // Refresh periodically so elapsed time can't drift after seeks made elsewhere.
            mediaRemote.refreshIfStale()
        }
        if let info, !info.isPlaying, let since = pausedSince, !ActivityCenter.shared.isPanelShowing {
            // 0 means "clear as soon as playback pauses"; otherwise keep the paused track around.
            // Never while the user has the card open in front of them.
            let limit = Preferences.shared.keepPausedMinutes * 60
            if limit <= 0 || Date().timeIntervalSince(since) > limit {
                dismissedPaused = info
                clear()
            }
        }
        refreshHealth()
    }

    private func handle(_ new: NowPlayingInfo?, from backend: Backend) {
        guard running else { return }   // a late poll must not bring the pill back after stop()
        // Lower-ranked backends stay quiet once a better one is delivering.
        if backend == .appleScript && (adapter.isAnswering || mediaRemote.isAnswering) { return }
        if backend == .mediaRemote && adapter.isAnswering { return }

        guard var new = new.map(Self.sanitized) else {
            if activeBackend == backend || activeBackend == .inactive { scheduleClear() }
            return
        }
        // A mode the report carries is the player's word; one it does not is what the island
        // last set by script, if it set one, see `ScriptedModes`.
        scriptedModes = scriptedModes?.after(new)
        if let scripted = scriptedModes { new = scripted.filling(new) }
        // The paused track the limit has already taken away is not news, see `staysDismissed`.
        // Any other track, or this one playing again, is, and ends the dismissal.
        if Self.staysDismissed(new, dismissed: dismissedPaused) { return }
        dismissedPaused = nil
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

    /// Whether a report is the paused track "Keep paused music for" already took off the
    /// island, and so not news.
    ///
    /// The helper speaks every five seconds whether or not anything has changed. Taken at its
    /// word, the same paused track put the card back five seconds after the limit removed it,
    /// with its clock started again — so it came back for good at five minutes and five
    /// seconds, and with "Not at all" the pill blinked every five seconds. The same track
    /// playing again, or any other track, is news.
    static func staysDismissed(_ incoming: NowPlayingInfo, dismissed: NowPlayingInfo?) -> Bool {
        guard let dismissed, !incoming.isPlaying else { return false }
        return sameTrack(incoming, dismissed)
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
        // Worked out here, after the duration is known to be a number, so a live stream's
        // infinite length does not offer it a fifteen-second skip.
        result.supports = NowPlayingInfo.supportedCommands(remote: result.remoteSupports, shuffle: result.shuffle,
                                                           repeatMode: result.repeatMode, bundleID: result.bundleID,
                                                           duration: result.duration)
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
        if let shuffle = optimistic.shuffle, incoming.shuffle != shuffle { result.shuffle = shuffle }
        if let mode = optimistic.repeatMode, incoming.repeatMode != mode { result.repeatMode = mode }
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
        if let shuffle = pending.shuffle, report.shuffle != shuffle { return false }
        if let mode = pending.repeatMode, report.repeatMode != mode { return false }
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
            let pending = carried(now)
            i.elapsed = seconds
            i.timestamp = now
            info = i
            optimistic = Optimistic(isPlaying: optimistic?.isPlaying, elapsed: seconds, at: now, until: now + Self.optimisticWindow,
                                    shuffle: pending?.shuffle, repeatMode: pending?.repeatMode)
            publish()
        }
    }

    func openApp() {
        if let bundle = info?.bundleID { OpenAction.app(bundleID: bundle).perform() }
    }

    private func optimisticallyToggle() {
        guard var i = info else { return }
        let now = Date()
        let pending = carried(now)
        i.elapsed = i.position(at: now)
        i.timestamp = now
        i.isPlaying.toggle()
        info = i
        optimistic = Optimistic(isPlaying: i.isPlaying, elapsed: nil, at: now, until: now + Self.optimisticWindow,
                                shuffle: pending?.shuffle, repeatMode: pending?.repeatMode)
        publish()
    }

    /// What is still pending of the last request, for a new one that must not forget it: a
    /// shuffle pressed a moment before play would otherwise flick back when play replaced it.
    private func carried(_ now: Date) -> Optimistic? {
        guard let optimistic, optimistic.until > now else { return nil }
        return optimistic
    }

    // MARK: The buttons beside play

    /// The track somebody pressed the heart on, so the heart stays filled while it plays.
    /// Players do not report a favourite back, so this is the island's own memory of the press,
    /// for this track only.
    @Published private(set) var likedTrackKey: String?

    static func trackKey(_ track: NowPlayingInfo) -> String {
        [track.bundleID ?? "", track.artist, track.title].joined(separator: "|")
    }

    func isLiked(_ track: NowPlayingInfo) -> Bool { likedTrackKey == Self.trackKey(track) }

    /// The shuffle and repeat the island last set through AppleScript, and the player it set
    /// them in.
    ///
    /// AppleScript is only asked to set a mode that the backend showing the track says nothing
    /// about, so nothing ever says it back. The button went dark once the press's moment was
    /// over, and the next press, reading nothing said as off, asked for on again: shuffle could
    /// be switched on and never off, and repeat went to all every time — for Spotify, repeating
    /// true, every time. Like the heart, this is the island's own memory of the press; unlike
    /// the heart it belongs to the player and not the track, because shuffle and repeat stay as
    /// they are from one track to the next. It fills in only what a report leaves out, and a
    /// mode is forgotten the moment a report carries it. What it cannot know is a change made
    /// in the player itself, which reports nothing either.
    struct ScriptedModes: Equatable {
        var bundleID: String?
        var shuffle: Bool? = nil
        var repeatMode: NowPlayingInfo.RepeatMode? = nil

        /// The memory after a press in `bundleID` set a mode by script. A press in another player
        /// starts it afresh: what was set in the first is no guide to the second.
        static func remembering(shuffle: Bool? = nil, repeatMode: NowPlayingInfo.RepeatMode? = nil,
                                in memory: ScriptedModes?, for bundleID: String?) -> ScriptedModes {
            var result = ScriptedModes(bundleID: bundleID)
            if let memory, memory.bundleID == bundleID { result = memory }
            if let shuffle { result.shuffle = shuffle }
            if let repeatMode { result.repeatMode = repeatMode }
            return result
        }

        /// What is left once `report` has come in: a mode it carries is forgotten, and nothing
        /// left is nil. A report from another player changes nothing — the one the modes were
        /// set in may well come back to the front.
        func after(_ report: NowPlayingInfo) -> ScriptedModes? {
            guard report.bundleID == bundleID else { return self }
            var kept = self
            if report.shuffle != nil { kept.shuffle = nil }
            if report.repeatMode != nil { kept.repeatMode = nil }
            return kept.shuffle == nil && kept.repeatMode == nil ? nil : kept
        }

        /// The report with the remembered modes filled in where it has none, for this player.
        func filling(_ report: NowPlayingInfo) -> NowPlayingInfo {
            guard report.bundleID == bundleID else { return report }
            var result = report
            if result.shuffle == nil { result.shuffle = shuffle }
            if result.repeatMode == nil { result.repeatMode = repeatMode }
            return result
        }

        /// Whether this button's mode, in this player, is one the island set by script.
        func holds(_ command: NowPlayingInfo.Command, in bundleID: String?) -> Bool {
            guard bundleID == self.bundleID else { return false }
            switch command {
            case .shuffle: return shuffle != nil
            case .cycleRepeat: return repeatMode != nil
            default: return false
            }
        }
    }

    /// See `ScriptedModes`. Main-queue state, like `info`, which it is folded into.
    private(set) var scriptedModes: ScriptedModes?

    /// Which backend a press of one of these buttons goes to. Pure, so the rule is tested.
    ///
    /// The one that is showing the track, as for play — unless MediaRemote has said nothing
    /// about this button for this player, and AppleScript can press it instead: the helper
    /// cannot set a shuffle it cannot see, and Music and Spotify answer AppleScript whatever
    /// MediaRemote makes of them. The fallback asks macOS for Automation once per player,
    /// which is why it is only taken when the helper has nothing to offer.
    ///
    /// A mode the island set by script (`scripted`) is shown in `info` as though reported, and
    /// is not: it goes back to AppleScript, where the last press went, and not to a helper
    /// that never said it could see it.
    static func route(_ command: NowPlayingInfo.Command, active: Backend, info: NowPlayingInfo,
                      scripted: ScriptedModes? = nil) -> Backend {
        if active == .appleScript { return .appleScript }
        if scripted?.holds(command, in: info.bundleID) == true { return .appleScript }
        let remoteKnows: Bool
        switch command {
        case .shuffle: remoteKnows = info.shuffle != nil || info.remoteSupports?.contains(.shuffle) == true
        case .cycleRepeat: remoteKnows = info.repeatMode != nil || info.remoteSupports?.contains(.cycleRepeat) == true
        case .like: remoteKnows = info.remoteSupports?.contains(.like) == true
        case .back15, .forward15: remoteKnows = true
        }
        if !remoteKnows, NowPlayingInfo.scriptable(command, bundleID: info.bundleID) { return .appleScript }
        return active == .adapter ? .adapter : .mediaRemote
    }

    /// Shuffle on if it is off, off if it is on. A player that has never said, and has not been
    /// set by script, counts as off.
    func toggleShuffle() {
        guard let current = info else { return }
        let target = !(current.shuffle ?? false)
        switch Self.route(.shuffle, active: activeBackend, info: current, scripted: scriptedModes) {
        case .appleScript:
            appleScript.setShuffle(target, bundleID: current.bundleID)
            scriptedModes = ScriptedModes.remembering(shuffle: target, in: scriptedModes, for: current.bundleID)
        case .adapter: adapter.send("shuffle \(NowPlayingInfo.remoteCode(shuffle: target))")
        default: mediaRemote.setShuffle(target)
        }
        optimistically(shuffle: target)
    }

    /// The next repeat, see `nextRepeat`.
    func cycleRepeat() {
        guard let current = info else { return }
        let backend = Self.route(.cycleRepeat, active: activeBackend, info: current, scripted: scriptedModes)
        let target = Self.nextRepeat(after: current.repeatMode ?? .off, bundleID: current.bundleID, via: backend)
        switch backend {
        case .appleScript:
            appleScript.setRepeat(target, bundleID: current.bundleID)
            scriptedModes = ScriptedModes.remembering(repeatMode: target, in: scriptedModes, for: current.bundleID)
        case .adapter: adapter.send("repeat \(NowPlayingInfo.remoteCode(repeat: target))")
        default: mediaRemote.setRepeat(target)
        }
        optimistically(repeatMode: target)
    }

    /// Off, all, one, off — except Spotify spoken to in AppleScript, whose dictionary knows only
    /// whether it repeats, so there the button is off and on.
    static func nextRepeat(after mode: NowPlayingInfo.RepeatMode, bundleID: String?, via backend: Backend) -> NowPlayingInfo.RepeatMode {
        if backend == .appleScript, bundleID == NowPlayingInfo.spotifyID { return mode == .off ? .all : .off }
        return mode.next
    }

    /// Favourite the track: "like" to MediaRemote, the heart in Music through AppleScript.
    func like() {
        guard let current = info else { return }
        switch Self.route(.like, active: activeBackend, info: current) {
        case .appleScript: appleScript.like(bundleID: current.bundleID)
        case .adapter: adapter.send("like")
        default: mediaRemote.send(.likeTrack)
        }
        likedTrackKey = Self.trackKey(current)
    }

    /// Fifteen seconds back or on, as a seek from where the playhead is now — the same seek the
    /// scrubber makes, through whichever backend is showing the track. A player's own skip
    /// command is not used: most players do not take one, every one that has a scrubber takes
    /// a seek.
    func skip(by seconds: Double) {
        guard seconds.isFinite, let current = info else { return }
        seek(to: Self.skipTarget(from: current, by: seconds, now: Date()))
    }

    /// Where a skip lands: never before the start, and a second short of the end rather than
    /// on it, so skipping on through the last few seconds finishes the track instead of asking
    /// a player to stand on a position it has no frame for. Pure, so it is tested.
    static func skipTarget(from track: NowPlayingInfo, by seconds: Double, now: Date) -> TimeInterval {
        let target = max(0, track.position(at: now) + seconds)
        guard track.duration > 0 else { return target }
        return min(target, max(0, track.duration - 1))
    }

    private func optimistically(shuffle: Bool? = nil, repeatMode: NowPlayingInfo.RepeatMode? = nil) {
        guard var i = info else { return }
        let now = Date()
        let pending = carried(now)
        if let shuffle { i.shuffle = shuffle }
        if let repeatMode { i.repeatMode = repeatMode }
        info = i
        optimistic = Optimistic(isPlaying: pending?.isPlaying, elapsed: pending?.elapsed, at: pending?.at ?? now,
                                until: now + Self.optimisticWindow,
                                shuffle: shuffle ?? pending?.shuffle, repeatMode: repeatMode ?? pending?.repeatMode)
        publish()
    }
}
