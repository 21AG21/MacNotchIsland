import Foundation
import Combine

/// Stopwatch Live Activity (added to the iPhone's island in iOS 17).
final class IslandStopwatch: ObservableObject {
    static let shared = IslandStopwatch()

    @Published private(set) var state: StopwatchState?

    private init() {}

    func start() {
        if var s = state {
            guard !s.isRunning else { return }
            s.startedAt = Date()
            s.isRunning = true
            state = s
        } else {
            state = StopwatchState(startedAt: Date())
        }
        publish()
    }

    func stop() {
        guard var s = state, s.isRunning else { return }
        s.accumulated = s.elapsed(at: Date())
        s.isRunning = false
        state = s
        publish()
    }

    func lap() {
        guard var s = state, s.isRunning else { return }
        s.laps.append(s.elapsed(at: Date()))
        state = s
        publish()
    }

    func reset() {
        state = nil
        ActivityCenter.shared.end(id: "stopwatch")
    }

    private func publish() {
        guard let s = state else { return }
        ActivityCenter.shared.upsert(IslandActivity(id: "stopwatch", kind: .stopwatch, content: .stopwatch(s), priority: 88))
    }
}
