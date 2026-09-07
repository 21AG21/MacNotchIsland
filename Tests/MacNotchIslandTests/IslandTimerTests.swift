import XCTest
@testable import MacNotchIsland

final class IslandTimerTests: XCTestCase {
    private var center: ActivityCenter { ActivityCenter.shared }
    private var timer: IslandTimer { IslandTimer.shared }
    private let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                                         notchWidth: 200, notchHeight: 32, hasPhysicalNotch: true)

    override func setUp() {
        super.setUp()
        timer.cancelAll()
        center.resetForTesting()
    }

    override func tearDown() {
        timer.cancelAll()
        center.resetForTesting()
        super.tearDown()
    }

    // MARK: - Several timers at once

    func testTwoTimersAreTwoLiveActivitiesWithDistinctIDs() {
        timer.start(seconds: 600, label: "Laundry")
        timer.start(seconds: 300, label: "Tea")

        XCTAssertEqual(timer.timers.count, 2)
        let ids = timer.timers.map { $0.id }
        XCTAssertEqual(Set(ids).count, 2, "each timer needs its own live activity id")
        for id in ids { XCTAssertNotNil(center.activity(id: id), "missing activity for \(id)") }
        XCTAssertEqual(center.activities.filter { $0.kind == .timer }.count, 2)

        // The soonest to finish owns the island; the other one becomes the bubble.
        guard case .compact(let primary, let bubble) = center.presentation else { return XCTFail("expected compact") }
        XCTAssertEqual(primary.id, timer.primary?.id)
        XCTAssertEqual(bubble?.id, ids.first { $0 != timer.primary?.id })
        guard case .timer(let shown) = primary.content else { return XCTFail("expected a timer") }
        XCTAssertEqual(shown.label, "Tea")
    }

    func testPrimaryIsTheTimerFinishingSoonest() {
        timer.start(seconds: 600, label: "Laundry")
        XCTAssertEqual(timer.state?.label, "Laundry")
        timer.start(seconds: 300, label: "Tea")
        XCTAssertEqual(timer.state?.label, "Tea", "the closer deadline takes the island")
        timer.start(seconds: 1800, label: "Roast")
        XCTAssertEqual(timer.state?.label, "Tea")
        XCTAssertEqual(timer.primary?.priority, 91)
        XCTAssertEqual(Set(timer.secondaryTimers.map { $0.label }), ["Laundry", "Roast"])
        XCTAssertEqual(timer.secondaryTimers.first?.label, "Roast", "the other timers stack most recent first")
    }

    func testNoArgumentControlsActOnThePrimaryTimerOnly() {
        timer.start(seconds: 600, label: "Laundry")
        let laundry = timer.timers[0].id
        timer.start(seconds: 300, label: "Tea")

        timer.pause()
        XCTAssertTrue(timer.state?.isPaused ?? false)
        XCTAssertEqual(timer.state?.label, "Tea")
        XCTAssertFalse(timer.entry(id: laundry)?.state.isPaused ?? true, "the other timer keeps running")

        timer.resume()
        XCTAssertFalse(timer.state?.isPaused ?? true)

        timer.cancel()
        XCTAssertEqual(timer.timers.count, 1)
        XCTAssertEqual(timer.state?.label, "Laundry", "the island falls back to the remaining timer")
    }

    func testCancelByIDRemovesOnlyThatTimer() {
        timer.start(seconds: 600, label: "Laundry")
        let laundry = timer.timers[0].id
        timer.start(seconds: 300, label: "Tea")
        let tea = timer.timers[1].id

        timer.cancel(id: laundry)
        XCTAssertEqual(timer.timers.map { $0.id }, [tea])
        XCTAssertNil(center.activity(id: laundry))
        XCTAssertNotNil(center.activity(id: tea))
        XCTAssertEqual(timer.state?.label, "Tea")

        timer.cancel(id: tea)
        XCTAssertTrue(timer.timers.isEmpty)
        XCTAssertNil(timer.state)
        XCTAssertTrue(center.activities.isEmpty)
    }

    func testTimerCountIsCapped() {
        for i in 1...(IslandTimer.maxTimers + 2) { timer.start(seconds: TimeInterval(i * 60), label: "T\(i)") }
        XCTAssertEqual(timer.timers.count, IslandTimer.maxTimers)
        XCTAssertEqual(center.activities.filter { $0.kind == .timer }.count, IslandTimer.maxTimers)
    }

    func testRepeatLastStartsAnotherTimer() {
        timer.start(seconds: 300, label: "Tea")
        timer.repeatLast()
        XCTAssertEqual(timer.timers.count, 2)
        XCTAssertEqual(timer.timers.map { $0.label }, ["Tea", "Tea"])
    }

    func testExpandedHeightGrowsPerExtraTimerUpToTwoRows() {
        let content = ActivityContent.timer(TimerState(label: "Tea", total: 60, endDate: Date()))
        let base = content.expandedSize(notch: geometry).height
        timer.start(seconds: 300, label: "One")
        XCTAssertEqual(content.expandedSize(notch: geometry).height, base, "a single timer needs no extra row")
        timer.start(seconds: 300, label: "Two")
        XCTAssertEqual(content.expandedSize(notch: geometry).height, base + IslandTimer.rowHeight)
        timer.start(seconds: 300, label: "Three")
        XCTAssertEqual(content.expandedSize(notch: geometry).height, base + IslandTimer.rowHeight * 2)
        timer.start(seconds: 300, label: "Four")
        XCTAssertEqual(content.expandedSize(notch: geometry).height, base + IslandTimer.rowHeight * 2,
                       "the list never grows past two extra rows")
    }

    // MARK: - Pomodoro

    func testPomodoroPhaseSequence() {
        let first = PomodoroPhase(kind: .focus, cycle: 1, cycles: 2, work: 1500, rest: 300)
        XCTAssertEqual(first.label, "Focus 1/2")
        XCTAssertEqual(first.duration, 1500)

        guard let second = IslandTimer.nextPhase(after: first) else { return XCTFail("expected a break") }
        XCTAssertEqual(second.kind, .rest)
        XCTAssertEqual(second.label, "Break 1/2")
        XCTAssertEqual(second.duration, 300)

        guard let third = IslandTimer.nextPhase(after: second) else { return XCTFail("expected the next session") }
        XCTAssertEqual(third.kind, .focus)
        XCTAssertEqual(third.label, "Focus 2/2")

        guard let fourth = IslandTimer.nextPhase(after: third) else { return XCTFail("expected the last break") }
        XCTAssertEqual(fourth.label, "Break 2/2")
        XCTAssertNil(IslandTimer.nextPhase(after: fourth), "the run ends after the last break")
    }

    func testEveryFourthSessionGetsTheLongBreak() {
        var phase = PomodoroPhase(kind: .focus, cycle: 1, cycles: 4, work: 1500, rest: 300,
                                  longRest: 900, longBreakEvery: 4)
        var labels: [String] = [phase.label]
        while let next = IslandTimer.nextPhase(after: phase) {
            phase = next
            labels.append(phase.label)
        }
        XCTAssertEqual(labels, ["Focus 1/4", "Break 1/4", "Focus 2/4", "Break 2/4",
                                "Focus 3/4", "Break 3/4", "Focus 4/4", "Long break 4/4"])
        XCTAssertEqual(phase.kind, .longRest)
        XCTAssertEqual(phase.duration, 900)
    }

    func testStartPomodoroRunsOneTimerAndCancelStopsTheRun() {
        timer.startPomodoro(work: 60, rest: 30, cycles: 3, longRest: 90)
        XCTAssertEqual(timer.timers.count, 1, "a Pomodoro is one timer whose label changes")
        XCTAssertEqual(timer.state?.label, "Focus 1/3")
        XCTAssertEqual(timer.state?.total, 60)
        XCTAssertEqual(timer.pomodoro?.cycle, 1)
        XCTAssertEqual(timer.pomodoro?.cycles, 3)
        XCTAssertTrue(timer.isPomodoroRunning)
        XCTAssertEqual(timer.pomodoroTimerID, timer.primary?.id)
        XCTAssertNotNil(center.activity(id: timer.primary?.id ?? ""))

        timer.cancel()
        XCTAssertNil(timer.pomodoro, "cancel stops the whole Pomodoro, not just the phase")
        XCTAssertNil(timer.pomodoroTimerID)
        XCTAssertTrue(timer.timers.isEmpty)
    }

    func testRestartingAPomodoroReplacesTheRunningOne() {
        timer.startPomodoro(work: 60, rest: 30, cycles: 4)
        timer.startPomodoro(work: 120, rest: 30, cycles: 2)
        XCTAssertEqual(timer.timers.count, 1)
        XCTAssertEqual(timer.state?.label, "Focus 1/2")
        XCTAssertEqual(timer.state?.total, 120)
    }
}
