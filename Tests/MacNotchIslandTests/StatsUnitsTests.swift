import XCTest
@testable import MacNotchIsland

/// Memory and disk are both "GB" on the Stats section, and they are not the same gigabyte.
final class StatsUnitsTests: XCTestCase {
    func testTheDiskIsCountedTheWayFinderCountsIt() {
        // Finder's 412.35 GB available. Memory's gigabyte made this 384.
        XCTAssertEqual(SystemStats.diskSize(412_345_678_901), "412 GB")
        XCTAssertEqual(SystemStats.diskSize(500_000_000_000), "500 GB")
        XCTAssertNotEqual(SystemStats.gigabytes(500_000_000_000), "500", "memory's gigabyte is a bigger one")
    }

    func testTheDiskKeepsTheShapeOfTheOtherReadings() {
        XCTAssertEqual(SystemStats.diskSize(38_500_000_000), "38.5 GB", "one decimal below a hundred")
        XCTAssertEqual(SystemStats.diskSize(12_000_000_000), "12 GB", "and never a trailing .0")
        XCTAssertEqual(SystemStats.diskSize(0), "0 GB")
    }

    func testAThousandGigabytesIsATerabyte() {
        XCTAssertEqual(SystemStats.diskSize(1_200_000_000_000), "1.2 TB")
        XCTAssertEqual(SystemStats.diskSize(2_000_000_000_000), "2 TB")
        XCTAssertEqual(SystemStats.diskSize(999_700_000_000), "1 TB", "not 1000 GB")
        XCTAssertEqual(SystemStats.diskSize(999_000_000_000), "999 GB")
    }

    func testMemoryIsStillCountedInPowersOfTwo() {
        // Sixteen gigabytes of memory is 2^34 bytes, and About This Mac calls it 16 GB.
        XCTAssertEqual(SystemStats.gigabytes(17_179_869_184), "16")
        XCTAssertEqual(SystemStats.memoryText(used: 8_589_934_592, total: 17_179_869_184), "8 / 16 GB")
    }
}
