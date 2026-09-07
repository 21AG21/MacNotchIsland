import AppKit

/// Hides the island while any app from Preferences.hiddenAppBundleIDs is frontmost.
/// (Stub: an implementation agent fills this in with NSWorkspace activation notifications.)
final class HiddenAppsMonitor {
    func start() {}
    func stop() {
        if ActivityCenter.shared.appSuppressed { ActivityCenter.shared.appSuppressed = false }
    }
}
