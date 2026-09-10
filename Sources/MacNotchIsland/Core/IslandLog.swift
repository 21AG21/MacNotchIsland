import Foundation
import os

/// The app's diagnostics, in the unified log so a report from another Mac can be read back:
///
///     log stream --predicate 'subsystem == "com.macnotchisland.app"' --level info
///
/// One category per part of the app that can fail on its own, so a report can be read back
/// by the thing that went wrong:
///
///     log show --last 10m --predicate 'category == "keys"'
///
/// Everything here goes through `Logger` and nothing through `NSLog`, which stamps no
/// subsystem at all — a line with no subsystem cannot be asked for by one, and half of what
/// the app had to say was invisible to its own support report.
enum IslandLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.macnotchisland.app"
    /// What opens and closes, and why.
    static let island = Logger(subsystem: subsystem, category: "island")
    /// Windows, Spaces and displays.
    static let panel = Logger(subsystem: subsystem, category: "panel")
    /// The now-playing backends: MediaRemote, the adapter helper, AppleScript.
    static let media = Logger(subsystem: subsystem, category: "media")
    /// The keyboard: the media-key event tap and the global hot keys.
    static let keys = Logger(subsystem: subsystem, category: "keys")
    /// CoreAudio: the output device, its level, the level tap.
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// DisplayServices and the brightness it will or will not set.
    static let display = Logger(subsystem: subsystem, category: "display")
    /// What the shelf and the clipboard keep on disk.
    static let store = Logger(subsystem: subsystem, category: "store")
    /// The notification history: the watcher reading a piece of system UI that Apple owes
    /// nobody a stable shape for, and the history it fills. Its own category because it is
    /// the part of the app most likely to be the thing that stopped working after a point
    /// release, and a support report has to be able to ask for exactly that.
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    /// Weather and the update check — anything that leaves the Mac.
    static let network = Logger(subsystem: subsystem, category: "network")
}
