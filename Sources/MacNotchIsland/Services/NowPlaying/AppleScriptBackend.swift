import AppKit
import CoreServices

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
    /// A cover Spotify named that was not fetched because "Find missing album art" was off,
    /// so switching it on fetches this track's cover rather than waiting for the next track.
    private var artworkWithheld = false

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
    /// Settings looks like from here. Both queues write it, so it is behind a lock.
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

    /// Drop any in-flight poll's result (its blocked NSAppleScript call can't be interrupted).
    func cancel() {
        generation += 1
        inFlight = false
    }

    /// `artworkLookup` is "Find missing album art", read on the main thread by the caller and
    /// carried to the poll's queue: Privacy lists the fetch of a cover Spotify names under that
    /// switch, and the poll fetched it whatever the switch said (`spotifyArtworkURL`).
    func poll(artworkLookup: Bool, _ completion: @escaping (NowPlayingInfo?) -> Void) {
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
            if hasSpotify, let s = query(spotify: true, artworkLookup: artworkLookup) { candidates.append(s) }
            if hasMusic, let m = query(spotify: false, artworkLookup: artworkLookup) { candidates.append(m) }
            let chosen = candidates.first(where: { $0.isPlaying }) ?? candidates.first
            DispatchQueue.main.async {
                guard self.generation == myGeneration else { return }
                self.inFlight = false
                completion(chosen)
            }
        }
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
                    return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) / 1000) & linefeed & (player position) & linefeed & (id of t) & linefeed & (artwork url of t) & linefeed & m
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
                    return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position) & linefeed & (database ID of t) & linefeed & "" & linefeed & m
                end if
            end tell
            return ""
            """
        }
        guard let result = run(source, app: spotify ? Self.spotifyID : Self.musicID), !result.isEmpty else { return nil }
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
        if key != artworkKey || (artworkWithheld && artworkLookup) {
            artworkKey = key
            if spotify {
                if let url = Self.spotifyArtworkURL(artworkURL, lookupEnabled: artworkLookup) {
                    artwork = fetchSpotifyArtwork(url)
                    artworkWithheld = false
                } else {
                    artwork = nil
                    artworkWithheld = Self.spotifyArtworkURL(artworkURL, lookupEnabled: true) != nil
                }
            } else {
                // Music hands its cover over itself, from the Mac: nothing leaves it.
                artwork = fetchMusicArtwork()
                artworkWithheld = false
            }
            artworkID = key.hashValue
            accent = artwork?.dominantColor() ?? .white
        }

        var info = NowPlayingInfo(title: title, artist: artist, album: album,
                                  duration: duration, elapsed: position, timestamp: Date(),
                                  isPlaying: state == "playing", bundleID: bundle,
                                  artwork: artwork, artworkID: artworkID, accent: accent)
        info.shuffle = Self.scriptedShuffle(parts.count > 8 ? parts[8] : "")
        info.repeatMode = Self.scriptedRepeat(parts.count > 9 ? parts[9] : "", spotify: spotify)
        return info
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
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let data = descriptor.data
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    /// The address of the cover Spotify names for a track, when it is to be fetched: an http
    /// or https one, and only with "Find missing album art" on. The fetch leaves the Mac, and
    /// Privacy lists it under that switch as one it stops. Pure, so it is tested.
    static func spotifyArtworkURL(_ text: String, lookupEnabled: Bool) -> URL? {
        guard lookupEnabled, let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private func fetchSpotifyArtwork(_ url: URL) -> NSImage? {
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

    /// Runs a script against `bundleID`'s player. A refusal is recorded rather than dropped,
    /// see `hasRefused`; a script that goes through clears it.
    private func run(_ source: String, app bundleID: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            // -600 = app not running, which says nothing about permission and is not logged.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == AutomationConsent.refusedStatus {
                Self.note(bundleID, refused: true)
            } else if code != -600 {
                IslandLog.media.error("AppleScript error: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
        Self.note(bundleID, refused: false)
        return descriptor.stringValue
    }

    /// The bundle identifier of the player a command goes to: Spotify's when it is the one
    /// playing, Music's otherwise, the same choice `command` makes of the name.
    private static func player(_ bundleID: String?) -> String {
        bundleID == spotifyID ? spotifyID : musicID
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
        commandQueue.async { _ = self.run("tell application \"\(app)\" to \(verb)", app: Self.player(bundleID)) }
    }

    func seek(to seconds: TimeInterval, bundleID: String?) {
        let app = bundleID == Self.spotifyID ? "Spotify" : "Music"
        commandQueue.async { _ = self.run("tell application \"\(app)\" to set player position to \(Int(seconds))", app: Self.player(bundleID)) }
    }

    /// The two players name the same switch differently: Music's `shuffle enabled`, Spotify's
    /// `shuffling`. Both take a plain true or false.
    func setShuffle(_ on: Bool, bundleID: String?) {
        let source = bundleID == Self.spotifyID
            ? "tell application \"Spotify\" to set shuffling to \(on)"
            : "tell application \"Music\" to set shuffle enabled to \(on)"
        commandQueue.async { _ = self.run(source, app: Self.player(bundleID)) }
    }

    /// Music takes off, one or all; Spotify only whether it repeats at all.
    func setRepeat(_ mode: NowPlayingInfo.RepeatMode, bundleID: String?) {
        let source = bundleID == Self.spotifyID
            ? "tell application \"Spotify\" to set repeating to \(mode != .off)"
            : "tell application \"Music\" to set song repeat to \(mode.rawValue)"
        commandQueue.async { _ = self.run(source, app: Self.player(bundleID)) }
    }

    /// Favourites the track in Music. The property was `loved` before Apple renamed the button
    /// Favourite, so the older word is tried when the newer one is refused. Spotify's
    /// dictionary has no way to save a track at all, so there is nothing to send it.
    func like(bundleID: String?) {
        guard bundleID != Self.spotifyID else { return }
        let source = """
        tell application "Music"
            try
                set favorited of current track to true
            on error
                set loved of current track to true
            end try
        end tell
        """
        commandQueue.async { _ = self.run(source, app: Self.player(bundleID)) }
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
