import XCTest
@testable import MacNotchIsland

/// Every extra figure on the battery panel comes through one of these helpers, so they can be
/// checked without a battery, IOKit or the IORegistry.
final class BatteryDetailTests: XCTestCase {
    // MARK: - BatteryMonitor decoding

    func testMinutesFromSecondsMapsSentinelsToNil() {
        XCTAssertNil(BatteryMonitor.minutes(fromSeconds: -1), "kIOPSTimeRemainingUnknown")
        XCTAssertNil(BatteryMonitor.minutes(fromSeconds: -2), "kIOPSTimeRemainingUnlimited")
        XCTAssertNil(BatteryMonitor.minutes(fromSeconds: .nan))
        XCTAssertNil(BatteryMonitor.minutes(fromSeconds: .infinity))
        XCTAssertEqual(BatteryMonitor.minutes(fromSeconds: 8040), 134)
        XCTAssertEqual(BatteryMonitor.minutes(fromSeconds: 30), 0)
        XCTAssertEqual(BatteryMonitor.minutes(fromSeconds: 0), 0)
    }

    func testKnownMinutesRejectsUnknownAndNonNumbers() {
        XCTAssertEqual(BatteryMonitor.knownMinutes(65), 65)
        XCTAssertEqual(BatteryMonitor.knownMinutes(0), 0)
        XCTAssertNil(BatteryMonitor.knownMinutes(-1))
        XCTAssertNil(BatteryMonitor.knownMinutes(nil))
        XCTAssertNil(BatteryMonitor.knownMinutes("65"))
    }

    func testSignedAmperageDecodesWrappedNegatives() {
        XCTAssertEqual(BatteryMonitor.signedAmperage(4_294_966_000), -1296)
        XCTAssertEqual(BatteryMonitor.signedAmperage(0xFFFF_FFFF), -1)
        XCTAssertEqual(BatteryMonitor.signedAmperage(0x7FFF_FFFF), 0x7FFF_FFFF)
        XCTAssertEqual(BatteryMonitor.signedAmperage(1_250), 1_250)
        XCTAssertEqual(BatteryMonitor.signedAmperage(0), 0)
        XCTAssertEqual(BatteryMonitor.signedAmperage(-1296), -1296, "already signed values pass through")
    }

    func testWattageSignFollowsAmperage() {
        XCTAssertEqual(BatteryMonitor.wattage(amperageMilliamps: 2_700, voltageMillivolts: 12_600), 34.02, accuracy: 0.0001)
        XCTAssertEqual(BatteryMonitor.wattage(amperageMilliamps: -1_296, voltageMillivolts: 12_600), -16.3296, accuracy: 0.0001)
        XCTAssertEqual(BatteryMonitor.wattage(amperageMilliamps: 0, voltageMillivolts: 12_600), 0)
    }

    func testHealthPercentClampsAndNeedsADesignFigure() {
        XCTAssertEqual(BatteryMonitor.healthPercent(maxCapacity: 4_550, designCapacity: 5_000), 91)
        XCTAssertEqual(BatteryMonitor.healthPercent(maxCapacity: 5_000, designCapacity: 5_000), 100)
        XCTAssertEqual(BatteryMonitor.healthPercent(maxCapacity: 5_200, designCapacity: 5_000), 100, "clamped high")
        XCTAssertEqual(BatteryMonitor.healthPercent(maxCapacity: -10, designCapacity: 5_000), 0, "clamped low")
        XCTAssertNil(BatteryMonitor.healthPercent(maxCapacity: 4_550, designCapacity: 0))
        XCTAssertNil(BatteryMonitor.healthPercent(maxCapacity: 4_550, designCapacity: -5))
    }

    func testTemperatureHandlesBothScales() {
        XCTAssertEqual(BatteryMonitor.celsius(fromRawTemperature: 3012) ?? -1, 30.12, accuracy: 0.001)
        XCTAssertEqual(BatteryMonitor.celsius(fromRawTemperature: 30_327) ?? -1, 30.12, accuracy: 0.001, "hundredths of a kelvin")
        XCTAssertNil(BatteryMonitor.celsius(fromRawTemperature: 0))
        XCTAssertNil(BatteryMonitor.celsius(fromRawTemperature: -5))
    }

    func testInfoFromRegistryProperties() {
        let properties: [String: Any] = [
            "CycleCount": 312,
            "AppleRawMaxCapacity": 4_550,
            "MaxCapacity": 100,
            "DesignCapacity": 5_000,
            "Temperature": 3012,
            "Amperage": 4_294_966_000,
            "Voltage": 12_600,
        ]
        let info = BatteryMonitor.info(from: properties)
        XCTAssertEqual(info.cycleCount, 312)
        XCTAssertEqual(info.healthPercent, 91, "the raw mAh figure wins over the bare percentage")
        XCTAssertEqual(info.temperatureCelsius ?? -1, 30.12, accuracy: 0.001)
        XCTAssertEqual(info.wattage ?? 0, -16.3296, accuracy: 0.0001, "wrapped amperage decodes to a discharge")
    }

    func testInfoDropsWhatTheBatteryDidNotReport() {
        let empty = BatteryMonitor.info(from: [:])
        XCTAssertNil(empty.cycleCount)
        XCTAssertNil(empty.healthPercent)
        XCTAssertNil(empty.temperatureCelsius)
        XCTAssertNil(empty.wattage)

        let percentOnly = BatteryMonitor.info(from: ["MaxCapacity": 100, "DesignCapacity": 5_000])
        XCTAssertNil(percentOnly.healthPercent, "a 2% ratio means MaxCapacity was a percentage, not mAh")

        let fallback = BatteryMonitor.info(from: ["MaxCapacity": 4_550, "DesignCapacity": 5_000])
        XCTAssertEqual(fallback.healthPercent, 91)

        let noVoltage = BatteryMonitor.info(from: ["Amperage": 1_000])
        XCTAssertNil(noVoltage.wattage)
    }

    // MARK: - BatteryFormatting

    func testFormatMinutes() {
        XCTAssertEqual(BatteryFormatting.formatMinutes(134), "2 h 14 min")
        XCTAssertEqual(BatteryFormatting.formatMinutes(45), "45 min")
        XCTAssertEqual(BatteryFormatting.formatMinutes(120), "2 h")
        XCTAssertEqual(BatteryFormatting.formatMinutes(1), "1 min")
        XCTAssertEqual(BatteryFormatting.formatMinutes(0), "Less than a minute")
        XCTAssertEqual(BatteryFormatting.formatMinutes(-3), "Less than a minute")
    }

    func testFormatWattageUsesATrueMinusSign() {
        XCTAssertEqual(BatteryFormatting.formatWattage(34.24), "+34.2 W")
        XCTAssertEqual(BatteryFormatting.formatWattage(-8.06), "\u{2212}8.1 W")
        XCTAssertFalse(BatteryFormatting.formatWattage(-8.06).contains("-"), "never the ASCII hyphen-minus")
        XCTAssertEqual(BatteryFormatting.formatWattage(0), "0.0 W")
        XCTAssertEqual(BatteryFormatting.formatWattage(-0.04), "0.0 W", "no signed zero")
        XCTAssertEqual(BatteryFormatting.formatWattage(.nan), "0.0 W")
    }

    func testTimeLineWording() {
        let draining = BatteryState(percent: 63, isCharging: false, isPluggedIn: false, event: .unplugged, timeRemainingMinutes: 134)
        XCTAssertEqual(BatteryFormatting.timeLine(for: draining), "2 h 14 min remaining")

        let charging = BatteryState(percent: 63, isCharging: true, isPluggedIn: true, event: .pluggedIn, timeRemainingMinutes: 65)
        XCTAssertEqual(BatteryFormatting.timeLine(for: charging), "1 h 5 min to full")

        let nearlyEmpty = BatteryState(percent: 2, isCharging: false, isPluggedIn: false, event: .critical, timeRemainingMinutes: 0)
        XCTAssertEqual(BatteryFormatting.timeLine(for: nearlyEmpty), "Less than a minute remaining")

        let charged = BatteryState(percent: 100, isCharging: false, isPluggedIn: true, event: .full, timeRemainingMinutes: 5)
        XCTAssertNil(BatteryFormatting.timeLine(for: charged), "nothing is counting down on a charged Mac on power")

        let estimating = BatteryState(percent: 63, isCharging: false, isPluggedIn: false, event: .unplugged)
        XCTAssertNil(BatteryFormatting.timeLine(for: estimating))
    }

    func testDetailLineDropsUnknowns() {
        let full = BatteryState(percent: 63, isCharging: true, isPluggedIn: true, event: .pluggedIn,
                                wattage: 34.24, cycleCount: 312, healthPercent: 91)
        XCTAssertEqual(BatteryFormatting.detailLine(for: full), "+34.2 W · 312 cycles · 91% health")

        let draining = BatteryState(percent: 18, isCharging: false, isPluggedIn: false, event: .low, wattage: -8.06)
        XCTAssertEqual(BatteryFormatting.detailLine(for: draining), "\u{2212}8.1 W")

        let idle = BatteryState(percent: 100, isCharging: false, isPluggedIn: true, event: .full, wattage: 0.01, cycleCount: 1)
        XCTAssertEqual(BatteryFormatting.detailLine(for: idle), "1 cycle", "a flow that rounds to zero is not worth a line")

        let healthOnly = BatteryState(percent: 50, isCharging: false, isPluggedIn: false, event: .unplugged, healthPercent: 88)
        XCTAssertEqual(BatteryFormatting.detailLine(for: healthOnly), "88% health")

        let bare = BatteryState(percent: 50, isCharging: false, isPluggedIn: false, event: .unplugged)
        XCTAssertNil(BatteryFormatting.detailLine(for: bare))
    }

    func testConnectToPowerOnlyForLowAlertsWithoutAnEstimate() {
        XCTAssertTrue(BatteryFormatting.showsConnectToPower(for: BatteryState(percent: 9, isCharging: false, isPluggedIn: false, event: .critical)))
        XCTAssertTrue(BatteryFormatting.showsConnectToPower(for: BatteryState(percent: 18, isCharging: false, isPluggedIn: false, event: .low)))
        XCTAssertFalse(BatteryFormatting.showsConnectToPower(for: BatteryState(percent: 9, isCharging: false, isPluggedIn: false, event: .critical,
                                                                                timeRemainingMinutes: 20)))
        XCTAssertFalse(BatteryFormatting.showsConnectToPower(for: BatteryState(percent: 50, isCharging: false, isPluggedIn: false, event: .unplugged)))
    }

    func testSpokenMinutes() {
        XCTAssertEqual(BatteryFormatting.spokenMinutes(134), "2 hours 14 minutes")
        XCTAssertEqual(BatteryFormatting.spokenMinutes(65), "1 hour 5 minutes")
        XCTAssertEqual(BatteryFormatting.spokenMinutes(60), "1 hour")
        XCTAssertEqual(BatteryFormatting.spokenMinutes(1), "1 minute")
        XCTAssertEqual(BatteryFormatting.spokenMinutes(0), "less than a minute")
    }

    func testAccessibilityLabelReadsNaturally() {
        let charging = BatteryState(percent: 63, isCharging: true, isPluggedIn: true, event: .pluggedIn,
                                    timeRemainingMinutes: 134, wattage: 34.24, cycleCount: 312, healthPercent: 91)
        XCTAssertEqual(BatteryFormatting.accessibilityLabel(for: charging),
                       "Battery 63 percent, 2 hours 14 minutes until fully charged, charging at 34 watts, 312 cycles, 91 percent health")

        let draining = BatteryState(percent: 63, isCharging: false, isPluggedIn: false, event: .unplugged,
                                    timeRemainingMinutes: 134, wattage: -8.06)
        XCTAssertEqual(BatteryFormatting.accessibilityLabel(for: draining),
                       "Battery 63 percent, 2 hours 14 minutes remaining, using 8 watts")

        let low = BatteryState(percent: 18, isCharging: false, isPluggedIn: false, event: .low, wattage: -8.06)
        XCTAssertEqual(BatteryFormatting.accessibilityLabel(for: low), "Battery 18 percent, using 8 watts, connect to power")

        let bare = BatteryState(percent: 80, isCharging: true, isPluggedIn: true, event: .pluggedIn)
        XCTAssertEqual(BatteryFormatting.accessibilityLabel(for: bare), "Battery 80 percent")
    }
}
