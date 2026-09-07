import XCTest
@testable import MacNotchIsland

/// Every number the Stats tab shows is derived by one of these helpers, so they can be
/// checked without touching Mach, getifaddrs or the IORegistry.
final class SystemStatsTests: XCTestCase {
    // MARK: - cpuPercent

    func testCPUPercentIsTheBusyShareOfTheTickDelta() {
        let value = SystemStats.cpuPercent(previous: (busy: 100, total: 200), current: (busy: 200, total: 400))
        XCTAssertEqual(value, 50, accuracy: 0.0001)
    }

    func testCPUPercentFullyBusyAndFullyIdle() {
        XCTAssertEqual(SystemStats.cpuPercent(previous: (busy: 0, total: 0), current: (busy: 100, total: 100)), 100, accuracy: 0.0001)
        XCTAssertEqual(SystemStats.cpuPercent(previous: (busy: 500, total: 1000), current: (busy: 500, total: 1500)), 0, accuracy: 0.0001)
    }

    func testCPUPercentUsesOnlyTheDeltaNotTheAbsoluteTotals() {
        // A machine that has been up for weeks has huge absolute counters; only the
        // movement between two readings matters.
        let value = SystemStats.cpuPercent(previous: (busy: 9_000_000, total: 40_000_000),
                                           current: (busy: 9_000_025, total: 40_000_100))
        XCTAssertEqual(value, 25, accuracy: 0.0001)
    }

    func testCPUPercentIsZeroWhenTheCountersDoNotMove() {
        XCTAssertEqual(SystemStats.cpuPercent(previous: (busy: 10, total: 20), current: (busy: 10, total: 20)), 0)
    }

    func testCPUPercentIsZeroWhenTheCountersGoBackwards() {
        // Sleep/wake or a fresh baseline can hand us a smaller reading than the last one.
        XCTAssertEqual(SystemStats.cpuPercent(previous: (busy: 100, total: 200), current: (busy: 50, total: 100)), 0)
        XCTAssertEqual(SystemStats.cpuPercent(previous: (busy: 100, total: 200), current: (busy: 50, total: 400)), 0)
    }

    func testCPUPercentClampsToOneHundred() {
        // Nonsense input (busy moving faster than total) must never paint a >100% bar.
        let value = SystemStats.cpuPercent(previous: (busy: 0, total: 0), current: (busy: 300, total: 100))
        XCTAssertEqual(value, 100, accuracy: 0.0001)
    }

    // MARK: - rate

    func testRateIsBytesPerSecond() {
        XCTAssertEqual(SystemStats.rate(bytesNow: 3000, bytesBefore: 1000, elapsed: 2), 1000, accuracy: 0.0001)
        XCTAssertEqual(SystemStats.rate(bytesNow: 1_500_000, bytesBefore: 0, elapsed: 0.5), 3_000_000, accuracy: 0.0001)
    }

    func testRateIsZeroWithoutAWindow() {
        XCTAssertEqual(SystemStats.rate(bytesNow: 3000, bytesBefore: 1000, elapsed: 0), 0)
        XCTAssertEqual(SystemStats.rate(bytesNow: 3000, bytesBefore: 1000, elapsed: -2), 0)
    }

    func testRateIsZeroWhenTheInterfaceCounterWraps() {
        // if_data's byte counters are 32-bit and do wrap on a long-lived interface.
        XCTAssertEqual(SystemStats.rate(bytesNow: 10, bytesBefore: 4_294_967_000, elapsed: 2), 0)
    }

    func testRateOfNoTrafficIsZero() {
        XCTAssertEqual(SystemStats.rate(bytesNow: 4096, bytesBefore: 4096, elapsed: 2), 0)
    }

    // MARK: - healthPercent

    func testHealthPercentIsMaxOverDesign() {
        XCTAssertEqual(SystemStats.healthPercent(max: 4000, design: 5000) ?? -1, 80, accuracy: 0.0001)
        XCTAssertEqual(SystemStats.healthPercent(max: 4510, design: 4510) ?? -1, 100, accuracy: 0.0001)
    }

    func testHealthPercentCanExceedOneHundredOnAFreshBattery() {
        XCTAssertEqual(SystemStats.healthPercent(max: 5100, design: 5000) ?? -1, 102, accuracy: 0.0001)
    }

    func testHealthPercentIsNilWithoutBothCapacities() {
        // Desktops have no AppleSmartBattery node, and some batteries answer with zeros.
        XCTAssertNil(SystemStats.healthPercent(max: 0, design: 5000))
        XCTAssertNil(SystemStats.healthPercent(max: 4000, design: 0))
        XCTAssertNil(SystemStats.healthPercent(max: -1, design: 5000))
        XCTAssertNil(SystemStats.healthPercent(max: .nan, design: 5000))
    }

    // MARK: - celsius

    func testCelsiusFromRawTemperature() {
        XCTAssertEqual(SystemStats.celsius(fromRawTemperature: 30415) ?? -999, 31, accuracy: 0.0001)
        XCTAssertEqual(SystemStats.celsius(fromRawTemperature: 27315) ?? -999, 0, accuracy: 0.0001)
        XCTAssertEqual(SystemStats.celsius(fromRawTemperature: 30000) ?? -999, 26.85, accuracy: 0.0001)
        // Apple silicon publishes hundredths of a degree Celsius.
        XCTAssertEqual(SystemStats.celsius(fromRawTemperature: 3062) ?? -999, 30.62, accuracy: 0.0001)
    }

    func testCelsiusIsNilWhenTheBatteryReportsNothing() {
        XCTAssertNil(SystemStats.celsius(fromRawTemperature: 0))
        XCTAssertNil(SystemStats.celsius(fromRawTemperature: -100))
    }

    // MARK: - rateText

    func testRateTextIsPerSecond() {
        XCTAssertTrue(SystemStats.rateText(0).hasSuffix("/s"))
        XCTAssertTrue(SystemStats.rateText(1_500_000).hasSuffix("/s"))
        XCTAssertFalse(SystemStats.rateText(1_500_000).isEmpty)
    }

    func testRateTextScalesWithTheNumber() {
        // A megabyte a second must not read the same as a kilobyte a second.
        XCTAssertNotEqual(SystemStats.rateText(1_500_000), SystemStats.rateText(1_500))
        XCTAssertNotEqual(SystemStats.rateText(1_500_000_000), SystemStats.rateText(1_500_000))
    }

    func testRateTextTreatsRubbishAsIdle() {
        let idle = SystemStats.rateText(0)
        XCTAssertEqual(SystemStats.rateText(-1_000), idle)
        XCTAssertEqual(SystemStats.rateText(.nan), idle)
        XCTAssertEqual(SystemStats.rateText(.infinity), idle)
    }

    // MARK: - memoryText

    func testMemoryTextPairsUsedAndTotal() {
        let text = SystemStats.memoryText(used: 12_400_000_000, total: 17_179_869_184)
        XCTAssertEqual(text.components(separatedBy: "/").count, 2, "exactly one separator: \(text)")
        XCTAssertTrue(text.contains(" / "), text)
        XCTAssertFalse(text.hasSuffix(" / "), text)
    }

    func testMemoryTextHandlesZeroes() {
        XCTAssertTrue(SystemStats.memoryText(used: 0, total: 0).contains("/"))
    }

    // MARK: - Sampling lifecycle

    func testStartAndStopAreReferenceCounted() {
        let stats = SystemStats.shared
        XCTAssertFalse(stats.isRunning, "nothing should be sampling before a view asks")

        stats.start()
        XCTAssertTrue(stats.isRunning)
        stats.start()
        XCTAssertTrue(stats.isRunning)

        stats.stop()
        XCTAssertTrue(stats.isRunning, "one caller is still on screen")
        stats.stop()
        XCTAssertFalse(stats.isRunning, "the last caller went away, so sampling stops")

        // An unbalanced extra stop must not push the count negative and wedge start().
        stats.stop()
        XCTAssertFalse(stats.isRunning)
        stats.start()
        XCTAssertTrue(stats.isRunning)
        stats.stop()
        XCTAssertFalse(stats.isRunning)
    }

    func testHistoryLengthIsBounded() {
        XCTAssertEqual(SystemStats.historyLength, 40)
        XCTAssertTrue(SystemStats.shared.cpuHistory.count <= SystemStats.historyLength)
    }
}
