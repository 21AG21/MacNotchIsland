import AppKit
import CoreServices

/// Polls Music and Spotify with AppleScript. Used when MediaRemote yields nothing
/// (macOS 15.4 and later). Artwork is fetched only when the track changes, and again on the
/// next poll where a cover Spotify named could not be fetched in time.
///
/// Every script, polls and presses alike, runs on the one `ScriptQueue`, one at a time, each
/// inside a `with timeout`. Main-queue state: `poll`, the presses and `cancel` are called there,
/// and every answer comes back there.
final class AppleScriptBackend {
    enum Command { case togglePlayPause, pause, next, previous }

    /// How long one Apple event in a poll may wait for its player. A beach-balling player used to
    /// hold the poll for the two minutes an Apple event waits by default.
    static let pollTimeout = 4
    /// How long one Apple event in a press may wait.
    static let pressTimeout = 5
    /// How long a poll may run before the island is told "nothing" (`poll`).
    static let pollWatchdog: TimeInterval = 6

    /// A poll whose scripts have not come back yet, from when it went to the queue to when its
    /// answer came back to the main queue. While it is set no other poll is sent: the queue is
    /// serial, and a poll sent behind a player that is not answering only waits there, and then
    /// runs back to back with every other that was sent. The watchdog tells the island "nothing"
    /// after `pollWatchdog` without clearing this, which is what used to let the next tick queue
    /// another behind it, every tick, for as long as the player was stuck.
    private var pollRunning = false
    private var generation = 0

    /// One player's cover, as the poll last worked it out for its current track.
    private struct Cover {
        var key = ""
        var image: NSImage?
        var accent: NSColor = .white
        /// How many times this track's Spotify cover has been fetched and not arrived, see
        /// `fetchesCover`.
        var attempts = 0
    }

    /// Each player's cover, by bundle identifier. Queue state: only `query` reads and writes it.
    /// One cover was kept for both players, and a poll asks both, so with a track in each every
    /// poll was a new track twice over and fetched both covers again — Spotify's over the network.
    private var covers: [String: Cover] = [:]

    static let musicID = "com.apple.Music"
    static let spotifyID = "com.spotify.client"

    // MARK: Refusals

    /// The players that have turned the island down, by bundle identifier: a script sent to
    /// them came back -1743, which is macOS saying Automation was refused.
    ///
    /// That answer used to be swallowed with the "not running" one, so a refusal was
    /// indistinguishable from nothing playing — the backend's health said answering, Privacy
    /// said "Asked when needed" for ever, and the heart beside play simply did nothing. Kept
    /// here, where the answer arrives, for everything that has to say so. Cleared the next
    /// time a script to the same player goes through, which is what a grant in System
    /// Settings looks like from here. Written on the script queue and read on the main one, so
    /// it is behind a lock.
    private static let refusalLock = NSLock()
    private static var refused: Set<String> = []

    /// Whether `bundleID`'s player has refused the island's scripts this session.
    static func hasRefused(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        refusalLock.lock()
        defer { refusalLock.unlock() }
        return refused.contains(bundleID)
    }

    private static func note(_ bundleID: String, refused wasRefused: Bool) {
        refusalLock.lock()
        let changed = wasRefused ? refused.insert(bundleID).inserted : refused.remove(bundleID) != nil
        refusalLock.unlock()
        if changed, wasRefused { IslandLog.media.notice("Automation refused for \(bundleID, privacy: .public)") }
    }

    /// Whether every player this backend would ask right now has refused it, which is the one
    /// way it can be switched on, asked, and never answer with anything. Main thread: it reads
    /// the running applications. For `NowPlayingService`'s health, which calls this backend
    /// answering whenever it is asked.
    var isRefused: Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        Self.refusalLock.lock()
        defer { Self.refusalLock.unlock() }
        return Self.refusesEverything(running: running, refused: Self.refused)
    }

    /// Pure: at least one player is open to be asked, and each that is has said no.
    static func refusesEverything(running: Set<String>, refused: Set<String>) -> Bool {
        let asked = running.intersection([musicID, spotifyID])
        return !asked.isEmpty && asked.isSubset(of: refused)
    }

    /// Drops any in-flight poll's result (its blocked script cannot be interrupted, and it
    /// still holds the queue until its timeout) and every press still waiting its turn.
    func cancel() {
        generation += 1
        for press in presses { press.done?(false) }
        presses.removeAll()
    }

    // MARK: Polling

    /// What a poll came to.
    enum PollResult {
        /// Neither player is open, so nobody was asked.
        case noPlayer
        /// A player was asked: its track, or nil for nothing playing, or for no answer in time.
        case answered(NowPlayingInfo?)

        /// The track the island is told about: none, where there was no player to ask.
        var report: NowPlayingInfo? {
            guard case .answered(let info) = self else { return nil }
            return info
        }
    }

    /// `artworkLookup` is "Find missing album art", read on the main thread by the caller and
    /// carried to the poll's queue: Privacy lists the fetch of a cover Spotify names under that
    /// switch, and the poll fetched it whatever the switch said (`spotifyArtworkURL`).
    /// `preferring` is the player of the card on screen, see `choose`.
    ///
    /// Not sent while a press is running or waiting (`pressRunning`, `presses`). The queue is
    /// serial, and a poll sent the moment the last one came back went in ahead of a press made
    /// meanwhile: with one player not answering, a poll holds the queue for seconds, and the
    /// press waited behind it and then behind the next. Presses used to have a queue of their
    /// own so a slow poll never delayed a click; on the one queue, presses go first. The
    /// once-a-second tick asks again, so the poll skipped here is sent on the first of its
    /// turns after the presses are through.
    func poll(artworkLookup: Bool, preferring bundleID: String?, _ completion: @escaping (PollResult) -> Void) {
        guard !pollRunning, !pressRunning, presses.isEmpty else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let hasSpotify = running.contains(Self.spotifyID)
        let hasMusic = running.contains(Self.musicID)
        guard hasSpotify || hasMusic else {
            completion(.noPlayer)
            return
        }
        pollRunning = true
        generation += 1
        let myGeneration = generation
        // Watchdog: a player that is not answering holds the poll until its timeout. Report
        // "nothing" after `pollWatchdog` so the island does not hold a stale track; the poll
        // itself is still running, and no other is sent until it is back (`pollRunning`).
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollWatchdog) { [weak self] in
            guard let self, self.generation == myGeneration, self.pollRunning else { return }
            completion(.answered(nil))
        }
        ScriptQueue.async { [self] in
            var candidates: [NowPlayingInfo] = []
            if hasSpotify, let s = query(spotify: true, artworkLookup: artworkLookup) { candidates.append(s) }
            if hasMusic, let m = query(spotify: false, artworkLookup: artworkLookup) { candidates.append(m) }
            let chosen = Self.choose(candidates, preferring: bundleID)
            DispatchQueue.main.async {
                // Only one poll runs at a time, so this is always the one that set it.
                self.pollRunning = false
                guard self.generation == myGeneration else { return }
                completion(.answered(chosen))
            }
        }
    }

    /// Which player's report the island shows. Pure, so it is tested.
    ///
    /// One that is playing, and of two that are, the one the card is already showing. With
    /// neither playing, the card's player again: this used to be whichever was asked first, which
    /// is Spotify, so pausing Music from the card flipped it to Spotify's old paused track, and
    /// play then started Spotify.
    static func choose(_ candidates: [NowPlayingInfo], preferring bundleID: String?) -> NowPlayingInfo? {
        let playing = candidates.filter(\.isPlaying)
        let pool = playing.isEmpty ? candidates : playing
        if let bundleID, let same = pool.first(where: { $0.bundleID == bundleID }) { return same }
        return pool.first
    }

    private func query(spotify: Bool, artworkLookup: Bool) -> NowPlayingInfo? {
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
                    set m to ""
                    try
                        set m to (shuffling as text) & linefeed & (repeating as text)
                    end try
                    set d to 0
                    try
                        set d to (duration of t) as integer
                    on error
                        try
                            set d to (duration of t) / 1000
                        end try
                    end try
                    set p to 0
                    try
                        set p to ((player position) * 1000) as integer
                    on error
                        try
                            set p to player position
                        end try
                    end try
                    return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & d & linefeed & p & linefeed & (id of t) & linefeed & (artwork url of t) & linefeed & m
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
                    set m to ""
                    try
                        set m to (shuffle enabled as text) & linefeed & (song repeat as text)
                    end try
                    set d to 0
                    try
                        set d to ((duration of t) * 1000) as integer
                    on error
                        try
                            set d to duration of t
                        end try
                    end try
                    set p to 0
                    try
                        set p to ((player position) * 1000) as integer
                    on error
                        try
                            set p to player position
                        end try
                    end try
                    return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & d & linefeed & p & linefeed & (database ID of t) & linefeed & "" & linefeed & m
                end if
            end tell
            return ""
            """
        }
        let answer = run(ScriptQueue.timed(source, seconds: Self.pollTimeout), app: spotify ? Self.spotifyID : Self.musicID)
        // The moment the player said where its playhead was: taken here, before any cover is
        // fetched, or the clock read up to the cover's timeout behind.
        let answeredAt = Date()
        guard let result = answer, !result.isEmpty else { return nil }
        let parts = result.components(separatedBy: "\n")
        guard parts.count >= 7 else { return nil }
        let state = parts[0]
        let title = parts[1]
        let artist = parts[2]
        let album = parts[3]
        let duration = Self.scriptedSeconds(parts[4])
        let position = Self.scriptedSeconds(parts[5])
        let trackID = parts[6]
        let artworkURL = parts.count > 7 ? parts[7] : ""
        let bundle = spotify ? Self.spotifyID : Self.musicID

        let key = bundle + "|" + trackID + "|" + title
        var cover = covers[bundle] ?? Cover()
        if key != cover.key {
            cover = Cover(key: key)
            if !spotify {
                // Music hands its cover over itself, from the Mac: nothing leaves it.
                cover.image = fetchMusicArtwork()
                cover.accent = cover.image?.dominantColor() ?? .white
            }
        }
        // Spotify names its cover by address. It is fetched only with "Find missing album art"
        // on, and fetched again on the next poll where it did not arrive in time: a cover that
        // came late used to be dropped with the track already marked as done, and that track
        // never had one. Switching the setting on fetches this track's cover the same way.
        if spotify, Self.fetchesCover(hasCover: cover.image != nil, attempts: cover.attempts),
           let url = Self.spotifyArtworkURL(artworkURL, lookupEnabled: artworkLookup) {
            cover.attempts += 1
            cover.image = fetchSpotifyArtwork(url)
            cover.accent = cover.image?.dominantColor() ?? .white
        }
        covers[bundle] = cover
        // Changes when the cover arrives, so a cover that comes on a later poll is a changed
        // report and is drawn (`NowPlayingInfo ==` compares this, not the image).
        let artworkID = cover.image == nil ? 0 : key.hashValue

        var info = NowPlayingInfo(title: title, artist: artist, album: album,
                                  duration: duration, elapsed: position, timestamp: answeredAt,
                                  isPlaying: state == "playing", bundleID: bundle,
                                  artwork: cover.image, artworkID: artworkID, accent: cover.accent)
        info.shuffle = Self.scriptedShuffle(parts.count > 8 ? parts[8] : "")
        info.repeatMode = Self.scriptedRepeat(parts.count > 9 ? parts[9] : "", spotify: spotify)
        return info
    }

    /// Seconds out of a length or a playhead as the poll's script writes it: whole milliseconds,
    /// which the script works out itself (`* 1000 as integer`) so that no decimal separator is
    /// ever written.
    ///
    /// The script wrote the seconds as a real, and AppleScript writes a real with the decimal
    /// separator of the Mac's region: a comma was turned back into a point here, but a Mac set
    /// to a region that writes "٫" read every track as 0:00 long, playing from 0:00. An integer
    /// has no separator to get wrong. A real is still read, with any of the three separators:
    /// the script falls back to one for a length too long for an AppleScript integer, some 149
    /// hours of milliseconds. Anything else — "missing value" for a stream with no length — is
    /// nought, as it always was. Pure, so it is tested.
    static func scriptedSeconds(_ text: String) -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let milliseconds = Int(trimmed) { return TimeInterval(milliseconds) / 1000 }
        let pointed = trimmed.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "\u{066B}", with: ".")
        guard let seconds = Double(pointed), seconds.isFinite else { return 0 }
        return seconds
    }

    /// How many times a track's Spotify cover is fetched before the island stops asking.
    static let coverAttemptLimit = 3

    /// Whether this poll fetches the track's Spotify cover: it has none yet, and it has not been
    /// asked for `coverAttemptLimit` times already. Pure, so it is tested.
    static func fetchesCover(hasCover: Bool, attempts: Int) -> Bool {
        !hasCover && attempts < coverAttemptLimit
    }

    /// "true" or "false", as both players' dictionaries write a boolean; anything else is a
    /// player that would not say.
    static func scriptedShuffle(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Music says off, one or all. Spotify's dictionary has only a yes or no for repeating, and
    /// yes is read as the whole list, which is what its button does first.
    static func scriptedRepeat(_ text: String, spotify: Bool) -> NowPlayingInfo.RepeatMode? {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        if spotify {
            switch word {
            case "true": return .all
            case "false": return .off
            default: return nil
            }
        }
        return NowPlayingInfo.RepeatMode(rawValue: word)
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
        let outcome = ScriptQueue.execute(ScriptQueue.timed(source, seconds: Self.pollTimeout))
        guard outcome.succeeded, let data = outcome.descriptor?.data, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    /// The address of the cover Spotify names for a track, when it is to be fetched: an http
    /// or https one, and only with "Find missing album art" on. The fetch leaves the Mac, and
    /// Privacy lists it under that switch as one it stops. Pure, so it is tested.
    static func spotifyArtworkURL(_ text: String, lookupEnabled: Bool) -> URL? {
        guard lookupEnabled, let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// How long the poll waits for a Spotify cover.
    static let coverTimeout: TimeInterval = 2.5

    /// Fetches a cover, waiting no longer than `coverTimeout`. The request carries the same
    /// timeout, and one still out when the wait is over is cancelled: it used to run on for
    /// the shared session's sixty seconds with nobody left to take its answer.
    private func fetchSpotifyArtwork(_ url: URL) -> NSImage? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var fetched: Data?
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: Self.coverTimeout)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? (data != nil)
            if ok, let data {
                lock.lock()
                fetched = data
                lock.unlock()
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + Self.coverTimeout) == .timedOut { task.cancel() }
        lock.lock()
        let data = fetched
        lock.unlock()
        return data.flatMap { NSImage(data: $0) }
    }

    /// Runs a script against `bundleID`'s player and says whether it went through. A refusal is
    /// recorded rather than dropped, see `hasRefused`; a script that goes through clears it.
    /// On the script queue.
    @discardableResult
    private func execute(_ source: String, app bundleID: String) -> ScriptQueue.Outcome {
        let outcome = ScriptQueue.execute(source)
        if outcome.succeeded {
            Self.note(bundleID, refused: false)
        } else if outcome.errorNumber == AutomationConsent.refusedStatus {
            Self.note(bundleID, refused: true)
        } else if outcome.errorNumber == ScriptQueue.timedOutStatus {
            IslandLog.media.notice("\(bundleID, privacy: .public) did not answer in time")
        } else if outcome.errorNumber != -600 {
            // -600 = app not running, which says nothing about permission and is not logged.
            let reason = outcome.error.map { String(describing: $0) } ?? "the script did not compile"
            IslandLog.media.error("AppleScript error: \(reason, privacy: .public)")
        }
        return outcome
    }

    /// What a script to `bundleID`'s player returned, or nil where it did not go through.
    private func run(_ source: String, app bundleID: String) -> String? {
        execute(source, app: bundleID).text
    }

    /// The bundle identifier of the player a command goes to: Spotify's when it is the one
    /// playing, Music's otherwise, the same choice `command` makes of the name.
    private static func player(_ bundleID: String?) -> String {
        bundleID == spotifyID ? spotifyID : musicID
    }

    private static func appName(_ bundleID: String?) -> String {
        bundleID == spotifyID ? "Spotify" : "Music"
    }

    // MARK: Presses

    /// A button pressed on the card, on its way to a player by script.
    struct Press {
        enum Kind: Equatable { case toggle, pause, next, previous, seek, shuffle, repeatMode, like, unfavourite }
        var kind: Kind
        var player: String
        var source: String
        var at: Date
        /// Told on the main queue whether the script went through, where the caller wants to
        /// know (the heart). A press dropped without being sent is told no.
        var done: ((Bool) -> Void)? = nil
    }

    /// Presses waiting for the one before them to come back, oldest first. Main queue.
    private var presses: [Press] = []
    /// A press sent to the script queue and not back yet: running, or waiting there behind a
    /// poll that was already running. No poll is sent meanwhile (`poll`). Main queue.
    private var pressRunning = false

    /// How long a press may wait its turn and still be sent. One that has waited longer is
    /// behind a player that was not answering, and would land after the user has moved on — a
    /// play/pause that starts the music a quarter of a minute after it was pressed. A pause is
    /// the exception, see `stillWanted`.
    static let pressPatience: TimeInterval = 6

    /// The presses waiting once `press` has joined them. Pure, so it is tested.
    ///
    /// They used to queue without limit behind a script that was not coming back, and ran back
    /// to back when the player recovered: every play/pause pressed meanwhile, late. Now two
    /// play/pauses in a row cancel out, so presses made while the player is stuck add up to one
    /// toggle or none; a seek, a shuffle or a repeat replaces the one waiting before it, since
    /// only the last is what the user wants; and a next, previous or pause pressed again while
    /// one is still waiting is the same press.
    static func coalesced(_ waiting: [Press], adding press: Press) -> [Press] {
        var result = waiting
        switch press.kind {
        case .toggle:
            if let last = result.last, last.kind == .toggle, last.player == press.player {
                result.removeLast()
                return result
            }
        case .seek, .shuffle, .repeatMode:
            result.removeAll { $0.kind == press.kind && $0.player == press.player }
        case .next, .previous, .pause:
            if let last = result.last, last.kind == press.kind, last.player == press.player { return result }
        case .like, .unfavourite:
            break
        }
        result.append(press)
        return result
    }

    /// Whether a press that has waited since `press.at` is still worth sending. Pure, so it is
    /// tested.
    ///
    /// A pause always is. Sent late it stops music that is still playing, or finds it stopped
    /// already and does nothing; it cannot start anything, which is what patience is there to
    /// prevent. The sleep timer's pause, queued behind a press that was slow to come back, was
    /// dropped after six seconds with the card already showing paused and the music playing on.
    static func stillWanted(_ press: Press, now: Date) -> Bool {
        press.kind == .pause || now.timeIntervalSince(press.at) <= pressPatience
    }

    private func submit(_ kind: Press.Kind, source: String, bundleID: String?, done: ((Bool) -> Void)? = nil) {
        let press = Press(kind: kind, player: Self.player(bundleID),
                          source: ScriptQueue.timed(source, seconds: Self.pressTimeout), at: Date(), done: done)
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.enqueue(press) }
            return
        }
        enqueue(press)
    }

    /// Only presses without a `done` are ever coalesced away (`coalesced` never drops a heart),
    /// so nobody waits on an answer for a press that was folded into another.
    private func enqueue(_ press: Press) {
        presses = Self.coalesced(presses, adding: press)
        sendNextPress()
    }

    /// Patience is asked twice: here, of the presses still waiting, and again on the script
    /// queue, the moment the press would start. Asked here only, a press that passed went to
    /// the queue behind a poll already running there, and a poll held back by a player that
    /// was not answering ran it seconds later with nobody having asked whether it still should.
    private func sendNextPress() {
        guard !pressRunning else { return }
        let now = Date()
        while let first = presses.first, !Self.stillWanted(first, now: now) {
            presses.removeFirst()
            IslandLog.media.notice("dropped a press that waited too long for its player")
            first.done?(false)
        }
        guard !presses.isEmpty else { return }
        let press = presses.removeFirst()
        pressRunning = true
        ScriptQueue.async { [self] in
            let wanted = Self.stillWanted(press, now: Date())
            let succeeded = wanted ? execute(press.source, app: press.player).succeeded : false
            DispatchQueue.main.async {
                if !wanted { IslandLog.media.notice("dropped a press that waited too long for its player") }
                self.pressRunning = false
                press.done?(succeeded)
                self.sendNextPress()
            }
        }
    }

    func command(_ command: Command, bundleID: String?) {
        let verb: String
        let kind: Press.Kind
        switch command {
        case .togglePlayPause:
            verb = "playpause"
            kind = .toggle
        case .pause:
            verb = "pause"
            kind = .pause
        case .next:
            verb = "next track"
            kind = .next
        case .previous:
            verb = "previous track"
            kind = .previous
        }
        submit(kind, source: "tell application \"\(Self.appName(bundleID))\" to \(verb)", bundleID: bundleID)
    }

    func seek(to seconds: TimeInterval, bundleID: String?) {
        submit(.seek, source: "tell application \"\(Self.appName(bundleID))\" to set player position to \(Int(seconds))",
               bundleID: bundleID)
    }

    /// The two players name the same switch differently: Music's `shuffle enabled`, Spotify's
    /// `shuffling`. Both take a plain true or false.
    func setShuffle(_ on: Bool, bundleID: String?) {
        let source = bundleID == Self.spotifyID
            ? "tell application \"Spotify\" to set shuffling to \(on)"
            : "tell application \"Music\" to set shuffle enabled to \(on)"
        submit(.shuffle, source: source, bundleID: bundleID)
    }

    /// Music takes off, one or all; Spotify only whether it repeats at all.
    func setRepeat(_ mode: NowPlayingInfo.RepeatMode, bundleID: String?) {
        let source = bundleID == Self.spotifyID
            ? "tell application \"Spotify\" to set repeating to \(mode != .off)"
            : "tell application \"Music\" to set song repeat to \(mode.rawValue)"
        submit(.repeatMode, source: source, bundleID: bundleID)
    }

    /// Favourites the track in Music, and tells `done` on the main queue whether it did. The
    /// property was `loved` before Apple renamed the button Favourite, so the older word is
    /// tried when the newer one is refused. Spotify's dictionary has no way to save a track at
    /// all, so there is nothing to send it, and the answer is no.
    func like(bundleID: String?, done: @escaping (Bool) -> Void) {
        guard bundleID != Self.spotifyID else {
            DispatchQueue.main.async { done(false) }
            return
        }
        let source = """
        tell application "Music"
            try
                set favorited of current track to true
            on error
                set loved of current track to true
            end try
        end tell
        """
        submit(.like, source: source, bundleID: bundleID, done: done)
    }

    /// Music's heart, emptied: the other half of `like`, said the same two ways. What Music said
    /// comes back to `done` on the main queue. Automation refused (-1743) and Music not running
    /// (-600) are the two everybody meets; both are a heart that stays lit.
    func unfavourite(done: @escaping (Bool) -> Void) {
        let source = """
        tell application "Music"
            try
                set favorited of current track to false
            on error
                set loved of current track to false
            end try
        end tell
        """
        submit(.unfavourite, source: source, bundleID: Self.musicID, done: done)
    }
}

/// What macOS has said about the island sending Apple events to one player, asked without
/// putting a question on screen.
///
/// The Privacy row said "Asked when needed" whatever the answer had been, so a refusal —
/// easy to give to a prompt that arrives out of nowhere — left Music and Spotify dark with
/// nothing anywhere to say why. `AEDeterminePermissionToAutomateTarget` answers the question
/// without asking it; it answers only for a player that is open, and this session's own
/// refusals fill in for one that is not. The rules are pure; `asking(_:)` is the live half.
enum AutomationConsent: Equatable {
    case allowed
    case refused
    /// Never asked: the first script sent to it will ask.
    case notAsked
    /// Not open, and macOS only answers for a player that is.
    case notRunning
    case unknown

    /// errAEEventNotPermitted: the user said no. Also what a refused script comes back with.
    static let refusedStatus = -1743

    /// `AEDeterminePermissionToAutomateTarget`'s answer, as a word. -1744 is
    /// errAEEventWouldRequireUserConsent and -600 procNotFound.
    static func from(status: Int) -> AutomationConsent {
        switch status {
        case 0: return .allowed
        case refusedStatus: return .refused
        case -1744: return .notAsked
        case -600: return .notRunning
        default: return .unknown
        }
    }

    /// macOS's own answer where it gives one; where it cannot — the player is closed — a
    /// refusal this session has seen is the truer thing to say than nothing.
    static func merged(_ asked: AutomationConsent, refusedThisSession: Bool) -> AutomationConsent {
        switch asked {
        case .allowed, .refused, .notAsked: return asked
        case .notRunning, .unknown: return refusedThisSession ? .refused : asked
        }
    }

    /// The row's status for the players on this Mac. A refusal names the player, since that is
    /// the one to fix; a grant is only "Granted" when it covers them all.
    static func summary(_ players: [(name: String, consent: AutomationConsent)]) -> String {
        let refused = players.filter { $0.consent == .refused }.map(\.name)
        if !refused.isEmpty { return "Refused for " + refused.joined(separator: " and ") }
        let allowed = players.filter { $0.consent == .allowed }.map(\.name)
        if !allowed.isEmpty {
            return allowed.count == players.count ? "Granted" : "Granted for " + allowed.joined(separator: " and ")
        }
        return "Asked when needed"
    }

    /// Asks macOS about one player, never with a prompt. It can wait on the system's privacy
    /// daemon, so never on the main thread.
    static func asking(_ bundleID: String) -> AutomationConsent {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        return from(status: Int(status))
    }
}
