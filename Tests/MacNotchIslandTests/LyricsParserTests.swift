import XCTest
@testable import MacNotchIsland

final class LyricsParserTests: XCTestCase {
    private let sample = """
        [ar:Test Artist]
        [ti:Test Song]
        [length: 03:12]
        [00:12.00]First line
        [00:17.20][00:22.20]Repeated line
        [01:23.456]Third line
        [02:00]No fraction at all
        [02:30.5]
        """

    func testParsesTimestampsAndSkipsMetadata() {
        let lines = LyricsService.parse(lrc: sample)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[0].time, 12, accuracy: 0.0001)
        XCTAssertEqual(lines[0].text, "First line")
        XCTAssertEqual(lines[3].time, 83.456, accuracy: 0.0001)
        XCTAssertEqual(lines[3].text, "Third line")
        XCTAssertEqual(lines[4].time, 120, accuracy: 0.0001)
        XCTAssertEqual(lines[4].text, "No fraction at all")
        // A stamp with nothing after it marks an instrumental gap: kept, but empty.
        XCTAssertEqual(lines[5].time, 150.5, accuracy: 0.0001)
        XCTAssertEqual(lines[5].text, "")
    }

    func testMultipleTimestampsOnOneLineBecomeSeparateLines() {
        let lines = LyricsService.parse(lrc: sample)
        XCTAssertEqual(lines[1].time, 17.2, accuracy: 0.0001)
        XCTAssertEqual(lines[2].time, 22.2, accuracy: 0.0001)
        XCTAssertEqual(lines[1].text, "Repeated line")
        XCTAssertEqual(lines[2].text, "Repeated line")
    }

    func testTwoAndThreeDigitFractions() {
        let lines = LyricsService.parse(lrc: "[00:01.5]a\n[00:02.25]b\n[00:03.125]c\n[00:04:75]d")
        XCTAssertEqual(lines.map { $0.text }, ["a", "b", "c", "d"])
        XCTAssertEqual(lines[0].time, 1.5, accuracy: 0.0001)
        XCTAssertEqual(lines[1].time, 2.25, accuracy: 0.0001)
        XCTAssertEqual(lines[2].time, 3.125, accuracy: 0.0001)
        XCTAssertEqual(lines[3].time, 4.75, accuracy: 0.0001)
    }

    func testOutputIsSortedAndCarriageReturnsSurvive() {
        let lines = LyricsService.parse(lrc: "[00:30.00]Later\r\n[00:10.00]Earlier\r\n")
        XCTAssertEqual(lines.map { $0.text }, ["Earlier", "Later"])
        XCTAssertEqual(lines[0].time, 10, accuracy: 0.0001)
    }

    func testGarbageAndEmptyInputProduceNoLines() {
        XCTAssertTrue(LyricsService.parse(lrc: "").isEmpty)
        XCTAssertTrue(LyricsService.parse(lrc: "just some plain lyrics\nwith no timestamps").isEmpty)
        XCTAssertTrue(LyricsService.parse(lrc: "[ar:Only metadata]\n[by:Someone]").isEmpty)
    }

    func testEnhancedWordTimingsAreStripped() {
        let lines = LyricsService.parse(lrc: "[00:05.00]<00:05.00>Hello <00:05.50>world")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello world")
    }

    func testAngleBracketsThatAreNotTimestampsAreKept() {
        let lines = LyricsService.parse(lrc: "[00:05.00]a <3 b")
        XCTAssertEqual(lines[0].text, "a <3 b")
    }

    func testLineAtPicksLastLineAtOrBeforeTime() {
        let lines = LyricsService.parse(lrc: sample)
        XCTAssertNil(LyricsService.line(at: 0, in: lines))
        XCTAssertNil(LyricsService.line(at: 11.99, in: lines))
        XCTAssertEqual(LyricsService.line(at: 12, in: lines), 0)
        XCTAssertEqual(LyricsService.line(at: 16.9, in: lines), 0)
        XCTAssertEqual(LyricsService.line(at: 20, in: lines), 1)
        XCTAssertEqual(LyricsService.line(at: 22.2, in: lines), 2)
        XCTAssertEqual(LyricsService.line(at: 100, in: lines), 3)
        XCTAssertEqual(LyricsService.line(at: 99999, in: lines), 5)
    }

    func testLineAtWithNoLines() {
        XCTAssertNil(LyricsService.line(at: 10, in: []))
    }

    func testLineAtWalksEveryLineInOrder() {
        let lines = LyricsService.parse(lrc: sample)
        // Every timestamp in the sample is distinct, so each one lands on its own line.
        for (index, line) in lines.enumerated() {
            XCTAssertEqual(LyricsService.line(at: line.time, in: lines), index)
            XCTAssertEqual(LyricsService.line(at: line.time + 0.01, in: lines), index)
        }
    }

    func testTimestampParsingRejectsNonsense() {
        XCTAssertNil(LyricsService.timestamp(from: "ar:Artist"[...]))
        XCTAssertNil(LyricsService.timestamp(from: "0012"[...]))
        XCTAssertNil(LyricsService.timestamp(from: "00:12.3456"[...]))
        XCTAssertEqual(LyricsService.timestamp(from: "00:12"[...]) ?? -1, 12, accuracy: 0.0001)
    }
}
