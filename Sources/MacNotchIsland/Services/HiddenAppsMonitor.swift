import AppKit
import Combine

/// Hides the island while any app from Preferences.hiddenAppBundleIDs is frontmost
/// (Keynote during a talk, a game, a screen-sharing client). Event-driven: listens for
/// NSWorkspace activation notifications rather than polling.
final class HiddenAppsMonitor {
    private var activationObserver: NSObjectProtocol?
    private var prefsCancellable: AnyCancellable?

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.apply(bundleID: app?.bundleIdentifier)
        }

        prefsCancellable = Preferences.shared.$hiddenAppBundleIDs
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reevaluateFrontmost() }

        reevaluateFrontmost()
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        prefsCancellable = nil
        if ActivityCenter.shared.appSuppressed { ActivityCenter.shared.appSuppressed = false }
    }

    private func reevaluateFrontmost() {
        apply(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func apply(bundleID: String?) {
        let hidden = Self.isHidden(bundleID: bundleID, hidden: Preferences.shared.hiddenAppBundleIDs)
        guard ActivityCenter.shared.appSuppressed != hidden else { return }
        ActivityCenter.shared.appSuppressed = hidden
        if hidden { ActivityCenter.shared.clearInteraction() }
    }

    /// True when `bundleID` matches one of `hidden`, case-insensitively.
    static func isHidden(bundleID: String?, hidden: [String]) -> Bool {
        guard let bundleID else { return false }
        return hidden.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}
