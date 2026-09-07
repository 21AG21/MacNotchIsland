import AppKit
import Combine

/// Hides the island while the frontmost app has a window covering an entire screen
/// (full-screen video, games, presentations). Polls the window list every 2 s, scaled by
/// EnergyPolicy, and only while the preference is on.
final class FullscreenMonitor {
    private var timer: Timer?
    private var energyCancellable: AnyCancellable?

    func start() {
        guard timer == nil else { return }
        scheduleTimer()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        energyCancellable = nil
        if ActivityCenter.shared.fullscreenSuppressed { ActivityCenter.shared.fullscreenSuppressed = false }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = 2.0 * EnergyPolicy.shared.pollingMultiplier
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = interval * 0.25
    }

    private func tick() {
        let suppressed = Self.frontmostAppIsFullScreen()
        if ActivityCenter.shared.fullscreenSuppressed != suppressed {
            ActivityCenter.shared.fullscreenSuppressed = suppressed
            if suppressed { ActivityCenter.shared.clearInteraction() }
        }
    }

    /// True when the frontmost app (not us, not Finder) owns an on-screen window whose
    /// bounds equal a screen's full frame.
    static func frontmostAppIsFullScreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleIdentifier != "com.apple.finder" else { return false }
        let pid = app.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let screens = NSScreen.screens.map { screen -> CGRect in
            // CGWindowList uses a top-left origin; compare sizes and a flipped origin.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            return CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if screens.contains(where: { screenCoversWindow($0, bounds) }) { return true }
        }
        return false
    }

    static func screenCoversWindow(_ screen: CGRect, _ window: CGRect) -> Bool {
        abs(screen.width - window.width) < 2 && abs(screen.height - window.height) < 2 &&
        abs(screen.minX - window.minX) < 2 && abs(screen.minY - window.minY) < 2
    }
}
