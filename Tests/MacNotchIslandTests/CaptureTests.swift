import XCTest
@testable import MacNotchIsland

/// The capture card: what it says, and how the words it finds are put together.
final class CaptureTests: XCTestCase {
    private func capture(_ path: String = "/Users/you/Desktop/Screenshot 2026-09-09 at 21.14.02.png",
                         recording: Bool = false, onShelf: Bool = true, text: String? = nil) -> CaptureState {
        CaptureState(path: path, isRecording: recording, thumbnail: nil, onShelf: onShelf, text: text)
    }

    func testACaptureIsNamedByItsFileAndItsKind() {
        let shot = capture()
        XCTAssertEqual(shot.name, "Screenshot 2026-09-09 at 21.14.02.png")
        XCTAssertEqual(shot.title, "Screenshot")
        XCTAssertEqual(shot.symbol, "camera.viewfinder")
        XCTAssertEqual(shot.url.path, shot.path)

        let movie = capture("/Users/you/Desktop/Screen Recording.mov", recording: true)
        XCTAssertEqual(movie.title, "Screen recording")
        XCTAssertEqual(movie.symbol, "record.circle")
    }

    func testThePillSaysWhereItWentOnlyWhenItWentThere() {
        XCTAssertEqual(capture(onShelf: true).trailingText, "On the shelf")
        // With the shelf switched off the capture is still announced; it just cannot claim to
        // have landed somewhere it did not.
        XCTAssertEqual(capture(onShelf: false).trailingText, "Captured")
        XCTAssertEqual(capture("/x.mov", recording: true, onShelf: false).trailingText, "Recorded")
    }

    func testCopyTheTextIsOfferedOnlyWhereThereAreWords() {
        XCTAssertFalse(capture().hasText, "nothing has been read yet")
        XCTAssertFalse(capture(text: "").hasText, "read, and there was nothing in it")
        XCTAssertFalse(capture(text: "   \n  ").hasText, "whitespace is not words")
        XCTAssertTrue(capture(text: "sudo launchctl list").hasText)
    }

    func testTheWordsArePutBackTogetherTheWayAPersonWouldPasteThem() {
        // In reading order, one line each, with the empty ones dropped.
        XCTAssertEqual(CaptureText.joined(["  Notch Island  ", "", "   ", "Version 1.0"]),
                       "Notch Island\nVersion 1.0")
        XCTAssertEqual(CaptureText.joined([]), "")
        XCTAssertEqual(CaptureText.joined(["  "]), "")
    }

    func testACaptureIsNeverHeldBackByAFocus() {
        // It is the answer to a key the person just pressed, not an interruption.
        let activity = IslandActivity(id: "capture", kind: .capture, content: .capture(capture()), priority: 85)
        XCTAssertFalse(ActivityCenter.focusHolds(activity))
    }

    func testACaptureHasACardOfItsOwn() {
        XCTAssertTrue(ActivityContent.capture(capture()).hasExpandedView)
        XCTAssertEqual(ActivityContent.capture(capture()).cardHeight, ActivityContent.cardRow)
    }

    func testThereIsNothingToReadInAFileThatIsNotThere() {
        let missing = URL(fileURLWithPath: "/nowhere/at/all/Screenshot.png")
        XCTAssertNil(CaptureText.recognizeSync(missing), "no picture, no words, and no crash")
    }
}
