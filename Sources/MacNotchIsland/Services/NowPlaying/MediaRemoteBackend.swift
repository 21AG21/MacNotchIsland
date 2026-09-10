import AppKit

/// Talks to the private MediaRemote framework through dlopen so no private headers are needed.
final class MediaRemoteBackend {
    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5
    }

    private typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterFn = @convention(c) () -> Void
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int32, AnyObject?) -> Bool
    private typealias SetElapsedFn = @convention(c) (Double) -> Void
    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void

    var onUpdate: ((NowPlayingInfo?) -> Void)?

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
    var isHealthy: Bool { BackendHealth.isFresh(lastPayload, now: Date(), within: Self.staleAfter) }

    /// Whether we are registered for notifications *right now* — not whether the framework has
    /// ever been loaded. Those two used to be the same flag, so switching Now Playing off and on
    /// again left this backend loaded, unregistered, without observers, and still claiming to be
    /// healthy: switched off in every way except the one that gated the fallbacks.
    private var started = false
    /// When MediaRemote last handed over a payload with a track in it.
    private var lastPayload: Date?

    private var handle: UnsafeMutableRawPointer?
    private var getInfo: GetNowPlayingInfoFn?
    private var register: RegisterFn?
    private var unregister: UnregisterFn?
    private var isPlayingFn: IsPlayingFn?
    private var sendCommandFn: SendCommandFn?
    private var setElapsedFn: SetElapsedFn?
    private var getPIDFn: GetPIDFn?

    private var lastArtworkHash = 0
    private var lastArtwork: NSImage?
    private var lastAccent: NSColor = .white
    private var lastRefresh = Date.distantPast
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
    }

    func stop() {
        started = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        unregister?()
        // Health cannot outlive being switched off, or the AppleScript poller would stay gated
        // behind a backend that is no longer listening to anything.
        lastPayload = nil
        lastRefresh = .distantPast
    }

    private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 10 { refresh() }
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
        guard !d.isEmpty else {
            if isHealthy { onUpdate?(nil) }
            return
        }

        let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = d["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
        let elapsed = d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
        let rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        let timestamp = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()

        if let data = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            let hash = data.hashValue
            if hash != lastArtworkHash {
                lastArtworkHash = hash
                lastArtwork = NSImage(data: data)
                lastAccent = lastArtwork?.dominantColor() ?? .white
            }
        } else {
            lastArtworkHash = 0
            lastArtwork = nil
            lastAccent = .white
        }

        var info = NowPlayingInfo(title: title, artist: artist, album: album,
                                  duration: duration, elapsed: elapsed, timestamp: timestamp,
                                  isPlaying: rate > 0, bundleID: nil,
                                  artwork: lastArtwork, artworkID: lastArtworkHash, accent: lastAccent)

        if title.isEmpty && artist.isEmpty {
            // macOS 15.4+ hands unentitled apps a payload with no usable fields; don't count that as healthy.
            if isHealthy { onUpdate?(nil) }
            return
        }
        lastPayload = Date()

        if let getPIDFn {
            getPIDFn(DispatchQueue.main) { [weak self] pid in
                if pid > 0, let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                    info.bundleID = app.bundleIdentifier
                }
                self?.onUpdate?(info)
            }
        } else {
            onUpdate?(info)
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
}
