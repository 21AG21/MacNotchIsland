import XCTest
@testable import MacNotchIsland

/// The name rule the Downloads watcher runs before it asks the disk anything. The watcher
/// itself reads the folder on its own queue; what it lets through is decided here, on names.
final class DownloadMonitorTests: XCTestCase {

    func testEachBrowsersPartialFileIsPickedOut() {
        let names = ["report.pdf.download", "Unconfirmed 123.crdownload", "movie.mkv.part"]
        XCTAssertEqual(DownloadMonitor.partials(in: names), names,
                       "Safari's bundle, Chrome's file and Firefox's file are all a download still running")
    }

    /// Downloads is hundreds of finished files beside the few that are still arriving, and the
    /// ones that are finished must cost nothing but a look at their names.
    func testFinishedFilesAreLeftOutBeforeAnythingIsAskedAboutThem() {
        let names = ["report.pdf", "Installer.dmg", "photo.jpg", "archive.zip", "notes.txt",
                     "big.iso.crdownload", "Folder", "partial", "download", "README.part.txt"]
        XCTAssertEqual(DownloadMonitor.partials(in: names), ["big.iso.crdownload"])
    }

    func testTheExtensionIsReadWhateverItsCase() {
        XCTAssertEqual(DownloadMonitor.partials(in: ["A.DOWNLOAD", "b.CrDownload", "c.Part"]),
                       ["A.DOWNLOAD", "b.CrDownload", "c.Part"])
    }

    /// The folder was listed with hidden files skipped, and the rule on names keeps that: a
    /// dot file is somebody's bookkeeping, not a download.
    func testHiddenFilesAreNeverADownload() {
        XCTAssertEqual(DownloadMonitor.partials(in: [".DS_Store", ".hidden.crdownload", ".x.part"]), [])
    }

    func testTheOrderOfTheListingIsKept() {
        let names = ["z.part", "a.txt", "m.download", "b.crdownload"]
        XCTAssertEqual(DownloadMonitor.partials(in: names), ["z.part", "m.download", "b.crdownload"])
    }

    func testAnEmptyFolderHasNothingInFlight() {
        XCTAssertEqual(DownloadMonitor.partials(in: []), [])
    }
}
