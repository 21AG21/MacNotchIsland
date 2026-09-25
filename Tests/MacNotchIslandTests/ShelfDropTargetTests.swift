import AppKit
import XCTest
@testable import MacNotchIsland

/// The split well's rules: which of Shelf, AirDrop and Share a point lands in, what a drop on
/// each does with the files it carried, and when the hand gets a tap. The sender here writes
/// down what it was asked and sends nothing, so no AirDrop window or share sheet ever opens.
final class ShelfDropTargetTests: XCTestCase {
    private typealias Target = ShelfDropTarget

    /// Records every call; AirDrop and Share succeed or fail as told.
    private final class FakeSender: ShelfDropSending {
        var airDropWorks = true
        var shareWorks = true
        private(set) var kept: [[URL]] = []
        private(set) var airDropped: [[URL]] = []
        private(set) var shared: [[URL]] = []

        func keep(_ urls: [URL]) { kept.append(urls) }

        func airDrop(_ urls: [URL]) -> Bool {
            airDropped.append(urls)
            return airDropWorks
        }

        func share(_ urls: [URL]) -> Bool {
            shared.append(urls)
            return shareWorks
        }
    }

    private let files = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.png")]

    // MARK: - Where a point lands

    func testThreeEqualColumnsInOrder() {
        XCTAssertEqual(Target.allCases, [.shelf, .airDrop, .share], "Shelf | AirDrop | Share, left to right")
        let width: CGFloat = 300
        XCTAssertEqual(Target.at(x: 0, width: width), .shelf)
        XCTAssertEqual(Target.at(x: 99, width: width), .shelf)
        XCTAssertEqual(Target.at(x: 100, width: width), .airDrop, "a boundary belongs to the column it opens")
        XCTAssertEqual(Target.at(x: 150, width: width), .airDrop)
        XCTAssertEqual(Target.at(x: 199.9, width: width), .airDrop)
        XCTAssertEqual(Target.at(x: 200, width: width), .share)
        XCTAssertEqual(Target.at(x: 300, width: width), .share, "the far edge is still the last column")
    }

    func testAPointPastEitherEdgeBelongsToTheColumnAtThatEdge() {
        XCTAssertEqual(Target.at(x: -40, width: 300), .shelf)
        XCTAssertEqual(Target.at(x: 900, width: 300), .share)
        XCTAssertEqual(Target.at(x: .greatestFiniteMagnitude, width: 300), .share, "bounded, never a trap")
    }

    func testAWellWithNoWidthYetIsAllShelf() {
        // Before the well has been laid out, or with a figure nobody can place, a drop goes
        // where it always went.
        XCTAssertEqual(Target.at(x: 250, width: 0), .shelf)
        XCTAssertEqual(Target.at(x: 250, width: -10), .shelf)
        XCTAssertEqual(Target.at(x: .nan, width: 300), .shelf)
        XCTAssertEqual(Target.at(x: 250, width: .infinity), .shelf)
    }

    func testTheColumnsScaleWithTheWell() {
        for width: CGFloat in [120, 480, 1000] {
            XCTAssertEqual(Target.at(x: width * 0.1, width: width), .shelf, "at \(width)")
            XCTAssertEqual(Target.at(x: width * 0.5, width: width), .airDrop, "at \(width)")
            XCTAssertEqual(Target.at(x: width * 0.9, width: width), .share, "at \(width)")
        }
    }

    func testEachTargetsColumnIsTheThirdItClaims() {
        let bounds = CGRect(x: 10, y: 5, width: 300, height: 90)
        XCTAssertEqual(Target.shelf.column(in: bounds), CGRect(x: 10, y: 5, width: 100, height: 90))
        XCTAssertEqual(Target.airDrop.column(in: bounds), CGRect(x: 110, y: 5, width: 100, height: 90))
        XCTAssertEqual(Target.share.column(in: bounds), CGRect(x: 210, y: 5, width: 100, height: 90))
        for target in Target.allCases {
            let column = target.column(in: bounds)
            XCTAssertEqual(Target.at(x: column.midX - bounds.minX, width: bounds.width), target,
                           "the middle of \(target.rawValue)'s column is \(target.rawValue)")
        }
    }

    // MARK: - What a drop on each does

    func testADropOnTheShelfKeepsTheFiles() {
        let sender = FakeSender()
        XCTAssertEqual(Target.shelf.deliver(files, to: sender), .kept)
        XCTAssertEqual(sender.kept, [files])
        XCTAssertTrue(sender.airDropped.isEmpty)
        XCTAssertTrue(sender.shared.isEmpty)
    }

    func testADropOnAirDropSendsWithoutKeeping() {
        let sender = FakeSender()
        XCTAssertEqual(Target.airDrop.deliver(files, to: sender), .sent)
        XCTAssertEqual(sender.airDropped, [files])
        XCTAssertTrue(sender.kept.isEmpty, "sent, not parked on the shelf as well")
        XCTAssertTrue(sender.shared.isEmpty)
    }

    func testADropOnShareOpensThePickerWithoutKeeping() {
        let sender = FakeSender()
        XCTAssertEqual(Target.share.deliver(files, to: sender), .sent)
        XCTAssertEqual(sender.shared, [files])
        XCTAssertTrue(sender.kept.isEmpty)
        XCTAssertTrue(sender.airDropped.isEmpty)
    }

    func testAnAirDropThatCannotHappenKeepsTheFilesInstead() {
        let sender = FakeSender()
        sender.airDropWorks = false
        XCTAssertEqual(Target.airDrop.deliver(files, to: sender), .keptInstead)
        XCTAssertEqual(sender.airDropped, [files], "it was tried")
        XCTAssertEqual(sender.kept, [files], "and nothing dropped on the island is lost")
    }

    func testAShareWithNothingToHangFromKeepsTheFilesInstead() {
        let sender = FakeSender()
        sender.shareWorks = false
        XCTAssertEqual(Target.share.deliver(files, to: sender), .keptInstead)
        XCTAssertEqual(sender.shared, [files])
        XCTAssertEqual(sender.kept, [files])
        XCTAssertTrue(sender.airDropped.isEmpty, "a drop on Share never turns into an AirDrop")
    }

    func testADropWithNoFilesDoesNothingAnywhere() {
        for target in Target.allCases {
            let sender = FakeSender()
            XCTAssertEqual(target.deliver([], to: sender), .nothing, target.rawValue)
            XCTAssertTrue(sender.kept.isEmpty && sender.airDropped.isEmpty && sender.shared.isEmpty, target.rawValue)
        }
    }

    // MARK: - What is lit, and when the hand feels it

    func testTheShelfIsLitWhileThePointerIsElsewhereOnTheIsland() {
        XCTAssertEqual(Target.lit(nil), .shelf, "a drop off the well goes to the shelf, so the well says so")
        for target in Target.allCases { XCTAssertEqual(Target.lit(target), target) }
    }

    func testATapOnlyWhenWhatIsLitChanges() {
        XCTAssertTrue(Target.changesLight(from: .shelf, to: .airDrop))
        XCTAssertTrue(Target.changesLight(from: .airDrop, to: .share))
        XCTAssertTrue(Target.changesLight(from: .share, to: .shelf))
        XCTAssertTrue(Target.changesLight(from: nil, to: .airDrop), "onto AirDrop from the band")
        XCTAssertTrue(Target.changesLight(from: .share, to: nil), "off Share to the band lights the shelf")
        XCTAssertFalse(Target.changesLight(from: .airDrop, to: .airDrop))
        XCTAssertFalse(Target.changesLight(from: nil, to: .shelf), "arriving on the island has tapped already")
        XCTAssertFalse(Target.changesLight(from: .shelf, to: nil))
        XCTAssertFalse(Target.changesLight(from: nil, to: nil))
    }

    // MARK: - Words

    func testEveryTargetHasANameAGlyphAndAPrompt() {
        for target in Target.allCases {
            XCTAssertFalse(target.title.isEmpty)
            XCTAssertFalse(target.symbol.isEmpty)
            XCTAssertTrue(target.prompt.hasPrefix("Drop to"), target.prompt)
        }
        XCTAssertEqual(Target.shelf.prompt, "Drop to add", "the words the undivided well has always used")
    }

    // MARK: - Whether the well splits

    func testOnlyADragCarryingFilesSplitsTheWell() throws {
        // Private, named pasteboards standing in for the drag's, so nothing the person at the
        // Mac has dragged or copied is read or overwritten.
        let files = NSPasteboard(name: NSPasteboard.Name("ShelfDropTargetTests-files-\(UUID().uuidString)"))
        let text = NSPasteboard(name: NSPasteboard.Name("ShelfDropTargetTests-text-\(UUID().uuidString)"))
        defer {
            files.releaseGlobally()
            text.releaseGlobally()
        }
        files.clearContents()
        text.clearContents()
        guard files.writeObjects([URL(fileURLWithPath: NSTemporaryDirectory()) as NSURL]),
              text.setString("a line of text", forType: .string) else {
            throw XCTSkip("this session has no pasteboard server to write to")
        }
        XCTAssertTrue(Target.carriesFiles(files))
        XCTAssertFalse(Target.carriesFiles(text))
    }
}
