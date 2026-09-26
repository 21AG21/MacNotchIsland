import AppKit
import Combine
import Foundation

/// Stopwatch Live Activity (added to the iPhone's island in iOS 17).
///
/// Measured on `uptime`, a clock nobody sets, so neither the clock being set by hand nor the
/// network time catching up after a wake moves the reading or a lap. The views draw from the
/// wall clock, a `TimelineView`'s date, so the state's `startedAt` is moved to agree with the
/// measurement whenever the wall clock is set and whenever anything here changes
/// (`StopwatchState.reanchored`). Nothing is kept across a relaunch: the stopwatch starts again
/// from nothing, as it always has.
final class IslandStopwatch: ObservableObject {
    static let shared = IslandStopwatch()

    @Published private(set) var state: StopwatchState?

    /// Seconds on a clock that only goes forward and goes on counting while the Mac sleeps:
    /// `mach_continuous_time`. Not `ProcessInfo.systemUptime`, whose `mach_absolute_time`
    /// stands still while the Mac sleeps, so a stopwatch left running over a closed lid would
    /// come back short by the whole night; and not the wall clock, which can be set. Swapped
    /// for a hand-wound clock by the tests.
    var uptime: () -> TimeInterval = IslandStopwatch.continuousUptime

    static func continuousUptime() -> TimeInterval {
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.denom != 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let ticks = Double(mach_continuous_time())
        return ticks * Double(base.numer) / Double(base.denom) / 1_000_000_000
    }

    private var clockObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private init() {
        // The wall clock set, or the Mac awake again: the reading is where it was, and the
        // views' `startedAt` is moved to say so.
        let local = NotificationCenter.default
        clockObservers.append((local, local.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.clockMoved()
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        clockObservers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.clockMoved()
        }))
    }

    func start() {
        let now = Date(), ticks = uptime()
        if var s = state {
            guard !s.isRunning else { return }
            s.startedAt = now
            s.startedUptime = ticks
            s.isRunning = true
            state = s
        } else {
            state = StopwatchState(startedAt: now, startedUptime: ticks)
        }
        publish()
    }

    func stop() {
        guard var s = state, s.isRunning else { return }
        s.accumulated = max(0, s.elapsed(uptime: uptime(), at: Date()))
        s.isRunning = false
        s.startedUptime = nil
        state = s
        publish()
    }

    func lap() {
        guard var s = state, s.isRunning else { return }
        let now = Date(), ticks = uptime()
        s.laps.append(max(0, s.elapsed(uptime: ticks, at: now)))
        state = s.reanchored(uptime: ticks, now: now)
        publish()
    }

    func reset() {
        state = nil
        ActivityCenter.shared.end(id: "stopwatch")
    }

    /// Moves `startedAt` to where the wall clock now puts the start of this run.
    func clockMoved(now: Date = Date()) {
        guard let s = state, s.isRunning else { return }
        let moved = s.reanchored(uptime: uptime(), now: now)
        guard moved != s else { return }
        state = moved
        publish()
    }

    private func publish() {
        guard let s = state else { return }
        ActivityCenter.shared.upsert(IslandActivity(id: "stopwatch", kind: .stopwatch, content: .stopwatch(s), priority: 88))
    }
}
