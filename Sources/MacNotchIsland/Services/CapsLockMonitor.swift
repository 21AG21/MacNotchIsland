import AppKit
import ApplicationServices
import Combine

/// Caps Lock on/off pill.
///
/// With Accessibility granted, AppKit says when a modifier changes: a global `.flagsChanged`
/// monitor hears the key pressed in every other app and a local one hears it in this one, and
/// the key is not polled. Without it a global monitor hears no key of any kind, so
/// `NSEvent.modifierFlags` — which needs no permission — is read once a second instead,
/// slowed further by `EnergyPolicy`. Which of the two is chosen again whenever the permission
/// may have changed (`mode`).
final class CapsLockMonitor {
    /// Once a second: a pill up to a second late is still the answer to the key, and the
    /// 0.6 s it polled at before was nearly two wakeups a second, every second the app ran,
    /// for a key pressed a few times a day.
    static let basePollInterval: TimeInterval = 1

    /// How often a poll looks at whether Accessibility has been granted since, in case the
    /// announcement that it was (see `start`) went unheard. In polls.
    static let trustCheckEvery = 30

    /// How often, while the monitors are listening, the permission they stand on is looked at.
    ///
    /// Taking Accessibility away does not remove a monitor; it just stops hearing anything, and
    /// the only other word of it is the announcement `start` listens for. One missed, and the
    /// pill was gone for the rest of the run with nothing polling to bring it back. Thirty
    /// seconds is one cheap question twice a minute, slower for the energy policy, and it is
    /// the only thing standing between a missed announcement and a key that never answers.
    static let baseTrustCheckInterval: TimeInterval = 30

    /// How the key is being listened for.
    enum Mode: Equatable {
        /// Both monitors, and nothing polled but the permission (`baseTrustCheckInterval`).
        case events
        /// `NSEvent.modifierFlags` on a timer (`pollInterval`), and the permission looked at
        /// every `trustCheckEvery` polls in case it has been given.
        case polling
    }

    /// Events only while they can be heard: the permission is there and the global monitor was
    /// accepted. Anything less is the poll. Pure, so it is tested.
    static func mode(trusted: Bool, monitorsInstalled: Bool) -> Mode {
        trusted && monitorsInstalled ? .events : .polling
    }

    /// The poll's interval at a given energy multiplier. Pure, so it is tested.
    static func pollInterval(multiplier: Double) -> TimeInterval {
        basePollInterval * max(1, multiplier)
    }

    /// How often the timer fires in a mode, at a given energy multiplier. Pure, so it is tested.
    static func interval(for mode: Mode, multiplier: Double) -> TimeInterval {
        switch mode {
        case .polling: return pollInterval(multiplier: multiplier)
        case .events: return baseTrustCheckInterval * max(1, multiplier)
        }
    }

    private var running = false
    private var listening = Mode.polling
    /// The poll in `.polling`, the permission check in `.events`.
    private var timer: Timer?
    private var monitors: [Any] = []
    private var trustObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var last = false
    private var polls = 0
    private var energyCancellable: AnyCancellable?

    func start() {
        guard !running else { return }
        running = true
        last = NSEvent.modifierFlags.contains(.capsLock)
        // The Accessibility list changing is announced, though not whose entry changed; the
        // way of listening is chosen again then, either way round. The answer lags the
        // announcement, hence the moment's wait.
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.chooseHowToListen() }
            }
        // The key as it is now, whenever the Mac comes back or another app comes forward. A
        // global monitor hears nothing while an app holds Secure Input — a password field, a
        // terminal that has asked for it — and nothing at all across sleep, so a key pressed
        // then is otherwise only found at the next press. Reading it costs no permission.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.check(NSEvent.modifierFlags.contains(.capsLock))
            })
        }
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
        chooseHowToListen()
    }

    func stop() {
        guard running else { return }
        running = false
        stopWatching()
        timer?.invalidate()
        timer = nil
        energyCancellable?.cancel()
        energyCancellable = nil
        if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
        trustObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    /// Events when they can be had, the poll when they cannot.
    private func chooseHowToListen() {
        guard running else { return }
        let trusted = AXIsProcessTrusted()
        let next = Self.mode(trusted: trusted, monitorsInstalled: trusted && watchEvents())
        if next == .polling { stopWatching() }
        if next != listening {
            listening = next
            polls = 0
            // The other mode's timer, at the other mode's pace.
            timer?.invalidate()
            timer = nil
        }
        scheduleTimer()
        // Whatever the key did while neither was listening.
        check(NSEvent.modifierFlags.contains(.capsLock))
    }

    // MARK: Events

    /// Both monitors or neither: a local one alone hears the key only while this app is in
    /// front, which is almost never.
    private func watchEvents() -> Bool {
        guard monitors.isEmpty else { return true }
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.check(event.modifierFlags.contains(.capsLock))
        }) else { return false }
        monitors.append(global)
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.check(event.modifierFlags.contains(.capsLock))
            return event
        }) {
            monitors.append(local)
        }
        return true
    }

    private func stopWatching() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    // MARK: The timer

    /// Rebuilds the timer at the current mode's interval and the current policy: 1 s polling,
    /// up to 8 s asleep or with nobody at the Mac, and thirty times that for the permission
    /// check. Left alone when the interval has not changed, so a policy change that does not
    /// touch it does not push the next look back.
    private func scheduleTimer() {
        guard running else { return }
        let interval = Self.interval(for: listening, multiplier: EnergyPolicy.shared.pollingMultiplier)
        if let timer, abs(timer.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.fire() }
        timer?.tolerance = interval / 2
    }

    private func fire() {
        switch listening {
        case .polling:
            check(NSEvent.modifierFlags.contains(.capsLock))
            polls += 1
            if polls % Self.trustCheckEvery == 0, AXIsProcessTrusted() { chooseHowToListen() }
        case .events:
            // Taken away without the announcement being heard: the monitors are deaf now, and
            // the poll is all there is.
            if !AXIsProcessTrusted() { chooseHowToListen() }
        }
    }

    // MARK: The pill

    private func check(_ on: Bool) {
        guard on != last else { return }
        last = on
        let custom = CustomActivity(title: "Caps Lock", symbol: on ? "capslock.fill" : "capslock",
                                    tint: on ? "white" : "gray", trailingText: on ? "On" : "Off")
        ActivityCenter.shared.showAlert(IslandActivity(id: "capslock", kind: .custom, content: .custom(custom), priority: 85),
                                        duration: 1.2, haptic: false)
    }
}
