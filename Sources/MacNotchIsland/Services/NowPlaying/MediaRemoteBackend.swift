import AppKit

/// Talks to the private MediaRemote framework through dlopen so no private headers are needed.
final class MediaRemoteBackend {
    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5
        /// Advance the shuffle and the repeat mode one step, the way the players' own buttons do.
        case advanceShuffle = 6, advanceRepeat = 7
        case likeTrack = 21
    }

    private typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterFn = @convention(c) () -> Void
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int32, AnyObject?) -> Bool
    private typealias SetElapsedFn = @convention(c) (Double) -> Void
    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias SetModeFn = @convention(c) (Int32) -> Void

    var onUpdate: ((NowPlayingInfo?) -> Void)?
    /// Whether a better backend is answering, so that a report from here would be dropped
    /// (`NowPlayingService.handle`). Asked before a cover is decoded: that used to be done for
    /// every track while the helper answered and the report went nowhere, and on the main
    /// thread. Main queue.
    var isOutranked: () -> Bool = { false }

    /// Whether MediaRemote, asked from inside this app, can say what is playing at all: up to
    /// macOS 15.3. From 15.4 it hands an app without Apple's entitlement nothing, and that
    /// nothing is not an answer — it is what the helper exists for.
    static let answersThisApp: Bool = !ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0))

    /// MediaRemote answers questions, it does not report in, so a payload that arrived a minute
    /// ago says nothing about whether the framework is still talking to us. Health lapses this
    /// long after the last usable one — comfortably more than the ten seconds between the
    /// refreshes the service sends, so an answered question always renews it in time.
    static let staleAfter: TimeInterval = 15

    /// True while MediaRemote is still handing over payloads with a track in them.
    ///
    /// This used to be true from the first usable payload until the app was relaunched, which is
    /// the worst possible shape for it: the point release that stops MediaRemote answering is
    /// exactly the moment the card goes blank, and a flag that could never fall kept the
    /// AppleScript fallback shut behind it, with nothing said to the user and nothing to be done
    /// short of quitting the app.
    /// Whether a track is coming through. What ranks this above AppleScript.
    var isHealthy: Bool { BackendHealth.isFresh(lastPayload, now: Date(), within: Self.staleAfter) }

    /// Whether MediaRemote is answering at all, which is a different question and the one the
    /// fallback turns on. A payload with nothing playing in it is an answer: it says the Mac is
    /// silent. Reading "not delivering a track" as "not answering" had a Mac with the music
    /// stopped firing a round trip at Music and at Spotify every two seconds for as long as it
    /// was switched on, each one able to raise an Automation prompt. It is not the last word,
    /// though: a MediaRemote wedged after a wake says the same with Music playing. So while it
    /// answers with nothing and has shown no track lately (`isHealthy`), AppleScript is still
    /// asked, at its slowest, and this "nothing" does not end AppleScript's card
    /// (`NowPlayingService.mediaRemoteSaysNothing`).
    var isAnswering: Bool { BackendHealth.isFresh(lastHeard, now: Date(), within: Self.staleAfter) }

    /// Whether we are registered for notifications *right now* — not whether the framework has
    /// ever been loaded. Those two used to be the same flag, so switching Now Playing off and on
    /// again left this backend loaded, unregistered, without observers, and still claiming to be
    /// healthy: switched off in every way except the one that gated the fallbacks.
    private var started = false
    /// When MediaRemote last handed over a payload with a track in it.
    private var lastPayload: Date?
    /// The last payload of any kind, empty ones included. See `isAnswering`.
    private var lastHeard: Date?

    private var handle: UnsafeMutableRawPointer?
    private var getInfo: GetNowPlayingInfoFn?
    private var register: RegisterFn?
    private var unregister: UnregisterFn?
    private var isPlayingFn: IsPlayingFn?
    private var sendCommandFn: SendCommandFn?
    private var setElapsedFn: SetElapsedFn?
    private var getPIDFn: GetPIDFn?
    private var setShuffleFn: SetModeFn?
    private var setRepeatFn: SetModeFn?

    /// The hash of the cover bytes in the newest report, which is what decides whether the next
    /// one brings a new cover. Set as a report comes in. Main queue.
    private var lastArtworkHash = 0
    /// The cover of the last report to go out, and its accent. Set as each report goes out, in
    /// the order they came in (`inOrder`): a new cover is decoded before its report leaves.
    /// Main queue.
    private var lastArtwork: NSImage?
    private var lastAccent: NSColor = .white
    private var lastRefresh = Date.distantPast
    /// Where a new cover is decoded, off the main thread. MediaRemote answers on the main
    /// queue, and a new track's cover was decoded there, whole — a JPEG of many hundreds of
    /// pixels, for a picture drawn at 60 pt at most — on the pass that started the card's
    /// change of track. The report waits for it here instead, and nothing else does.
    private let coverQueue = DispatchQueue(label: "com.macnotchisland.mediaremote.covers", qos: .userInitiated)
    /// Reports on their way through `coverQueue`. While there are any, every report goes the
    /// same way behind them, so none overtakes one still waiting for its cover. Main queue.
    private var queued = 0
    /// Moved on by `stop`, so that a report on its way through `coverQueue` when the backend
    /// was switched off is not passed on when it lands, as one that arrives after it is not.
    /// Main queue.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    private let notifications = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ]

    func start() {
        guard !started else { return }
        if handle == nil { load() }
        guard handle != nil else { return }
        started = true

        register?(DispatchQueue.main)
        for name in notifications {
            let token = NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            observers.append(token)
        }
        refresh()
    }

    /// The framework itself is loaded once and kept: unloading a private framework that has
    /// registered callbacks of its own is a far worse idea than holding a handle we may need again.
    private func load() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            IslandLog.media.error("MediaRemote is unavailable")
            return
        }
        handle = h
        getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", GetNowPlayingInfoFn.self)
        register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", RegisterFn.self)
        unregister = symbol("MRMediaRemoteUnregisterForNowPlayingNotifications", UnregisterFn.self)
        isPlayingFn = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", IsPlayingFn.self)
        sendCommandFn = symbol("MRMediaRemoteSendCommand", SendCommandFn.self)
        setElapsedFn = symbol("MRMediaRemoteSetElapsedTime", SetElapsedFn.self)
        getPIDFn = symbol("MRMediaRemoteGetNowPlayingApplicationPID", GetPIDFn.self)
        // Optional: without them the modes are advanced a step with a command instead.
        setShuffleFn = symbol("MRMediaRemoteSetShuffleMode", SetModeFn.self)
        setRepeatFn = symbol("MRMediaRemoteSetRepeatMode", SetModeFn.self)
    }

    func stop() {
        started = false
        generation += 1
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        unregister?()
        // Health cannot outlive being switched off, or the AppleScript poller would stay gated
        // behind a backend that is no longer listening to anything.
        lastPayload = nil
        lastHeard = nil
        lastRefresh = .distantPast
    }

    private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    /// Asks again if the last question is more than ten seconds old, and says whether it did.
    @discardableResult
    func refreshIfStale() -> Bool {
        guard started, Date().timeIntervalSince(lastRefresh) > 10 else { return false }
        refresh()
        return true
    }

    func refresh() {
        guard started, let getInfo else { return }
        lastRefresh = Date()
        getInfo(DispatchQueue.main) { [weak self] dict in
            self?.parse(dict)
        }
    }

    private func parse(_ d: [String: Any]) {
        // An answer to a question we asked before we were switched off is no longer ours to act on.
        guard started else { return }
        let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""

        // Heard from, whatever it said. An empty payload is not a track and must not rank this
        // above AppleScript, but it is still MediaRemote answering — where it answers this app
        // at all. Up to 15.3 an empty dictionary is how it says nothing is playing, and that
        // answer used to be dropped before it was counted: fifteen seconds after the music
        // stopped MediaRemote counted as silent, and AppleScript was sent to Music and Spotify
        // every two seconds for as long as nothing played. From 15.4 an empty dictionary is all
        // it ever says, and counting it would shut the fallback out for good.
        if !d.isEmpty || Self.answersThisApp { lastHeard = Date() }
        if title.isEmpty && artist.isEmpty {
            // macOS 15.4+ hands unentitled apps a payload with no usable fields; don't count that
            // as healthy. Where MediaRemote answers this app, "nothing is playing" is its word.
            if isHealthy || Self.answersThisApp {
                inOrder(decoding: nil) { [weak self] _, current in if current { self?.onUpdate?(nil) } }
            }
            return
        }
        lastPayload = Date()
        // The service would drop this report (`isOutranked`); nothing more is worked out for it.
        if isOutranked() { return }

        let album = d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let reportedDuration = d["kMRMediaRemoteNowPlayingInfoDuration"] as? Double
        let reportedElapsed = (d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double).flatMap { $0.isFinite ? $0 : nil }
        let rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double
        let reportedTimestamp = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date

        // The cover's bytes come with every report about its track; only new ones are decoded.
        let artwork = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let hash = artwork?.hashValue ?? 0
        let step = Self.coverStep(hash: artwork.map { _ in hash }, last: lastArtworkHash)
        lastArtworkHash = hash

        // The cover and its accent are filled in as the report goes out, see `inOrder`.
        var info = NowPlayingInfo(title: title, artist: artist, album: album,
                                  duration: reportedDuration ?? 0, elapsed: reportedElapsed ?? 0,
                                  timestamp: reportedTimestamp ?? Date(),
                                  isPlaying: NowPlayingInfo.isPlaying(rate: rate, flag: nil), bundleID: nil,
                                  artwork: nil, artworkID: hash, accent: .white)
        // The elapsed time is where the playhead is; a timestamp on its own says only when,
        // and a report that carried one and no position counted from 0:00 at it.
        info.reportsPosition = reportedElapsed != nil
        // The same keys the helper passes through, read the same way. No list of supported
        // commands here: that is asked for inside the helper only.
        info.shuffle = NowPlayingInfo.shuffle(fromRemote: (d["kMRMediaRemoteNowPlayingInfoShuffleMode"] as? NSNumber)?.intValue)
        info.repeatMode = NowPlayingInfo.repeatMode(fromRemote: (d["kMRMediaRemoteNowPlayingInfoRepeatMode"] as? NSNumber)?.intValue)

        let report = info
        inOrder(decoding: step == .decode ? artwork : nil) { [weak self] decoded, current in
            guard let self else { return }
            switch step {
            case .decode:
                self.lastArtwork = decoded?.image
                self.lastAccent = decoded?.accent ?? .white
            case .clear:
                self.lastArtwork = nil
                self.lastAccent = .white
            case .keep:
                break
            }
            guard current else { return }
            var covered = report
            covered.artwork = self.lastArtwork
            covered.accent = self.lastAccent
            self.passOn(covered, rate: rate)
        }
    }

    /// The player's own word on whether it is playing, where the framework gives one, then the
    /// application that is playing it; each is a question answered on the main queue.
    private func passOn(_ info: NowPlayingInfo, rate: Double?) {
        let deliver: (NowPlayingInfo) -> Void = { [weak self] info in
            guard let self else { return }
            guard let getPIDFn = self.getPIDFn else {
                self.onUpdate?(info)
                return
            }
            getPIDFn(DispatchQueue.main) { [weak self] pid in
                var info = info
                if pid > 0, let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                    info.bundleID = app.bundleIdentifier
                }
                self?.onUpdate?(info)
            }
        }
        if let isPlayingFn {
            isPlayingFn(DispatchQueue.main) { playing in
                var info = info
                info.isPlaying = NowPlayingInfo.isPlaying(rate: rate, flag: playing)
                deliver(info)
            }
        } else {
            deliver(info)
        }
    }

    /// What a report does with the cover the last one had. Pure, so it is tested.
    enum CoverStep: Equatable {
        /// New bytes: decode them.
        case decode
        /// The same bytes as the report before: the same cover.
        case keep
        /// No bytes: no cover.
        case clear
    }

    /// `hash` is that of this report's cover bytes, nil when it has none; `last` is that of the
    /// report before, 0 when it had none.
    static func coverStep(hash: Int?, last: Int) -> CoverStep {
        guard let hash else { return .clear }
        return hash == last ? .keep : .decode
    }

    /// Runs `then` on the main queue in the order the reports came in, with the cover decoded
    /// from `bytes` when there are any, and whether the report is still to be passed on.
    ///
    /// With nothing to decode and nothing on its way through `coverQueue`, `then` runs at once,
    /// as it always did. Otherwise it goes through the queue: a new cover is decoded there
    /// (`NSImage.cover(from:)`), and a report behind one waits its turn, so a later report can
    /// never go out ahead of an earlier one, nor a decode that finishes late stand in for a
    /// newer report's cover. A report that lands after `stop` is not passed on (`current` is
    /// false), but its cover is still taken in: the next report is weighed against the hash
    /// this one brought, and has to find the cover that goes with it. Not private, so the order
    /// is tested. Main queue.
    func inOrder(decoding bytes: Data?,
                 then: @escaping (_ decoded: (image: NSImage, accent: NSColor)?, _ current: Bool) -> Void) {
        guard bytes != nil || queued > 0 else { return then(nil, true) }
        queued += 1
        let generation = self.generation
        coverQueue.async { [weak self] in
            let decoded = bytes.flatMap { NSImage.cover(from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.queued -= 1
                then(decoded, generation == self.generation)
            }
        }
    }

    // MARK: Commands

    @discardableResult
    func send(_ command: Command) -> Bool {
        sendCommandFn?(Int32(command.rawValue), nil) ?? false
    }

    func seek(to seconds: TimeInterval) {
        setElapsedFn?(seconds)
    }

    /// Sets the shuffle outright where the framework exports a way to, and otherwise advances
    /// it a step — which, from off, is on, and from on, is off.
    func setShuffle(_ on: Bool) {
        if let setShuffleFn {
            setShuffleFn(Int32(NowPlayingInfo.remoteCode(shuffle: on)))
        } else {
            send(.advanceShuffle)
        }
    }

    func setRepeat(_ mode: NowPlayingInfo.RepeatMode) {
        if let setRepeatFn {
            setRepeatFn(Int32(NowPlayingInfo.remoteCode(repeat: mode)))
        } else {
            send(.advanceRepeat)
        }
    }
}
