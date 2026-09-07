import XCTest
@testable import MacNotchIsland

/// Exercises EnergyPolicy's pure decision rules directly, without touching NSWorkspace,
/// IOKit, or Preferences — the instance properties are thin wrappers over these.
final class EnergyPolicyTests: XCTestCase {
    // MARK: animationsPaused

    func testAnimationsPausedWhenAsleep() {
        XCTAssertTrue(EnergyPolicy.animationsPaused(asleep: true, lowPower: false, onBattery: false, pauseOnBattery: false))
    }

    func testAnimationsPausedWhenLowPower() {
        XCTAssertTrue(EnergyPolicy.animationsPaused(asleep: false, lowPower: true, onBattery: false, pauseOnBattery: false))
    }

    func testAnimationsPausedOnBatteryOnlyWhenPreferenceIsOn() {
        XCTAssertTrue(EnergyPolicy.animationsPaused(asleep: false, lowPower: false, onBattery: true, pauseOnBattery: true))
        XCTAssertFalse(EnergyPolicy.animationsPaused(asleep: false, lowPower: false, onBattery: true, pauseOnBattery: false))
    }

    func testAnimationsNotPausedWhenNoneApply() {
        XCTAssertFalse(EnergyPolicy.animationsPaused(asleep: false, lowPower: false, onBattery: false, pauseOnBattery: true))
    }

    // MARK: animationInterval

    func testAnimationIntervalIsOneSecondWhenPaused() {
        XCTAssertEqual(EnergyPolicy.animationInterval(asleep: true, lowPower: false, onBattery: false, pauseOnBattery: false), 1)
        XCTAssertEqual(EnergyPolicy.animationInterval(asleep: false, lowPower: true, onBattery: false, pauseOnBattery: false), 1)
        XCTAssertEqual(EnergyPolicy.animationInterval(asleep: false, lowPower: false, onBattery: true, pauseOnBattery: true), 1)
    }

    func testAnimationIntervalSlowerOnBatteryWhenRunning() {
        let onBattery = EnergyPolicy.animationInterval(asleep: false, lowPower: false, onBattery: true, pauseOnBattery: false)
        let onPower = EnergyPolicy.animationInterval(asleep: false, lowPower: false, onBattery: false, pauseOnBattery: false)
        XCTAssertEqual(onBattery, 1.0 / 20.0, accuracy: 0.0001)
        XCTAssertEqual(onPower, 1.0 / 30.0, accuracy: 0.0001)
        XCTAssertGreaterThan(onBattery, onPower, "battery should animate no faster than on power")
    }

    // MARK: pollingMultiplier

    func testPollingMultiplierPrefersAsleepOverEverythingElse() {
        XCTAssertEqual(EnergyPolicy.pollingMultiplier(asleep: true, lowPower: true, onBattery: true), 8)
        XCTAssertEqual(EnergyPolicy.pollingMultiplier(asleep: true, lowPower: false, onBattery: false), 8)
    }

    func testPollingMultiplierLowPowerBeatsBatteryAlone() {
        XCTAssertEqual(EnergyPolicy.pollingMultiplier(asleep: false, lowPower: true, onBattery: true), 4)
        XCTAssertEqual(EnergyPolicy.pollingMultiplier(asleep: false, lowPower: true, onBattery: false), 4)
    }

    func testPollingMultiplierOnBatteryOnly() {
        XCTAssertEqual(EnergyPolicy.pollingMultiplier(asleep: false, lowPower: false, onBattery: true), 2)
    }

    func testPollingMultiplierBaselineIsOne() {
        XCTAssertEqual(EnergyPolicy.pollingMultiplier(asleep: false, lowPower: false, onBattery: false), 1)
    }

    func testPollingMultiplierOrdering() {
        // Each state should never be a *lower* multiplier than the calmer state below it —
        // this is the invariant every caller (DownloadMonitor, CameraMonitor, CapsLockMonitor)
        // relies on when multiplying its base interval.
        let awake = EnergyPolicy.pollingMultiplier(asleep: false, lowPower: false, onBattery: false)
        let battery = EnergyPolicy.pollingMultiplier(asleep: false, lowPower: false, onBattery: true)
        let lowPower = EnergyPolicy.pollingMultiplier(asleep: false, lowPower: true, onBattery: true)
        let asleep = EnergyPolicy.pollingMultiplier(asleep: true, lowPower: true, onBattery: true)
        XCTAssertLessThanOrEqual(awake, battery)
        XCTAssertLessThanOrEqual(battery, lowPower)
        XCTAssertLessThanOrEqual(lowPower, asleep)
    }

    // MARK: shared instance sanity

    func testSharedInstanceDefaultsMatchPureRulesAtRest() {
        // Freshly constructed / never-started, EnergyPolicy.shared reports all-clear flags, so
        // its computed properties should agree with the pure rules given those same flags.
        let policy = EnergyPolicy.shared
        let pauseOnBattery = Preferences.shared.pauseAnimationsOnBattery
        XCTAssertEqual(policy.animationsPaused,
                       EnergyPolicy.animationsPaused(asleep: policy.isAsleep, lowPower: policy.isLowPower,
                                                      onBattery: policy.isOnBattery, pauseOnBattery: pauseOnBattery,
                                                    reduceMotion: IslandMotion.reduceMotion))
        XCTAssertEqual(policy.animationInterval,
                       EnergyPolicy.animationInterval(asleep: policy.isAsleep, lowPower: policy.isLowPower,
                                                       onBattery: policy.isOnBattery, pauseOnBattery: pauseOnBattery))
        XCTAssertEqual(policy.pollingMultiplier,
                       EnergyPolicy.pollingMultiplier(asleep: policy.isAsleep, lowPower: policy.isLowPower,
                                                       onBattery: policy.isOnBattery))
    }
}
