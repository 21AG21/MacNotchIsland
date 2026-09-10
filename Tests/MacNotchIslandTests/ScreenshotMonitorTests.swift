import XCTest
@testable import MacNotchIsland

/// ScreenshotMonitor's pure rules: which file names look like captures, the recency window
/// and how the com.apple.screencapture location resolves. Nothing here watches a directory
/// or touches the shelf.
final class ScreenshotMonitorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    /// Resolves a location and returns its path without any trailing slash, so the
    /// assertions don't depend on how `URL.path` renders directory URLs.
    private func resolved(_ location: String?) -> String {
        let path = ScreenshotMonitor.screenshotDirectory(defaultsLocation: location, home: home).path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - Name matching

    func testEnglishCaptureNames() {
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Screenshot 2026-09-07 at 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Screen Shot 2019-05-01 at 3.45.12 PM.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Screen Recording 2026-09-07 at 10.15.30.mov"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("CleanShot 2026-09-07 at 10.15.30@2x.png"))
    }

    func testPrefixMatchIsCaseInsensitive() {
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("screenshot 2026-09-07 at 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("SCREENSHOT.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("cleanshot 2026-09-07 at 10.15.30.png"))
    }

    func testLocalizedCaptureNames() {
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Bildschirmfoto 2026-09-07 um 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Capture d’écran 2026-09-07 à 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Capture d'écran 2026-09-07 à 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Captura de pantalla 2026-09-07 a las 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Schermafbeelding 2026-09-07 om 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("スクリーンショット 2026-09-07 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("屏幕快照 2026-09-07 上午10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("截屏2026-09-07 10.15.30.png"))
    }

    func testGenericDateTimePatternMatches() {
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Simulator Screen Shot - iPhone 2026-09-07 at 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Capture 2026-09-07 at 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Capture 2026-09-07 at 10.15.30 (2).png"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Capture 2026-09-07 at 9.05.01.jpg"))
        XCTAssertTrue(ScreenshotMonitor.looksLikeScreenshot("Snímek obrazovky 2026-09-07 v 10.15.30.png"))
    }

    func testGenericDateTimePatternNeedsWordsDateAndTime() {
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot("2026-09-07 at 10.15.30.png"), "no words before the date")
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot("Photo 2026-09-07.png"), "date without a time")
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot("Report 2026-09-07 at 10.png"), "incomplete time")
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot("Report 2026-09-07 at 10.15.301.png"), "too many seconds digits")
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot("Report 26-09-07 at 10.15.30.png"), "two-digit year")
    }

    func testRejectsUnrelatedNames() {
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot("IMG_0001.png"))
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot("invoice.pdf"))
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot(".DS_Store"))
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot(""))
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot("My Screenshot.png"))
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot("Untitled.png"))
    }

    func testHiddenNamesNeverMatch() {
        XCTAssertFalse(ScreenshotMonitor.looksLikeScreenshot(".Screenshot 2026-09-07 at 10.15.30.png"))
        XCTAssertFalse(ScreenshotMonitor.isCandidate(name: ".Screenshot 2026-09-07 at 10.15.30.png"))
    }

    // MARK: - Candidate filter (name + extension)

    func testCandidateAcceptsImageAndMovieExtensions() {
        XCTAssertTrue(ScreenshotMonitor.isCandidate(name: "Screenshot 2026-09-07 at 10.15.30.png"))
        XCTAssertTrue(ScreenshotMonitor.isCandidate(name: "Screenshot 2026-09-07 at 10.15.30.JPG"))
        XCTAssertTrue(ScreenshotMonitor.isCandidate(name: "Screenshot 2026-09-07 at 10.15.30.jpeg"))
        XCTAssertTrue(ScreenshotMonitor.isCandidate(name: "Screenshot 2026-09-07 at 10.15.30.heic"))
        XCTAssertTrue(ScreenshotMonitor.isCandidate(name: "Screen Recording 2026-09-07 at 10.15.30.mov"))
    }

    func testCandidateRejectsOtherExtensionsAndPartialDownloads() {
        XCTAssertFalse(ScreenshotMonitor.isCandidate(name: "Screenshot 2026-09-07 at 10.15.30.pdf"))
        XCTAssertFalse(ScreenshotMonitor.isCandidate(name: "Screenshot 2026-09-07 at 10.15.30.png.crdownload"))
        XCTAssertFalse(ScreenshotMonitor.isCandidate(name: "Screenshot 2026-09-07 at 10.15.30"))
        XCTAssertFalse(ScreenshotMonitor.isCandidate(name: "IMG_0001.png"))
    }

    // MARK: - Recency

    func testRecentWithinWindow() {
        let now = Date()
        XCTAssertTrue(ScreenshotMonitor.isRecent(creation: now, now: now))
        XCTAssertTrue(ScreenshotMonitor.isRecent(creation: now.addingTimeInterval(-3), now: now))
        XCTAssertTrue(ScreenshotMonitor.isRecent(creation: now.addingTimeInterval(-10), now: now))
    }

    func testNotRecentOutsideWindow() {
        let now = Date()
        XCTAssertFalse(ScreenshotMonitor.isRecent(creation: now.addingTimeInterval(-11), now: now))
        XCTAssertFalse(ScreenshotMonitor.isRecent(creation: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(ScreenshotMonitor.isRecent(creation: now.addingTimeInterval(60), now: now), "well in the future")
    }

    func testMissingCreationDateIsNotRecent() {
        XCTAssertFalse(ScreenshotMonitor.isRecent(creation: nil, now: Date()))
    }

    func testCustomWindow() {
        let now = Date()
        XCTAssertTrue(ScreenshotMonitor.isRecent(creation: now.addingTimeInterval(-25), now: now, window: 30))
        XCTAssertFalse(ScreenshotMonitor.isRecent(creation: now.addingTimeInterval(-25), now: now, window: 20))
    }

    func testSlightFutureTimestampTolerated() {
        let now = Date()
        XCTAssertTrue(ScreenshotMonitor.isRecent(creation: now.addingTimeInterval(0.5), now: now), "file-system clock granularity")
    }

    // MARK: - Directory resolution

    func testTildeExpandsToHome() {
        XCTAssertEqual(resolved("~/Pictures/Shots"), "/Users/test/Pictures/Shots")
    }

    func testBareTildeIsHome() {
        XCTAssertEqual(resolved("~"), "/Users/test")
    }

    func testAbsoluteLocationIsKept() {
        XCTAssertEqual(resolved("/Users/test/Shots"), "/Users/test/Shots")
        XCTAssertEqual(resolved("/Users/test/Shots/"), "/Users/test/Shots")
    }

    func testNilLocationFallsBackToDesktop() {
        XCTAssertEqual(resolved(nil), "/Users/test/Desktop")
    }

    func testEmptyLocationFallsBackToDesktop() {
        XCTAssertEqual(resolved(""), "/Users/test/Desktop")
        XCTAssertEqual(resolved("   "), "/Users/test/Desktop")
    }

    func testRelativeLocationFallsBackToDesktop() {
        XCTAssertEqual(resolved("Pictures"), "/Users/test/Desktop")
    }

    func testResolvedDirectoryIsAFileURL() {
        XCTAssertTrue(ScreenshotMonitor.screenshotDirectory(defaultsLocation: "~/Pictures/Shots", home: home).isFileURL)
        XCTAssertTrue(ScreenshotMonitor.screenshotDirectory(defaultsLocation: nil, home: home).isFileURL)
    }

    // MARK: - The whole rule for one directory entry

    /// The walk that applies this moved off the main thread; what it decides did not.
    func testAnEntryIsACaptureByItsKindItsNameAndItsAge() {
        let now = Date()
        let name = "Screenshot 2026-09-07 at 10.15.30.png"
        XCTAssertTrue(ScreenshotMonitor.isNewCapture(name: name, isRegularFile: true, creation: now, now: now))
        XCTAssertFalse(ScreenshotMonitor.isNewCapture(name: name, isRegularFile: false, creation: now, now: now),
                       "a folder named like a capture is not one")
        XCTAssertFalse(ScreenshotMonitor.isNewCapture(name: "invoice.pdf", isRegularFile: true,
                                                      creation: now, now: now))
        XCTAssertFalse(ScreenshotMonitor.isNewCapture(name: name, isRegularFile: true,
                                                      creation: now.addingTimeInterval(-60), now: now),
                       "one that was already there when the watch began is old news")
        XCTAssertFalse(ScreenshotMonitor.isNewCapture(name: name, isRegularFile: true, creation: nil, now: now))
    }

    /// What counts as a capture, written out rather than worked out.
    ///
    /// This used to compute what it expected by composing the same two rules the function
    /// composes, which cannot disagree with it for any input: it asserted that the function is
    /// itself, over six names and three ages, and would have passed with the name rule and the
    /// age rule both deleted. The answers are literals now, so they can actually be wrong.
    func testWhatCountsAsACaptureAndWhatDoesNot() {
        let now = Date()
        // name, seconds old, whether the island should raise a card for it.
        let cases: [(String, Double, Bool)] = [
            ("Screenshot 2026-09-07 at 10.15.30.png", 0, true),
            ("Screenshot 2026-09-07 at 10.15.30.png", 5, true),
            ("Screenshot 2026-09-07 at 10.15.30.png", 30, false),      // already there when the watch began
            ("Screen Recording 2026-09-07 at 10.15.30.mov", 0, true),
            ("Screenshot 2026-09-07 at 10.15.30.pdf", 0, false),       // a screenshot is not a PDF
            ("Screenshot 2026-09-07 at 10.15.30.png.crdownload", 0, false),  // still being written
            ("IMG_0001.png", 0, false),                                // somebody's photo, saved to the desktop
            ("invoice.pdf", 0, false),
        ]
        for (name, age, expected) in cases {
            XCTAssertEqual(ScreenshotMonitor.isNewCapture(name: name, isRegularFile: true,
                                                          creation: now.addingTimeInterval(-age), now: now),
                           expected, "\(name), \(age)s old")
        }
    }

    func testAFolderNamedLikeAScreenshotIsStillAFolder() {
        let now = Date()
        XCTAssertFalse(ScreenshotMonitor.isNewCapture(name: "Screenshot 2026-09-07 at 10.15.30.png",
                                                      isRegularFile: false, creation: now, now: now))
    }
}
