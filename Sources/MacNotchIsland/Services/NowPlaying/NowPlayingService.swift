import AppKit
import Combine

/// Publishes what's playing system-wide and exposes transport controls.
///
/// Two backends: the private MediaRemote framework (covers every app, but Apple stopped
/// delivering data to third-party apps in macOS 15.4) and an AppleScript poller for Music
/// and Spotify. The poller only runs while MediaRemote hasn't produced anything.
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    enum Backend { case inactive, mediaRemote, appleScript }

    @Published private(set) var info: NowPlayingInfo?

    private let mediaRemote = MediaRemoteBackend()
    private let appleScript = AppleScriptBackend()
    private var running = false
    private var pollTimer: Timer?
    private var pausedSince: Date?
    private var ticks = 0
    private(set) var activeBackend: Backend = .inactive

    private init() {}

    func start() {
        guard !running else { return }
        running = true
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
        mediaRemote.stop()
        clear()
    }

    private func tick() {
        ticks += 1
        if !mediaRemote.isHealthy, ticks % 2 == 0 {
            appleScript.poll { [weak self] info in self?.handle(info, from: .appleScript) }
        } else if activeBackend == .mediaRemote {
            // Refresh periodically so elapsed time can't drift after seeks made elsewhere.
            mediaRemote.refreshIfStale()
        }
        if let info, !info.isPlaying, let since = pausedSince {
            let limit = Preferences.shared.keepPausedMinutes * 60
            if limit > 0, Date().timeIntervalSince(since) > limit { clear() }
        }
    }

    private func handle(_ new: NowPlayingInfo?, from backend: Backend) {
        // Ignore the fallback once MediaRemote is delivering.
        if backend == .appleScript && mediaRemote.isHealthy { return }

        guard let new else {
            if activeBackend == backend || activeBackend == .inactive { clear() }
            return
        }
        activeBackend = backend
        if new.isPlaying {
            pausedSince = nil
        } else if pausedSince == nil {
            pausedSince = Date()
        }
        if info != new { info = new }
        publish()
    }

    private func clear() {
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
        default: mediaRemote.send(.togglePlayPause)
        }
        optimisticallyToggle()
    }

    func next() {
        switch activeBackend {
        case .appleScript: appleScript.command(.next, bundleID: info?.bundleID)
        default: mediaRemote.send(.nextTrack)
        }
    }

    func previous() {
        switch activeBackend {
        case .appleScript: appleScript.command(.previous, bundleID: info?.bundleID)
        default: mediaRemote.send(.previousTrack)
        }
    }

    func seek(to seconds: TimeInterval) {
        switch activeBackend {
        case .appleScript: appleScript.seek(to: seconds, bundleID: info?.bundleID)
        default: mediaRemote.seek(to: seconds)
        }
        if var i = info {
            i.elapsed = seconds
            i.timestamp = Date()
            info = i
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
        publish()
    }
}
