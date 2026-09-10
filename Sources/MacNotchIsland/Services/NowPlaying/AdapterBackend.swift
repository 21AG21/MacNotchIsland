import AppKit

/// Runs MediaRemoteAdapter.dylib inside /usr/bin/perl (an Apple-signed host) and reads
/// the JSON stream it produces. This is what makes Now Playing work on macOS 15.4+ for
/// every app, not just Music and Spotify.
final class AdapterBackend {
    var onUpdate: ((NowPlayingInfo?) -> Void)?

    /// The helper speaks every five seconds whether or not anything is playing, so silence for
    /// longer than two of those beats means the helper has stopped talking — not that the Mac
    /// has gone quiet. Everything above this class turns on that difference.
    static let silence: TimeInterval = 12

    /// Deaths are counted as a rate rather than as a lifetime total, see `BackendHealth`.
    static let restartBudget = 5
    static let restartWindow: TimeInterval = 300

    /// Blowing the budget buys a rest, never a permanent silence. A helper that cannot start
    /// this minute may well start after the next sleep/wake or the next software update, and the
    /// alternative — never trying again — leaves the island dark until the user thinks to
    /// relaunch the app, which is the failure this backend exists to prevent.
    static let restCooldown: TimeInterval = 300

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var stopped = true
    /// When the helper we currently hold last said something we could read, and whether what it
    /// said was a track. Both are main-queue state, like `process` itself.
    private var lastMessage: Date?
    private var lastMessageWasTrack = false
    /// When each helper we have owned this session died, most recent last.
    private var failures: [Date] = []
    private var watchdog: Timer?
    private var artworkHash = ""
    private var artwork: NSImage?
    private var accent: NSColor = .white
    private let parseQueue = DispatchQueue(label: "com.macnotchisland.adapter", qos: .userInitiated)

    /// Writing to a helper that died a moment ago would otherwise take the whole app down with a
    /// SIGPIPE instead of failing as an error we can log and route around. Done once, lazily, on
    /// the first launch, because this backend is the only part of the app that writes to a pipe
    /// whose reader can vanish underneath it.
    private static let ignoresBrokenPipe: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    private static let perlScript = """
    use strict; use DynaLoader;
    my $path = shift @ARGV or die "missing path";
    my $lib = DynaLoader::dl_load_file($path, 0) or die "load: " . DynaLoader::dl_error();
    my $sym = DynaLoader::dl_find_symbol($lib, "MRAdapterMain") or die "symbol: " . DynaLoader::dl_error();
    my $sub = DynaLoader::dl_install_xsub("MRAdapter::main", $sym);
    $sub->();
    """

    static var dylibURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter.dylib"),
              FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { return nil }
        return url
    }

    var isAvailable: Bool { Self.dylibURL != nil }

    // MARK: Health

    /// The helper is alive and still talking to us. This is what the lower-ranked backends are
    /// gated on: while it holds, nobody else needs to go and ask the Mac what is playing.
    var isAnswering: Bool { BackendHealth.isFresh(lastMessage, now: Date(), within: Self.silence) }

    /// The helper is answering *and* the last thing it said was a real track.
    ///
    /// "Answering, and nothing is playing" is a wholly different fact from "not answering", and
    /// reading the second where the first was meant is what used to fire an AppleScript at Music
    /// and Spotify every two seconds, for ever, on a perfectly healthy Mac with the music off.
    var isDeliveringTrack: Bool { lastMessageWasTrack && isAnswering }

    // MARK: Lifetime

    func start() {
        guard stopped, let dylib = Self.dylibURL else { return }
        stopped = false
        failures.removeAll()
        launch(dylib)
        startWatchdog()
    }

    func stop() {
        stopped = true
        watchdog?.invalidate()
        watchdog = nil
        if process?.isRunning == true { send("quit") }
        if let process, process.isRunning { process.terminate() }
        releaseHelper()
    }

    /// Let go of the helper we hold. Its output must not reach us once we have written it off,
    /// and its health must never be inherited by whatever replaces it.
    private func releaseHelper() {
        output?.readabilityHandler = nil   // no trailing reads after we've stopped believing it
        output = nil
        input = nil
        process = nil
        lastMessage = nil
        lastMessageWasTrack = false
    }

    // MARK: Commands

    /// A press the helper never receives is a press the user has to make twice, and the island
    /// will have flipped its own button in the meantime. Losing one in silence is worse than
    /// failing loudly, so this says so in the log either way.
    ///
    /// It deliberately does not hold the press for the helper that replaces this one: a "toggle"
    /// replayed two seconds later lands on a Mac the user may have paused by other means, and
    /// starting the music up again unbidden is the one thing a media control must never do.
    func send(_ command: String) {
        guard let input, process?.isRunning == true, let data = (command + "\n").data(using: .utf8) else {
            IslandLog.media.error("dropped \(command, privacy: .public): the adapter helper is not listening")
            return
        }
        do {
            try input.write(contentsOf: data)
        } catch {
            IslandLog.media.error("could not hand \(command, privacy: .public) to the adapter helper: \(String(describing: error), privacy: .public)")
            // A broken pipe means the helper is already gone whatever its exit status says yet;
            // let go of it now rather than write into it again on the next press.
            self.input = nil
        }
    }

    func refresh() { send("refresh") }

    // MARK: Process

    private func launch(_ dylib: URL) {
        _ = Self.ignoresBrokenPipe
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.perlScript, dylib.path]
        let stdout = Pipe()
        let stdin = Pipe()
        p.standardOutput = stdout
        p.standardInput = stdin
        p.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: stop the handler so it doesn't spin, the death is dealt with elsewhere.
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.parseQueue.async { self.consume(data) }
        }
        p.terminationHandler = { [weak self] ended in
            // The process that died is passed along: by the time this runs it may not be ours.
            DispatchQueue.main.async { self?.processEnded(ended) }
        }
        // Half a line left in the buffer by the helper that just died would otherwise glue itself
        // to the first line of this one.
        parseQueue.async { [weak self] in self?.buffer.removeAll() }
        do {
            try p.run()
        } catch {
            IslandLog.media.error("the adapter helper would not launch: \(String(describing: error), privacy: .public)")
            // A launch that throws is a death like any other. Returning quietly here is what used
            // to leave this backend switched on, holding nothing, and never asked again for the
            // rest of the session.
            helperDied(wasDeliveringTrack: false)
            return
        }
        process = p
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        // The helper is given the benefit of the doubt for one silence window. It has to be
        // allowed to boot before the watchdog may accuse it of having wedged, and the fallbacks
        // have no reason to wake up in the meantime.
        lastMessage = Date()
        lastMessageWasTrack = false
    }

    /// Nothing else notices a helper that stops writing without exiting — a main queue wedged by
    /// sleep/wake, an XPC round trip that never comes back. No termination handler ever runs for
    /// that helper, so without this it would hold the fallbacks shut for the rest of the session
    /// while saying nothing at all: a blank island, music playing, and no way to know why.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkForSilence() }
        timer.tolerance = 0.5
        // .common: a menu the user is holding open must not pause the one thing that is watching.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkForSilence() {
        guard !stopped, let p = process, !isAnswering else { return }
        IslandLog.media.error("the adapter helper has gone quiet; restarting it")
        // This death is ours to handle, so the process must not report it a second time.
        p.terminationHandler = nil
        // SIGTERM is delivered by the kernel and asks nothing of the helper's own run loop, so
        // even a thoroughly wedged helper goes away.
        if p.isRunning { p.terminate() }
        let wasDelivering = isDeliveringTrack
        releaseHelper()
        helperDied(wasDeliveringTrack: wasDelivering)
    }

    private func processEnded(_ ended: Process) {
        // A helper we have already replaced is allowed to die in peace. Acting on its death would
        // drop the reference to its *successor* and then start a third one behind it, leaving the
        // second alive, unreferenced, still feeding us reports and never terminated.
        guard Self.isTheHelperWeHold(ended, held: process) else { return }
        let wasDelivering = isDeliveringTrack
        releaseHelper()
        helperDied(wasDeliveringTrack: wasDelivering)
    }

    /// Whether the process that has just ended is the one we are relying on.
    static func isTheHelperWeHold(_ ended: Process?, held: Process?) -> Bool {
        guard let ended, let held else { return false }
        return ended === held
    }

    /// The one path out of every way a helper can stop being useful: it exited, it refused to
    /// launch, or it went silent and we killed it. All three cost the same and are answered the
    /// same, so none of them can quietly become the one that is never retried.
    private func helperDied(wasDeliveringTrack: Bool) {
        guard !stopped else { return }
        // Hand the island straight back to MediaRemote or AppleScript rather than leave the card
        // frozen on whatever was playing when the helper stopped.
        if wasDeliveringTrack { onUpdate?(nil) }
        guard let dylib = Self.dylibURL else { return }

        let now = Date()
        failures = BackendHealth.recentFailures(failures + [now], endingAt: now, window: Self.restartWindow)
        // Asked of the rule rather than counted again here. The same comparison written twice
        // is one that can be changed in one place and stay green in the other, and the test
        // that pins this budget was asserting a rule with no caller.
        let resting = BackendHealth.hasBlownBudget(failures, endingAt: now,
                                                   window: Self.restartWindow, budget: Self.restartBudget)
        if resting {
            IslandLog.media.error("the adapter helper has died \(self.failures.count, privacy: .public) times in quick succession; resting before it is tried again")
        }
        let delay = resting ? Self.restCooldown : min(Double(failures.count) * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.process == nil else { return }
            // A rest wipes the slate, or every later death would be over budget on arrival.
            if resting { self.failures.removeAll() }
            self.launch(dylib)
        }
    }

    // MARK: Parsing

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            parse(line)
        }
    }

    private func parse(_ line: Data) {
        // Only a payload we can read counts as the helper answering. A helper writing nonsense is
        // alive in the sense that matters to `ps` and in no other: better it be treated as silent,
        // restarted, and the fallbacks let through while that happens.
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let title = obj["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = obj["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        if title.isEmpty && artist.isEmpty {
            artworkHash = ""
            artwork = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process != nil else { return }
                let wasDelivering = self.isDeliveringTrack
                self.noteMessage(carryingTrack: false)
                // "Nothing is playing" is still an answer, and it only ends a card that this
                // backend put there.
                if wasDelivering { self.onUpdate?(nil) }
            }
            return
        }

        let album = obj["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = (obj["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (obj["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let rate = (obj["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let timestamp = (obj["kMRMediaRemoteNowPlayingInfoTimestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        let hash = obj["artworkHash"] as? String ?? ""
        let pid = (obj["pid"] as? NSNumber)?.int32Value ?? 0

        // Artwork cache lives on parseQueue; only the finished value crosses to the main thread.
        if !hash.isEmpty, hash != artworkHash, let b64 = obj["artworkBase64"] as? String, let data = Data(base64Encoded: b64) {
            artworkHash = hash
            artwork = NSImage(data: data)
            accent = artwork?.dominantColor() ?? .white
        } else if hash.isEmpty {
            artworkHash = ""
            artwork = nil
            accent = .white
        }
        let info = NowPlayingInfo(title: title, artist: artist, album: album,
                                  duration: duration, elapsed: elapsed, timestamp: timestamp,
                                  isPlaying: rate > 0, bundleID: nil,
                                  artwork: artwork, artworkID: artworkHash.hashValue, accent: accent)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.process != nil else { return }
            var delivered = info
            if pid > 0, let app = NSRunningApplication(processIdentifier: pid) { delivered.bundleID = app.bundleIdentifier }
            self.noteMessage(carryingTrack: true)
            self.onUpdate?(delivered)
        }
    }

    /// Health is a fact about the last few seconds, never a badge kept for the session.
    private func noteMessage(carryingTrack: Bool) {
        lastMessage = Date()
        lastMessageWasTrack = carryingTrack
    }
}
