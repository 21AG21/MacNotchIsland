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
    /// True once MediaRemote has delivered a non-empty payload in this process.
    private(set) var isHealthy = false

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
        guard handle == nil else { return }
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            NSLog("MediaRemote unavailable")
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

        register?(DispatchQueue.main)
        for name in notifications {
            let token = NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            observers.append(token)
        }
        refresh()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        unregister?()
    }

    private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 10 { refresh() }
    }

    func refresh() {
        guard let getInfo else { return }
        lastRefresh = Date()
        getInfo(DispatchQueue.main) { [weak self] dict in
            self?.parse(dict)
        }
    }

    private func parse(_ d: [String: Any]) {
        guard !d.isEmpty else {
            if isHealthy { onUpdate?(nil) }
            return
        }
        isHealthy = true

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
            onUpdate?(nil)
            return
        }

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
