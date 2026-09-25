import AppKit

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var elapsed: TimeInterval
    var timestamp: Date
    var isPlaying: Bool
    var bundleID: String?
    var artwork: NSImage?
    var artworkID: Int
    var accent: NSColor
    /// Whether the player is shuffling, where it has said. Nil is a player that has not told
    /// anybody, which is a different thing from one that is playing in order.
    var shuffle: Bool? = nil
    /// The player's repeat, where it has said.
    var repeatMode: RepeatMode? = nil
    /// The buttons beside play that this player will honour, see `supportedCommands`. Worked
    /// out once, where the service takes a report in (`NowPlayingService.sanitized`).
    var supports: Set<Command> = []
    /// What MediaRemote itself said the player takes, from its list of supported commands.
    /// Nil when it gave no list, which is most of the time on some versions of macOS: a
    /// missing list says nothing either way, and the other evidence is weighed instead.
    var remoteSupports: Set<Command>? = nil

    /// The optional buttons of the transport row. Play, pause and the two skips are not here:
    /// every player takes those.
    enum Command: String, CaseIterable, Hashable {
        case shuffle
        case cycleRepeat = "repeat"
        case like
        case back15
        case forward15
    }

    /// Off, one, all — the three every player with a repeat button cycles through.
    enum RepeatMode: String, CaseIterable, Equatable {
        case off, one, all

        /// The next press, in the order Music and Spotify step through it: off, all, one.
        var next: RepeatMode {
            switch self {
            case .off: return .all
            case .all: return .one
            case .one: return .off
            }
        }
    }

    // MARK: - MediaRemote's numbers

    /// MediaRemote's own figures for the two modes, as its Now Playing dictionary reports them
    /// under `kMRMediaRemoteNowPlayingInfoShuffleMode` and `…RepeatMode`, and as
    /// `MRMediaRemoteSetShuffleMode` / `MRMediaRemoteSetRepeatMode` take them. Zero is
    /// "unknown", which is read as nothing having been said.
    static let remoteShuffleOff = 1
    static let remoteShuffleSongs = 3
    static let remoteRepeatOff = 1
    static let remoteRepeatOne = 2
    static let remoteRepeatAll = 3

    static func shuffle(fromRemote raw: Int?) -> Bool? {
        guard let raw, raw > 0 else { return nil }
        // 2 is albums and 3 is songs; both are shuffling.
        return raw != remoteShuffleOff
    }

    static func repeatMode(fromRemote raw: Int?) -> RepeatMode? {
        guard let raw else { return nil }
        if raw == remoteRepeatOff { return .off }
        if raw == remoteRepeatOne { return .one }
        if raw == remoteRepeatAll { return .all }
        return nil
    }

    static func remoteCode(shuffle on: Bool) -> Int { on ? remoteShuffleSongs : remoteShuffleOff }

    static func remoteCode(repeat mode: RepeatMode) -> Int {
        switch mode {
        case .off: return remoteRepeatOff
        case .one: return remoteRepeatOne
        case .all: return remoteRepeatAll
        }
    }

    /// The `MRMediaRemoteCommand` numbers that stand for each button, in the list of supported
    /// commands the helper reports. Advance and change are two ways of asking for the same
    /// thing (6 and 26 for shuffle, 7 and 25 for repeat); 21 is "like track". These come from
    /// the framework's reverse-engineered headers, not from anything Apple publishes.
    static let remoteCommandIDs: [Command: [Int]] = [
        .shuffle: [6, 26],
        .cycleRepeat: [7, 25],
        .like: [21],
    ]

    /// The buttons a list of MediaRemote command numbers covers. Numbers it does not know are
    /// left alone, which is what keeps a longer list from a newer macOS harmless.
    static func commands(fromRemote ids: [Int]) -> Set<Command> {
        let reported = Set(ids)
        var result: Set<Command> = []
        for (command, numbers) in remoteCommandIDs where numbers.contains(where: { reported.contains($0) }) {
            result.insert(command)
        }
        return result
    }

    /// Players the island can also reach with AppleScript, for when MediaRemote has nothing
    /// to say about a button.
    static let musicID = "com.apple.Music"
    static let spotifyID = "com.spotify.client"

    /// Whether AppleScript can press this button in this player: shuffle and repeat in Music
    /// and Spotify, the favourite in Music alone — Spotify's dictionary has no way to save a
    /// track.
    static func scriptable(_ command: Command, bundleID: String?) -> Bool {
        switch command {
        case .shuffle, .cycleRepeat: return bundleID == musicID || bundleID == spotifyID
        case .like: return bundleID == musicID
        case .back15, .forward15: return false
        }
    }

    /// Whether a favourite, once given, can be taken back from the island. In Music alone:
    /// its `favorited` (once `loved`) is a property a script can set to false as readily as
    /// to true, and Music answers AppleScript whatever MediaRemote makes of it. MediaRemote has
    /// a command to like a track and none to unlike one, and Spotify's dictionary has no way
    /// to save a track, let alone to unsave one.
    static func canTakeBackFavourite(bundleID: String?) -> Bool {
        bundleID == musicID
    }

    /// The buttons beside play that this player will honour. Pure, so the rule is tested.
    ///
    /// The fifteen-second skips are a seek from where the playhead is, the thing the scrubber
    /// already does, so a track with a length takes them and a live stream does not. The other
    /// three are honoured on any one piece of evidence: MediaRemote listing the command, the
    /// player reporting the mode (a player that says its shuffle is off has a shuffle), or
    /// AppleScript being able to do it for this app. A button with none of that behind it is
    /// drawn dimmed rather than pressed for nothing.
    static func supportedCommands(remote: Set<Command>?, shuffle: Bool?, repeatMode: RepeatMode?,
                                  bundleID: String?, duration: TimeInterval) -> Set<Command> {
        var result: Set<Command> = []
        if canSeek(duration: duration) { result.formUnion([.back15, .forward15]) }
        for command in [Command.shuffle, .cycleRepeat, .like] {
            let listed = remote?.contains(command) ?? false
            let reported: Bool
            switch command {
            case .shuffle: reported = shuffle != nil
            case .cycleRepeat: reported = repeatMode != nil
            default: reported = false
            }
            if listed || reported || scriptable(command, bundleID: bundleID) { result.insert(command) }
        }
        return result
    }

    /// Whether there is anywhere to seek to: a track with a length. Pure, so it is tested.
    ///
    /// A live radio stream has no length, nor does a podcast in a browser that has not
    /// measured one, and `NowPlayingService.sanitized` writes that down as zero. The
    /// fifteen-second skips always knew it; the scrubber did not, and a click anywhere on it
    /// asked for that fraction of nothing — a seek to 0:00, the start of an hour-long stream.
    /// The scrubber, the skips and `seek` itself all ask this one question now.
    static func canSeek(duration: TimeInterval) -> Bool {
        duration.isFinite && duration > 0
    }

    var canSeek: Bool { Self.canSeek(duration: duration) }

    /// Interpolated position using the elapsed value captured at `timestamp`.
    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return min(elapsed, duration > 0 ? duration : elapsed) }
        let p = elapsed + date.timeIntervalSince(timestamp)
        return duration > 0 ? min(max(0, p), duration) : max(0, p)
    }

    var appName: String {
        guard let id = bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "Now Playing" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func == (lhs: NowPlayingInfo, rhs: NowPlayingInfo) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album &&
        lhs.duration == rhs.duration && lhs.elapsed == rhs.elapsed && lhs.timestamp == rhs.timestamp &&
        lhs.isPlaying == rhs.isPlaying && lhs.bundleID == rhs.bundleID && lhs.artworkID == rhs.artworkID &&
        lhs.shuffle == rhs.shuffle && lhs.repeatMode == rhs.repeatMode && lhs.supports == rhs.supports &&
        lhs.remoteSupports == rhs.remoteSupports
    }
}
