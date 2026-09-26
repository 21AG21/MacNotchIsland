import XCTest
@testable import MacNotchIsland

/// Memory and disk are both "GB" on the Stats section, and they are not the same gigabyte.
final class StatsUnitsTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    func testTheDiskIsCountedTheWayFinderCountsIt() {
        // Finder's 412.35 GB available. Memory's gigabyte made this 384.
        XCTAssertEqual(SystemStats.diskSize(412_345_678_901, locale: english), "412 GB")
        XCTAssertEqual(SystemStats.diskSize(500_000_000_000, locale: english), "500 GB")
        XCTAssertNotEqual(SystemStats.gigabytes(500_000_000_000, locale: english), "500", "memory's gigabyte is a bigger one")
    }

    func testTheDiskKeepsTheShapeOfTheOtherReadings() {
        XCTAssertEqual(SystemStats.diskSize(38_500_000_000, locale: english), "38.5 GB", "one decimal below a hundred")
        XCTAssertEqual(SystemStats.diskSize(12_000_000_000, locale: english), "12 GB", "and never a trailing .0")
        XCTAssertEqual(SystemStats.diskSize(0, locale: english), "0 GB")
    }

    func testAThousandGigabytesIsATerabyte() {
        XCTAssertEqual(SystemStats.diskSize(1_200_000_000_000, locale: english), "1.2 TB")
        XCTAssertEqual(SystemStats.diskSize(2_000_000_000_000, locale: english), "2 TB")
        XCTAssertEqual(SystemStats.diskSize(999_700_000_000, locale: english), "1 TB", "not 1000 GB")
        XCTAssertEqual(SystemStats.diskSize(999_000_000_000, locale: english), "999 GB")
    }

    func testMemoryIsStillCountedInPowersOfTwo() {
        // Sixteen gigabytes of memory is 2^34 bytes, and About This Mac calls it 16 GB.
        XCTAssertEqual(SystemStats.gigabytes(17_179_869_184, locale: english), "16")
        XCTAssertEqual(SystemStats.memoryText(used: 8_589_934_592, total: 17_179_869_184, locale: english), "8 / 16 GB")
    }

    /// The network figures beside these come from `ByteCountFormatter`, which writes the
    /// region's decimal mark; the memory and the disk were written with a point regardless, and
    /// a German Mac read "1,2 MB/s" in one column and "38.5 GB free" in the next.
    func testTheDecimalMarkIsTheRegionsLikeTheNetworkFiguresBesideIt() {
        XCTAssertEqual(SystemStats.diskSize(38_500_000_000, locale: german), "38,5 GB")
        XCTAssertEqual(SystemStats.diskSize(1_200_000_000_000, locale: german), "1,2 TB")
        XCTAssertEqual(SystemStats.diskSize(12_000_000_000, locale: german), "12 GB", "never a trailing ,0 either")
        XCTAssertEqual(SystemStats.memoryText(used: 13_314_398_618, total: 17_179_869_184, locale: german), "12,4 / 16 GB")
        XCTAssertEqual(SystemStats.memoryText(used: 13_314_398_618, total: 17_179_869_184, locale: english), "12.4 / 16 GB")
    }

    func testAShortNumberIsRoundedAsItAlwaysWas() {
        XCTAssertEqual(SystemStats.shortNumber(0.25, locale: english), "0.3", "half away from zero, not to even")
        XCTAssertEqual(SystemStats.shortNumber(99.96, locale: english), "100")
        XCTAssertEqual(SystemStats.shortNumber(1536, locale: english), "1536", "no thousands separator")
        XCTAssertEqual(SystemStats.shortNumber(1536, locale: german), "1536")
        XCTAssertEqual(SystemStats.shortNumber(.nan, locale: german), "0")
    }
}
