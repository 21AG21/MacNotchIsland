import AppKit

/// Polls Music and Spotify with AppleScript. Used when MediaRemote yields nothing
/// (macOS 15.4 and later). Artwork is fetched only when the track changes.
final class AppleScriptBackend {
    enum Command { case togglePlayPause, next, previous }

    /// Polls run one at a time on a serial queue: `query` mutates the artwork cache, so two
    /// concurrent polls would race. Transport commands use their own queue so a slow poll
    /// never delays a play/pause click.
    private let queue = DispatchQueue(label: "com.macnotchisland.applescript.poll", qos: .userInitiated)
    private let commandQueue = DispatchQueue(label: "com.macnotchisland.applescript.command", qos: .userInitiated)
    private var inFlight = false
    private var generation = 0
    private var artworkKey = ""
    private var artwork: NSImage?
    private var artworkID = 0
    private var accent: NSColor = .white

    private static let musicID = "com.apple.Music"
    private static let spotifyID = "com.spotify.client"

    /// Drop any in-flight poll's result (its blocked NSAppleScript call can't be interrupted).
    func cancel() {
        generation += 1
        inFlight = false
    }

    func poll(_ completion: @escaping (NowPlayingInfo?) -> Void) {
        guard !inFlight else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let hasSpotify = running.contains(Self.spotifyID)
        let hasMusic = running.contains(Self.musicID)
        guard hasSpotify || hasMusic else {
            completion(nil)
            return
        }
        inFlight = true
        generation += 1
        let myGeneration = generation
        // Watchdog: a beach-balling player can block NSAppleScript for a long time (it times out
        // on its own after two minutes). Report "nothing" after 6 s so the island doesn't hold a
        // stale track; the serial queue keeps the stuck poll from racing the next one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.generation == myGeneration, self.inFlight else { return }
            self.inFlight = false
            completion(nil)
        }
        queue.async { [self] in
            var candidates: [NowPlayingInfo] = []
            if hasSpotify, let s = query(spotify: true) { candidates.append(s) }
            if hasMusic, let m = query(spotify: false) { candidates.append(m) }
            let chosen = candidates.first(where: { $0.isPlaying }) ?? candidates.first
            DispatchQueue.main.async {
                guard self.generation == myGeneration else { return }
                self.inFlight = false
                completion(chosen)
            }
        }
    }

    private func query(spotify: Bool) -> NowPlayingInfo? {
        let source: String
        if spotify {
            source = """
            tell application "Spotify"
                set s to "stopped"
                if player state is playing then
                    set s to "playing"
                else if player state is paused then
                    set s to "paused"
                end if
                if s is "playing" or s is "paused" then
                    set t to current track
                    return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) / 1000) & linefeed & (player position) & linefeed & (id of t) & linefeed & (artwork url of t)
                end if
            end tell
            return ""
            """
        } else {
            source = """
            tell application "Music"
                set s to "stopped"
                if player state is playing then
                    set s to "playing"
                else if player state is paused then
                    set s to "paused"
                end if
                if s is "playing" or s is "paused" then
                    set t to current track
                    return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position) & linefeed & (database ID of t) & linefeed & ""
                end if
            end tell
            return ""
            """
        }
        guard let result = run(source), !result.isEmpty else { return nil }
        let parts = result.components(separatedBy: "\n")
        guard parts.count >= 7 else { return nil }
        let state = parts[0]
        let title = parts[1]
        let artist = parts[2]
        let album = parts[3]
        let duration = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let position = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        let trackID = parts[6]
        let artworkURL = parts.count > 7 ? parts[7] : ""
        let bundle = spotify ? Self.spotifyID : Self.musicID

        let key = bundle + "|" + trackID + "|" + title
        if key != artworkKey {
            artworkKey = key
            artwork = spotify ? fetchSpotifyArtwork(artworkURL) : fetchMusicArtwork()
            artworkID = key.hashValue
            accent = artwork?.dominantColor() ?? .white
        }

        return NowPlayingInfo(title: title, artist: artist, album: album,
                              duration: duration, elapsed: position, timestamp: Date(),
                              isPlaying: state == "playing", bundleID: bundle,
                              artwork: artwork, artworkID: artworkID, accent: accent)
    }

    private func fetchMusicArtwork() -> NSImage? {
        let source = """
        tell application "Music"
            try
                return data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let data = descriptor.data
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private func fetchSpotifyArtwork(_ urlString: String) -> NSImage? {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var image: NSImage?
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data { image = NSImage(data: data) }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2.5)
        return image
    }

    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            // -1743 = user declined Automation permission; -600 = app not running. Both are silent.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code != -1743 && code != -600 { NSLog("AppleScript error: \(error)") }
            return nil
        }
        return descriptor.stringValue
    }

    // MARK: Commands

    func command(_ command: Command, bundleID: String?) {
        let app = bundleID == Self.spotifyID ? "Spotify" : "Music"
        let verb: String
        switch command {
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        commandQueue.async { _ = self.run("tell application \"\(app)\" to \(verb)") }
    }

    func seek(to seconds: TimeInterval, bundleID: String?) {
        let app = bundleID == Self.spotifyID ? "Spotify" : "Music"
        commandQueue.async { _ = self.run("tell application \"\(app)\" to set player position to \(Int(seconds))") }
    }
}
