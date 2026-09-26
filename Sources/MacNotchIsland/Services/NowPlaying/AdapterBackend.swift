import AppKit

/// Runs MediaRemoteAdapter.dylib inside /usr/bin/perl (an Apple-signed host) and reads
/// the JSON stream it produces. This is what makes Now Playing work on macOS 15.4+ for
/// every app, not just Music and Spotify.
final class AdapterBackend {
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    /// Called on the main queue whenever `isAnswering` may have changed: the helper spoke, was
    /// started, died or was killed, the Mac woke, or the watchdog looked. What the service
    /// switches its own tick on and off by, see `NowPlayingService.needsTick`.
    var onHealthChange: (() -> Void)?

    /// The helper speaks every five seconds whether or not anything is playing, so silence for
    /// longer than two of those beats means the helper has stopped talking — not that the Mac
    /// has gone quiet. Everything above this class turns on that difference.
    static let silence: TimeInterval = 12

    /// How often the watchdog looks for that silence: twice in the window, so a helper that
    /// stops talking is caught within half a window of running out of it. It looked every two
    /// seconds, six times per window, to catch a silence of twelve; the looks in between found
    /// nothing they could act on. The tolerance keeps the latest look well inside the window,
    /// which `missedItsLooks` reads a gap longer than as a sleep.
    static let watchdogInterval: TimeInterval = silence / 2
    static let watchdogTolerance: TimeInterval = 1

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
    /// When the Mac, or its screens, last woke — or the watchdog found it had not been running,
    /// which is how a sleep looks from inside a timer. See `isOverdue`.
    private var wokeAt: Date?
    /// When the watchdog last looked, so a look that comes far too late can be told apart.
    private var lastCheck: Date?
    private var wakeObservers: [NSObjectProtocol] = []
    /// The covers the helper has sent, by the hash it names them with. Lives on `parseQueue`.
    private var covers = CoverCache()
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
    var isAnswering: Bool { !Self.isOverdue(lastMessage: lastMessage, wokeAt: wokeAt, now: Date(), within: Self.silence) }

    /// When `isAnswering` runs out if nothing more is heard, or nil for a helper never heard
    /// from, which is not answering now. The service sets its one look at the backends by this
    /// rather than asking every second whether the moment has come.
    var answeringUntil: Date? { Self.answeringUntil(lastMessage: lastMessage, wokeAt: wokeAt, within: Self.silence) }

    /// The last moment `isOverdue` is false, from the same two facts: the window, counted from
    /// the later of the last message and the last wake. Pure, and tested against `isOverdue`,
    /// so the two cannot come to disagree about when the helper stops counting.
    static func answeringUntil(lastMessage: Date?, wokeAt: Date?, within window: TimeInterval) -> Date? {
        guard let lastMessage else { return nil }
        let from = wokeAt.map { max($0, lastMessage) } ?? lastMessage
        return from.addingTimeInterval(window)
    }

    /// Whether a helper last heard from at `lastMessage` has been silent for longer than it may
    /// be. Pure, so the sleep can be tested without one.
    ///
    /// Silence is counted from the later of its last message and the last wake. A sleep is
    /// silence the helper did not choose: it was frozen with the rest of the Mac, and after
    /// anything longer than `silence` its last message was stale the moment the lid opened.
    /// The watchdog then killed a healthy helper on every wake, each death counted against its
    /// restart budget, and while it was down AppleScript was let loose on Music and Spotify —
    /// which could raise the first "control Music" prompt right at the lock screen. A wake
    /// starts the helper's clock again, the same benefit of the doubt a launch gives it. A
    /// helper never heard from at all is overdue however recent the wake: there is nothing
    /// there to wait for.
    static func isOverdue(lastMessage: Date?, wokeAt: Date?, now: Date, within window: TimeInterval) -> Bool {
        guard lastMessage != nil else { return true }
        if BackendHealth.isFresh(lastMessage, now: now, within: window) { return false }
        return !BackendHealth.isFresh(wokeAt, now: now, within: window)
    }

    /// Whether the watchdog, looking now and last at `lastCheck`, has been kept from looking for
    /// long enough that the silence it would find says nothing about the helper: the Mac slept,
    /// or the main thread did. The wake notification is not certain to arrive before the
    /// watchdog's first look after a sleep, and this is the watchdog noticing for itself.
    static func missedItsLooks(lastCheck: Date?, now: Date, window: TimeInterval) -> Bool {
        guard let lastCheck else { return false }
        return now.timeIntervalSince(lastCheck) > window
    }

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
        watchForWake()
    }

    func stop() {
        stopped = true
        watchdog?.invalidate()
        watchdog = nil
        lastCheck = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in wakeObservers { center.removeObserver(observer) }
        wakeObservers.removeAll()
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
    ///
    /// Says whether the command reached the helper, which is as far as anybody can know: the
    /// players do not answer a press.
    @discardableResult
    func send(_ command: String) -> Bool {
        guard let input, process?.isRunning == true, let data = (command + "\n").data(using: .utf8) else {
            IslandLog.media.error("dropped \(command, privacy: .public): the adapter helper is not listening")
            return false
        }
        do {
            try input.write(contentsOf: data)
            return true
        } catch {
            IslandLog.media.error("could not hand \(command, privacy: .public) to the adapter helper: \(String(describing: error), privacy: .public)")
            // A broken pipe means the helper is already gone whatever its exit status says yet;
            // let go of it now rather than write into it again on the next press.
            self.input = nil
            return false
        }
    }

    func refresh() { _ = send("refresh") }

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
        onHealthChange?()
    }

    /// Nothing else notices a helper that stops writing without exiting — a main queue wedged by
    /// sleep/wake, an XPC round trip that never comes back. No termination handler ever runs for
    /// that helper, so without this it would hold the fallbacks shut for the rest of the session
    /// while saying nothing at all: a blank island, music playing, and no way to know why.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in self?.checkForSilence() }
        timer.tolerance = Self.watchdogTolerance
        // .common: a menu the user is holding open must not pause the one thing that is watching.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// The Mac waking, and its screens waking, each start the helper's clock again; see
    /// `isOverdue`. The screens count too: a display that went to sleep on its own is a Mac
    /// nobody was using, where the helper's beat may have been held back with everything
    /// else's, and a few seconds' grace for a helper that did not need it costs nothing.
    private func watchForWake() {
        guard wakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.wokeAt = Date()
                self?.onHealthChange?()
            })
        }
    }

    private func checkForSilence() {
        let now = Date()
        if Self.missedItsLooks(lastCheck: lastCheck, now: now, window: Self.silence) { wokeAt = now }
        lastCheck = now
        guard !stopped, let p = process, !isAnswering else {
            // Awake anyway, so the service's look at the backends rides on this one.
            if !stopped { onHealthChange?() }
            return
        }
        IslandLog.media.error("the adapter helper has gone quiet; restarting it")
        // This death is ours to handle, so the process must not report it a second time.
        p.terminationHandler = nil
        // SIGTERM is delivered by the kernel and asks nothing of the helper's own run loop, so
        // even a thoroughly wedged helper goes away.
        if p.isRunning { p.terminate() }
        // What it last said, not whether it is answering: it is not, which is why it is being
        // killed, and read through `isDeliveringTrack` this was always false here. The card it
        // put up then stayed, playing, with its clock running, for as long as nobody else spoke.
        let wasDelivering = lastMessageWasTrack
        releaseHelper()
        helperDied(wasDeliveringTrack: wasDelivering)
    }

    private func processEnded(_ ended: Process) {
        // A helper we have already replaced is allowed to die in peace. Acting on its death would
        // drop the reference to its *successor* and then start a third one behind it, leaving the
        // second alive, unreferenced, still feeding us reports and never terminated.
        guard Self.isTheHelperWeHold(ended, held: process) else { return }
        // As in `checkForSilence`: what it last said, however long ago.
        let wasDelivering = lastMessageWasTrack
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
        // And the fallbacks their tick: a helper that is gone is not answering.
        onHealthChange?()
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
        // Bytes are taken in whatever else the report says. The helper sends a cover's bytes once,
        // when its hash changes, and a report with no title can be the one that carries them.
        let hash = obj["artworkHash"] as? String ?? ""
        if !hash.isEmpty, covers.cover(for: hash) == nil,
           let b64 = obj["artworkBase64"] as? String, let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
            covers.remember(image, accent: image.dominantColor(), for: hash)
        }
        let title = obj["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = obj["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        if title.isEmpty && artist.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process != nil else { return }
                self.noteMessage(carryingTrack: false)
                // "Nothing is playing" is an answer, and it is always passed on; the service
                // decides whose card it ends (`NowPlayingService.nothingEndsCard`). Passed on
                // only after a track, a helper started afresh — by a restart, or by the user —
                // could never end the card the one before it left.
                self.onUpdate?(nil)
            }
            return
        }

        let album = obj["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = (obj["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let reportedElapsed = obj["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber
        let rate = (obj["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
        let reportedTimestamp = obj["kMRMediaRemoteNowPlayingInfoTimestamp"] as? NSNumber
        let timestamp = reportedTimestamp.map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        let pid = (obj["pid"] as? NSNumber)?.int32Value ?? 0
        // An older helper does not send it; the rate decides then.
        let flag = obj["isPlaying"] as? Bool

        // The cache lives on parseQueue; only the finished value crosses to the main thread. A
        // report that names no cover is a track without one, and leaves the cache as it is.
        let cover = hash.isEmpty ? nil : covers.cover(for: hash)
        var info = NowPlayingInfo(title: title, artist: artist, album: album,
                                  duration: duration, elapsed: reportedElapsed?.doubleValue ?? 0, timestamp: timestamp,
                                  isPlaying: NowPlayingInfo.isPlaying(rate: rate, flag: flag), bundleID: nil,
                                  artwork: cover?.image, artworkID: cover == nil ? 0 : hash.hashValue,
                                  accent: cover?.accent ?? .white)
        info.reportsPosition = reportedElapsed != nil || reportedTimestamp != nil
        Self.readModes(from: obj, into: &info)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.process != nil else { return }
            var delivered = info
            if pid > 0, let app = NSRunningApplication(processIdentifier: pid) { delivered.bundleID = app.bundleIdentifier }
            self.noteMessage(carryingTrack: true)
            self.onUpdate?(delivered)
        }
    }

    /// The covers the helper has sent, by the hash it names each with.
    ///
    /// The helper sends a cover's bytes only when its hash differs from the one it sent last,
    /// so a report naming a hash with no bytes means "the cover you already have". This used to
    /// be one cover, thrown away by any report without artwork — usual between tracks, or over
    /// an advert — and the next track with the same cover then came as a hash with nothing to
    /// match it, and had no cover at all. A handful are kept, and a report with no cover keeps
    /// them. Pure, so it is tested.
    struct CoverCache {
        static let limit = 8
        private var entries: [String: (image: NSImage, accent: NSColor)] = [:]
        /// Oldest first.
        private(set) var order: [String] = []

        init() {}

        func cover(for hash: String) -> (image: NSImage, accent: NSColor)? { entries[hash] }

        mutating func remember(_ image: NSImage, accent: NSColor, for hash: String) {
            entries[hash] = (image, accent)
            order.removeAll { $0 == hash }
            order.append(hash)
            while order.count > Self.limit {
                entries[order.removeFirst()] = nil
            }
        }
    }

    /// The shuffle and repeat modes, where MediaRemote reported them, and the helper's list of
    /// the commands the player takes, where it could get one. Each is optional in the payload —
    /// an older helper sends none of them — and a missing one is left as nothing said.
    static func readModes(from obj: [String: Any], into info: inout NowPlayingInfo) {
        info.shuffle = NowPlayingInfo.shuffle(fromRemote: (obj["kMRMediaRemoteNowPlayingInfoShuffleMode"] as? NSNumber)?.intValue)
        info.repeatMode = NowPlayingInfo.repeatMode(fromRemote: (obj["kMRMediaRemoteNowPlayingInfoRepeatMode"] as? NSNumber)?.intValue)
        if let numbers = obj["supportedCommands"] as? [NSNumber] {
            info.remoteSupports = NowPlayingInfo.commands(fromRemote: numbers.map(\.intValue))
        }
    }

    /// Health is a fact about the last few seconds, never a badge kept for the session.
    private func noteMessage(carryingTrack: Bool) {
        lastMessage = Date()
        lastMessageWasTrack = carryingTrack
        onHealthChange?()
    }
}
