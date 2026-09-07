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
        lhs.isPlaying == rhs.isPlaying && lhs.bundleID == rhs.bundleID && lhs.artworkID == rhs.artworkID
    }
}
