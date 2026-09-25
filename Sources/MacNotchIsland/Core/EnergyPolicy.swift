import AppKit
import Combine
import IOKit.ps

/// One place that knows whether the Mac is asleep, on battery, or in Low Power Mode — and
/// whether anybody is looking at it — so every animation and poller can slow down or stop.
/// Competitors get 1-star reviews for idling at 5–10% CPU; this is how we stay near zero.
final class EnergyPolicy: ObservableObject {
    static let shared = EnergyPolicy()

    @Published private(set) var isAsleep = false
    @Published private(set) var isLowPower = false
    @Published private(set) var isOnBattery = false
    /// Awake, and nobody can be looking: the displays are asleep, the screen is locked, a
    /// screen saver is up, or the session has been switched away from. See `isUnattended(…)`.
    @Published private(set) var isUnattended = false

    /// The four ways of nobody looking, kept apart because each is ended by its own
    /// notification: the unlock says nothing about the displays, and the displays waking says
    /// nothing about the lock.
    private var displaysAsleep = false
    private var screenLocked = false
    private var screenSaverRunning = false
    private var sessionInactive = false

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var started = false

    private init() {}

    /// True when continuous animation should stop entirely.
    var animationsPaused: Bool {
        // Reduce Motion is a promise that nothing moves on its own, so it stops the marquee and
        // the visualizer loops too, not only the springs.
        return Self.animationsPaused(asleep: isAsleep, lowPower: isLowPower, onBattery: isOnBattery,
                                     pauseOnBattery: Preferences.shared.pauseAnimationsOnBattery,
                                     reduceMotion: IslandMotion.reduceMotion, unattended: isUnattended)
    }

    /// Minimum frame interval for continuous animations (visualizer, marquee).
    var animationInterval: TimeInterval {
        Self.animationInterval(asleep: isAsleep, lowPower: isLowPower, onBattery: isOnBattery,
                               pauseOnBattery: Preferences.shared.pauseAnimationsOnBattery, unattended: isUnattended)
    }

    /// Multiply timer intervals by this for polling work.
    var pollingMultiplier: Double {
        Self.pollingMultiplier(asleep: isAsleep, lowPower: isLowPower, onBattery: isOnBattery, unattended: isUnattended)
    }

    /// Whether nothing the island draws can be seen: the Mac asleep, or awake with nobody at
    /// it. Narrower than `animationsPaused`, which Reduce Motion and Low Power also set — work
    /// that is content rather than motion, the next line of a lyric, stops for this and not
    /// for those.
    var nobodyLooking: Bool { isAsleep || isUnattended }

    // MARK: Pure rules (unit-testable without touching NSWorkspace/IOKit/Preferences)

    /// Pure form of `animationsPaused`.
    static func animationsPaused(asleep: Bool, lowPower: Bool, onBattery: Bool, pauseOnBattery: Bool,
                                 reduceMotion: Bool = false, unattended: Bool = false) -> Bool {
        reduceMotion || asleep || unattended || lowPower || (onBattery && pauseOnBattery)
    }

    /// Pure form of `animationInterval`.
    static func animationInterval(asleep: Bool, lowPower: Bool, onBattery: Bool, pauseOnBattery: Bool,
                                  unattended: Bool = false) -> TimeInterval {
        if animationsPaused(asleep: asleep, lowPower: lowPower, onBattery: onBattery, pauseOnBattery: pauseOnBattery,
                            unattended: unattended) { return 1 }
        return onBattery ? 1.0 / 20.0 : 1.0 / 30.0
    }

    /// Pure form of `pollingMultiplier`.
    ///
    /// A Mac nobody is looking at is treated as one that is asleep. Its displays being dark,
    /// or locked, did nothing here before: every poller went on at its daytime rate for as long
    /// as the Mac sat at the lock screen or with its displays off — overnight, for a Mac set
    /// never to sleep — for an island nobody could see.
    static func pollingMultiplier(asleep: Bool, lowPower: Bool, onBattery: Bool, unattended: Bool = false) -> Double {
        if asleep || unattended { return 8 }
        if lowPower { return 4 }
        return onBattery ? 2 : 1
    }

    /// Whether nobody can be looking: any one of the four is enough. The island's own space is
    /// hidden under a lock or a screen saver (`IslandSpace.shows`), dark displays show nothing,
    /// and a session switched away from is somebody else's screen.
    static func isUnattended(displaysAsleep: Bool, locked: Bool, screenSaverRunning: Bool, sessionInactive: Bool) -> Bool {
        displaysAsleep || locked || screenSaverRunning || sessionInactive
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { policy in
            if !policy.isAsleep { policy.isAsleep = true }
        }
        observe(workspace, NSWorkspace.didWakeNotification) { policy in
            if policy.isAsleep { policy.isAsleep = false }
            // A Mac waking from sleep is showing no screen saver, whatever was last heard —
            // the rule `IslandSpace` follows, and for its reason: a stop that never came would
            // otherwise hold every poller at a crawl for good.
            policy.screenSaverRunning = false
            policy.resync()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { policy in
            policy.displaysAsleep = true
            policy.refreshUnattended()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { policy in
            policy.displaysAsleep = false
            policy.resync()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { policy in
            policy.sessionInactive = true
            policy.refreshUnattended()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { policy in
            policy.sessionInactive = false
            policy.resync()
        }
        let distributed: NotificationCenter = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { policy in
            policy.screenLocked = true
            policy.refreshUnattended()
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { policy in
            policy.screenLocked = false
            // Nobody unlocks a screen through a running screen saver, see `IslandSpace`.
            policy.screenSaverRunning = false
            policy.refreshUnattended()
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { policy in
            policy.screenSaverRunning = true
            policy.refreshUnattended()
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { policy in
            policy.screenSaverRunning = false
            policy.refreshUnattended()
        }
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { policy in
            policy.refreshLowPower()
        }
        refreshLowPower()
        // Launched at the lock screen, or with the displays already dark, is launched unattended.
        resync()

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let policy = Unmanaged<EnergyPolicy>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { policy.refreshPowerSource() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            powerSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        refreshPowerSource()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping (EnergyPolicy) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            handle(self)
        }
        observers.append((center, token))
    }

    /// The lock and the displays read from the window server rather than from what was last
    /// heard, on every way back to the user. A notification missed while the Mac was asleep
    /// would otherwise leave the island at a crawl, with its animations stopped, until the
    /// next lock came round to put it right.
    private func resync() {
        screenLocked = ScreenLockMonitor.screenIsLocked
        displaysAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        refreshUnattended()
    }

    /// Published only on a change. Every poller in the app rebuilds its timer on this object's
    /// `objectWillChange`, so an assignment that changes nothing restarts all of them.
    private func refreshUnattended() {
        let unattended = Self.isUnattended(displaysAsleep: displaysAsleep, locked: screenLocked,
                                           screenSaverRunning: screenSaverRunning, sessionInactive: sessionInactive)
        if unattended != isUnattended { isUnattended = unattended }
    }

    /// Published only on a change, for `refreshUnattended`'s reason. The power-state
    /// notification comes for changes that are not Low Power Mode's too.
    private func refreshLowPower() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPower != isLowPower { isLowPower = lowPower }
    }

    private func refreshPowerSource() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return }
        let onBattery = type == kIOPSBatteryPowerValue
        if onBattery != isOnBattery { isOnBattery = onBattery }
    }
}
