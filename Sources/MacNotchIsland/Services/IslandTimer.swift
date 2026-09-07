import AppKit
import Combine

/// The island's own countdown timer, presented like the Clock app's Live Activity.
final class IslandTimer: ObservableObject {
    static let shared = IslandTimer()

    @Published private(set) var state: TimerState?
    private var ticker: Timer?
    private var lastDuration: TimeInterval = 300
    private var lastLabel = "Timer"

    private init() {}

    func start(seconds: TimeInterval, label: String = "Timer") {
        guard seconds > 0 else { return }
        lastDuration = seconds
        lastLabel = label
        state = TimerState(label: label, total: seconds, endDate: Date().addingTimeInterval(seconds))
        ActivityCenter.shared.dismissAlert()
        publish()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        Haptics.tap()
    }

    func pause() {
        guard var s = state, !s.isFinished, !s.isPaused else { return }
        s.pausedRemaining = s.remaining(at: Date())
        state = s
        publish()
        // Nothing changes while paused; stop ticking rather than waking up every 0.5s to
        // compare a remaining time that never moves.
        ticker?.invalidate()
        ticker = nil
    }

    func resume() {
        guard var s = state, let remaining = s.pausedRemaining else { return }
        s.endDate = Date().addingTimeInterval(remaining)
        s.pausedRemaining = nil
        state = s
        publish()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        state = nil
        ActivityCenter.shared.end(id: "timer")
    }

    func repeatLast() {
        start(seconds: lastDuration, label: lastLabel)
    }

    private func tick() {
        guard var s = state, !s.isFinished else { return }
        if s.remaining(at: Date()) <= 0 {
            s.isFinished = true
            state = s
            publish()
            finish()
        }
    }

    private func finish() {
        if Preferences.shared.timerSoundEnabled {
            NSSound(named: "Glass")?.play()
        }
        ActivityCenter.shared.forceExpanded(id: "timer", for: 8)
        // Auto-clear a finished timer after a minute if nobody stops it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            if let s = self?.state, s.isFinished { self?.cancel() }
        }
    }

    private func publish() {
        guard let s = state else { return }
        ActivityCenter.shared.upsert(IslandActivity(id: "timer", kind: .timer, content: .timer(s), priority: 90))
    }
}
