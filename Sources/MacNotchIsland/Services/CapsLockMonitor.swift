import AppKit
import ApplicationServices
import Combine

/// Caps Lock on/off pill.
///
/// With Accessibility granted, AppKit says when a modifier changes: a global `.flagsChanged`
/// monitor hears the key pressed in every other app and a local one hears it in this one, and
/// nothing is polled at all. Without it a global monitor hears no key of any kind, so
/// `NSEvent.modifierFlags` — which needs no permission — is read once a second instead,
/// slowed further by `EnergyPolicy`.
final class CapsLockMonitor {
    /// Once a second: a pill up to a second late is still the answer to the key, and the
    /// 0.6 s it polled at before was nearly two wakeups a second, every second the app ran,
    /// for a key pressed a few times a day.
    static let basePollInterval: TimeInterval = 1

    /// How often a poll looks at whether Accessibility has been granted since, in case the
    /// announcement that it was (see `start`) went unheard. In polls.
    static let trustCheckEvery = 30

    /// The poll's interval at a given energy multiplier. Pure, so it is tested.
    static func pollInterval(multiplier: Double) -> TimeInterval {
        basePollInterval * max(1, multiplier)
    }

    private var running = false
    private var timer: Timer?
    private var monitors: [Any] = []
    private var trustObserver: NSObjectProtocol?
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
        chooseHowToListen()
    }

    func stop() {
        guard running else { return }
        running = false
        stopWatching()
        stopPolling()
        if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
        trustObserver = nil
    }

    /// Events when they can be had, the poll when they cannot.
    private func chooseHowToListen() {
        guard running else { return }
        if AXIsProcessTrusted(), watchEvents() {
            stopPolling()
        } else {
            stopWatching()
            startPolling()
        }
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

    // MARK: Polling

    private func startPolling() {
        scheduleTimer()
        guard energyCancellable == nil else { return }
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        energyCancellable?.cancel()
        energyCancellable = nil
    }

    /// Rebuilds the poll timer at the current policy interval: 1 s, up to 8 s asleep or with
    /// nobody at the Mac. Left alone when the interval has not changed, so a policy change
    /// that does not touch it does not push the next look back.
    private func scheduleTimer() {
        guard running, monitors.isEmpty else { return }
        let interval = Self.pollInterval(multiplier: EnergyPolicy.shared.pollingMultiplier)
        if let timer, abs(timer.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = interval / 2
    }

    private func poll() {
        check(NSEvent.modifierFlags.contains(.capsLock))
        polls += 1
        if polls % Self.trustCheckEvery == 0, AXIsProcessTrusted() { chooseHowToListen() }
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
