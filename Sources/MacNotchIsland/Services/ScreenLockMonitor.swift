import CoreGraphics
import Foundation

/// "Unlocked" animation when the Mac unlocks (Touch ID / password), mirroring Face ID in the island.
final class ScreenLockMonitor {
    /// Whether the screen is locked right now, as the window server reports the session.
    static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Whether nobody can be looking: the screen is locked, or the main display is asleep.
    static var screenIsLockedOrAsleep: Bool {
        screenIsLocked || CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    private var token: NSObjectProtocol?

    func start() {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
                let activity = IslandActivity(id: "unlock", kind: .unlock, content: .unlock, priority: 85)
                ActivityCenter.shared.showAlert(activity, duration: 1.2)
            }
    }

    func stop() {
        if let token { DistributedNotificationCenter.default().removeObserver(token) }
        token = nil
    }
}
