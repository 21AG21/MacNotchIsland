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

    func testHealthPercentIsHeldToOneHundredOnAFreshBattery() {
        // A new battery can hold a little more than its design figure; the Stats cell says 100,
        // as the battery card does (`BatteryMonitor.healthPercent`), not 102.
        XCTAssertEqual(SystemStats.healthPercent(max: 5100, design: 5000) ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(SystemStats.healthPercent(max: 5100, design: 5000).map { Int($0.rounded()) },
                       BatteryMonitor.healthPercent(maxCapacity: 5100, designCapacity: 5000))
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

    // MARK: - What the Stats cells say

    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    private func laptop(percent: Int = 82, minutes: Int? = 220, charging: Bool = false,
                        health: Double? = 91.4, cycles: Int? = 214) -> SystemStats.Sample {
        var sample = SystemStats.Sample()
        sample.batteryPercent = percent
        sample.batteryMinutesRemaining = minutes
        sample.batteryCharging = charging
        sample.batteryHealthPercent = health
        sample.cycleCount = cycles
        return sample
    }

    /// The line under the battery's meter had "1 cycles" on a battery a day old; the card
    /// beside it already said "1 cycle", and the two now share the rule.
    func testTheBatteryDetailSaysOneCycle() {
        XCTAssertEqual(StatsView.batteryDetail(laptop()), "91% health · 214 cycles")
        XCTAssertEqual(StatsView.batteryDetail(laptop(cycles: 1)), "91% health · 1 cycle")
        XCTAssertEqual(StatsView.batteryDetail(laptop(health: nil, cycles: 1)), "1 cycle")
        XCTAssertNil(StatsView.batteryDetail(laptop(health: nil, cycles: nil)))
    }

    func testTheBatteryTimeIsTheClippedLineUnderTheMeter() {
        XCTAssertEqual(StatsView.batteryTime(laptop()), "3 h 40 min left")
        XCTAssertEqual(StatsView.batteryTime(laptop(minutes: 48, charging: true)), "48 min to full")
        XCTAssertEqual(StatsView.batteryTime(laptop(minutes: nil, charging: true)), "Charging")
        XCTAssertNil(StatsView.batteryTime(laptop(minutes: nil)))
        XCTAssertNil(StatsView.batteryTime(SystemStats.Sample()), "a desktop has no battery to time")
    }

    /// VoiceOver was handed the two clipped lines as they are drawn, and read "3 h 40 min"
    /// letter by letter and the "·" between health and cycles as a symbol.
    func testTheBatteryCellIsSpokenInWords() {
        XCTAssertEqual(StatsView.batterySpoken(laptop()),
                       "82 percent, 3 hours 40 minutes left, 91 percent health, 214 cycles")
        XCTAssertEqual(StatsView.batterySpoken(laptop(minutes: 1, charging: true, cycles: 1)),
                       "82 percent, 1 minute to full, 91 percent health, 1 cycle")
        XCTAssertEqual(StatsView.batterySpoken(laptop(minutes: nil, charging: true, health: nil, cycles: nil)),
                       "82 percent, charging")
        XCTAssertEqual(StatsView.batterySpoken(SystemStats.Sample()), "Not available")
        for spoken in [StatsView.batterySpoken(laptop()), StatsView.batterySpoken(laptop(charging: true))] {
            XCTAssertFalse(spoken.contains("·"), spoken)
            XCTAssertFalse(spoken.contains("%"), spoken)
            XCTAssertFalse(spoken.contains(" h "), spoken)
            XCTAssertFalse(spoken.contains(" min"), spoken)
        }
    }

    /// "52%, 12.4 / 16 GB" was read "12.4 slash 16"; the memory is said as a share and then as
    /// so many of so many gigabytes, with the region's decimal mark like the figure on screen.
    func testTheMemoryCellIsSpokenInWords() {
        var sample = SystemStats.Sample()
        sample.memoryUsedBytes = 13_314_398_618
        sample.memoryTotalBytes = 17_179_869_184
        XCTAssertEqual(StatsView.memorySpoken(sample, locale: english), "78 percent, 12.4 of 16 gigabytes")
        XCTAssertEqual(StatsView.memorySpoken(sample, locale: german), "78 percent, 12,4 of 16 gigabytes")
        XCTAssertFalse(StatsView.memorySpoken(sample, locale: english).contains("/"))
        XCTAssertEqual(SystemStats.spokenMemory(used: 8_589_934_592, total: 17_179_869_184, locale: english),
                       "8 of 16 gigabytes")

        sample.memoryUsedBytes = 20_000_000_000
        XCTAssertTrue(StatsView.memorySpoken(sample, locale: english).hasPrefix("100 percent"),
                      "never more than all of it, as the bar is never more than full")
        XCTAssertEqual(StatsView.memorySpoken(SystemStats.Sample(), locale: english), "Not available")
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

    // MARK: - StatsDestination

    /// The app is compared as a URL rather than as a string: a bundle is a directory, and a
    /// file URL to one can carry a trailing slash that the path it was built from never had.
    private let activityMonitor = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")

    func testEveryReadingIsADoorToWhereMacOSKeepsIt() {
        // Exhaustive on purpose: a cell added to the section without somewhere to send people
        // fails to compile here rather than quietly going back to being a decoration.
        for destination in StatsDestination.allCases {
            switch destination {
            case .cpu, .memory:
                XCTAssertEqual(destination.url, activityMonitor)
                XCTAssertEqual(destination.placeName, "Activity Monitor")
            case .disk:
                XCTAssertEqual(destination.url?.absoluteString, "x-apple.systempreferences:com.apple.settings.Storage")
                XCTAssertEqual(destination.placeName, "Storage settings")
            case .network:
                XCTAssertEqual(destination.url?.absoluteString, "x-apple.systempreferences:com.apple.Network-Settings.extension")
                XCTAssertEqual(destination.placeName, "Network settings")
            case .battery:
                XCTAssertEqual(destination.url?.absoluteString, "x-apple.systempreferences:com.apple.Battery-Settings.extension")
                XCTAssertEqual(destination.placeName, "Battery settings")
            }
        }
        XCTAssertEqual(StatsDestination.allCases.count, 5, "five readings in the row, five doors")
    }

    func testTheProcessorAndTheMemoryOpenTheOneWindow() {
        // They are two columns of Activity Monitor, not two different places.
        XCTAssertEqual(StatsDestination.cpu.url, StatsDestination.memory.url)
        XCTAssertEqual(StatsDestination.cpu.url?.isFileURL, true, "an app is opened by its path, not by a scheme")
    }

    func testASettingsPaneIsAskedForByItsExactExtension() {
        // System Settings finds nothing at all if the extension's identifier is off by a
        // character, so these strings are the test.
        for destination in [StatsDestination.disk, .network, .battery] {
            let link = destination.url?.absoluteString ?? ""
            XCTAssertTrue(link.hasPrefix("x-apple.systempreferences:"), link)
            XCTAssertFalse(link.hasSuffix(":"), "a scheme with nothing after it opens the last pane you looked at")
        }
    }

    func testAReadingWithNowhereToGoNamesNoPlace() {
        // The two halves have to agree: a place with no link would put a dead button on
        // screen, and a link with no name would leave its tooltip with nothing to say.
        for destination in StatsDestination.allCases {
            XCTAssertEqual(destination.url == nil, destination.placeName == nil,
                           "\(destination) only half-answers where it goes")
            XCTAssertNotEqual(destination.placeName, "", "a named place is named something")
        }
    }
}
