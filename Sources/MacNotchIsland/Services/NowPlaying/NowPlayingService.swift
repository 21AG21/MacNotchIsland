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

    private init() {}

    func start() {
        guard !running else { return }
        running = true
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
        if !energy.isAsleep, !adapter.isHealthy, !mediaRemote.isHealthy, ticks % pollEvery == 0 {
            appleScript.poll { [weak self] info in self?.handle(info, from: .appleScript) }
        } else if activeBackend == .mediaRemote {
            // Refresh periodically so elapsed time can't drift after seeks made elsewhere.
            mediaRemote.refreshIfStale()
        }
        if let info, !info.isPlaying, let since = pausedSince {
            // 0 means "clear as soon as playback pauses"; otherwise keep the paused track around.
            let limit = Preferences.shared.keepPausedMinutes * 60
            if limit <= 0 || Date().timeIntervalSince(since) > limit { clear() }
        }
    }

    private func handle(_ new: NowPlayingInfo?, from backend: Backend) {
        // Lower-ranked backends stay quiet once a better one is delivering.
        if backend == .appleScript && (adapter.isHealthy || mediaRemote.isHealthy) { return }
        if backend == .mediaRemote && adapter.isHealthy { return }

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
        case .adapter: adapter.send("toggle")
        default: mediaRemote.send(.togglePlayPause)
        }
        optimisticallyToggle()
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
        switch activeBackend {
        case .appleScript: appleScript.seek(to: seconds, bundleID: info?.bundleID)
        case .adapter: adapter.send("seek \(Int(seconds))")
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
