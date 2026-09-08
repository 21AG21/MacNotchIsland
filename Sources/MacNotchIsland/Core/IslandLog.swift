import Foundation
import os

/// The app's diagnostics, in the unified log so a report from another Mac can be read back:
///
///     log stream --predicate 'subsystem == "com.macnotchisland.app"' --level info
///
/// `island` records what opens and closes and why; `panel` records windows, Spaces and displays.
enum IslandLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.macnotchisland.app"
    static let island = Logger(subsystem: subsystem, category: "island")
    static let panel = Logger(subsystem: subsystem, category: "panel")
}
