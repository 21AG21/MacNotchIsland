import XCTest
@testable import MacNotchIsland

/// UpdateChecker's pure logic: version comparison and GitHub payload parsing. Neither
/// touches the network, UserDefaults, or ActivityCenter.
final class UpdateCheckerTests: XCTestCase {
    // MARK: - normalize(tag:)

    func testNormalizeStripsLeadingV() {
        XCTAssertEqual(UpdateChecker.normalize(tag: "v1.2.3"), "1.2.3")
        XCTAssertEqual(UpdateChecker.normalize(tag: "V1.2.3"), "1.2.3")
    }

    func testNormalizeLeavesPlainVersionAlone() {
        XCTAssertEqual(UpdateChecker.normalize(tag: "1.2.3"), "1.2.3")
    }

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(UpdateChecker.normalize(tag: "  v1.2.3  "), "1.2.3")
    }

    // MARK: - isNewer(tag:installed:)

    func testIsNewerComparesNumericallyNotLexically() {
        // "1.10.0" is numerically newer than "1.9.0" even though "1" < "9" as a string.
        XCTAssertTrue(UpdateChecker.isNewer(tag: "1.10.0", installed: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "1.9.0", installed: "1.10.0"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "1.10.0", installed: "1.2.0"))
    }

    func testIsNewerTreatsMissingComponentsAsZero() {
        XCTAssertFalse(UpdateChecker.isNewer(tag: "1.2", installed: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "1.2.0", installed: "1.2"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "1.3", installed: "1.2.0"))
    }

    func testIsNewerHandlesVPrefixOnEitherSide() {
        XCTAssertTrue(UpdateChecker.isNewer(tag: "v1.3.0", installed: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "1.2.0", installed: "v1.3.0"))
    }

    func testIsNewerFalseWhenCurrentIsAheadOnAnEarlierComponent() {
        XCTAssertFalse(UpdateChecker.isNewer(tag: "1.9.9", installed: "2.0.0"))
    }

    /// The first launch of a fresh install: GitHub's latest tag is the version it is. Told to
    /// update to itself was the bug; this is the rule half of the fix, and the stamp in
    /// `Scripts/build.sh` is the other.
    func testTheReleaseYouAreRunningIsUpToDate() {
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v1.0.0", installed: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "1.0.0", installed: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "V1.0.0", installed: "v1.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: " v1.2.3\n", installed: "1.2.3"))
    }

    func testAnOlderTagIsUpToDate() {
        // A build made ahead of its release, or a release pulled back to the one before.
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v1.9.0", installed: "1.10.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v0.9.0", installed: "1.0.0"))
    }

    func testAPreReleaseSortsBelowTheReleaseItLeadsUpTo() {
        XCTAssertFalse(UpdateChecker.isNewer(tag: "2.0.0-beta", installed: "2.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "2.0.0", installed: "2.0.0-beta"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "v2.0.0", installed: "2.0.0-rc.1"))
        // But above the release before it.
        XCTAssertTrue(UpdateChecker.isNewer(tag: "v1.1.0-beta.1", installed: "1.0.0"))
    }

    func testPreReleasesCompareTheWaySemanticVersioningOrdersThem() {
        XCTAssertTrue(UpdateChecker.isNewer(tag: "1.1.0-beta.10", installed: "1.1.0-beta.9"), "as numbers")
        XCTAssertFalse(UpdateChecker.isNewer(tag: "1.1.0-beta.9", installed: "1.1.0-beta.10"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "1.1.0-rc.1", installed: "1.1.0-beta.3"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "1.1.0-beta.1", installed: "1.1.0-beta"), "the longer list")
        XCTAssertTrue(UpdateChecker.isNewer(tag: "1.1.0-alpha", installed: "1.1.0-1"), "a word above a number")
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v1.1.0-beta.2", installed: "1.1.0-beta.2"))
    }

    func testBuildMetadataIsNotAVersion() {
        XCTAssertFalse(UpdateChecker.isNewer(tag: "1.0.0+7", installed: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "1.0.0", installed: "1.0.0+7"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "1.0.1+2", installed: "1.0.0+9"))
    }

    /// The other half: a release is built with its tag written into its own Info.plist, and a
    /// tag that is not a version stops the release rather than shipping one that cannot tell
    /// itself from its own tag. Read from the files, the way `AskTests` holds `notchctl`'s
    /// exit table to the app's.
    func testAReleaseIsBuiltWithItsOwnVersion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = try String(contentsOf: root.appendingPathComponent("Scripts/build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("plutil -replace CFBundleShortVersionString -string \"$NOTCH_VERSION\""))
        XCTAssertTrue(build.contains("plutil -replace CFBundleVersion -string \"$NOTCH_BUILD_NUMBER\""))
        XCTAssertFalse(build.contains("${VERSION:-}"),
                       "a VERSION a developer's shell exports for something else is not the app's")
        let release = try String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
                                 encoding: .utf8)
        XCTAssertTrue(release.contains("${GITHUB_REF_NAME#v}"), "the version comes from the tag")
        XCTAssertTrue(release.contains("NOTCH_VERSION="), "handed to the build by the name it reads")
        XCTAssertTrue(release.contains("NOTCH_BUILD_NUMBER="))
    }

    // MARK: - parse

    private func payload(tag: String, htmlURL: String = "https://github.com/21AG21/MacNotchIsland/releases/tag/v1.2.3",
                          assets: String = """
                          [
                            {"name": "MacNotchIsland.zip", "browser_download_url": "https://example.com/MacNotchIsland.zip"},
                            {"name": "MacNotchIsland.dmg", "browser_download_url": "https://example.com/MacNotchIsland.dmg"}
                          ]
                          """) -> Data {
        let json = """
        {
          "tag_name": "\(tag)",
          "html_url": "\(htmlURL)",
          "assets": \(assets)
        }
        """
        return Data(json.utf8)
    }

    func testParseSampleReleasePayload() throws {
        let data = payload(tag: "v1.2.3")
        let release = try XCTUnwrap(UpdateChecker.parse(data))
        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(release.releaseURL, URL(string: "https://github.com/21AG21/MacNotchIsland/releases/tag/v1.2.3"))
        XCTAssertEqual(release.dmgURL, URL(string: "https://example.com/MacNotchIsland.dmg"))
    }

    func testParsePicksFirstDmgAssetAmongOthers() throws {
        let data = payload(tag: "v2.0.0", assets: """
        [
          {"name": "readme.txt", "browser_download_url": "https://example.com/readme.txt"},
          {"name": "MacNotchIsland-2.0.0.dmg", "browser_download_url": "https://example.com/first.dmg"},
          {"name": "MacNotchIsland-2.0.0.dmg", "browser_download_url": "https://example.com/second.dmg"}
        ]
        """)
        let release = try XCTUnwrap(UpdateChecker.parse(data))
        XCTAssertEqual(release.dmgURL, URL(string: "https://example.com/first.dmg"))
    }

    func testParseWithoutMatchingDmgAssetLeavesDmgURLNil() throws {
        let data = payload(tag: "v1.0.0", assets: """
        [{"name": "MacNotchIsland.zip", "browser_download_url": "https://example.com/MacNotchIsland.zip"}]
        """)
        let release = try XCTUnwrap(UpdateChecker.parse(data))
        XCTAssertNil(release.dmgURL)
    }

    func testParseWithMissingAssetsFieldStillParses() throws {
        let json = """
        {"tag_name": "v1.0.0", "html_url": "https://github.com/21AG21/MacNotchIsland/releases/tag/v1.0.0"}
        """
        let release = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.0.0")
        XCTAssertNil(release.dmgURL)
    }

    func testAReleasePageThatIsNotAWebPageIsNotARelease() {
        // Whatever answered as api.github.com chose these strings, and the page ends up in
        // NSWorkspace.open on a click. The same rule every link the app did not write is held
        // to applies here: a release whose page is a file, or another app's scheme, is not one.
        for bad in ["file:///Applications/Calculator.app", "notchisland://settings",
                    "ftp://example.com/x", "javascript:alert(1)"] {
            let json = "{\"tag_name\": \"v9.0.0\", \"html_url\": \"\(bad)\"}"
            XCTAssertNil(UpdateChecker.parse(Data(json.utf8)), bad)
        }
    }

    func testADownloadThatIsNotAWebLinkIsSimplyNotOffered() {
        // The release itself is still good — it is the asset's link that is refused, and a
        // release with no download is one you read the page of.
        let json = "{\"tag_name\": \"v9.0.0\","
            + " \"html_url\": \"https://github.com/21AG21/MacNotchIsland/releases/tag/v9.0.0\","
            + " \"assets\": [{\"name\": \"MacNotchIsland.dmg\","
            + " \"browser_download_url\": \"file:///tmp/evil.dmg\"}]}"
        let release = UpdateChecker.parse(Data(json.utf8))
        XCTAssertNotNil(release, "the release is still a release")
        XCTAssertNil(release?.dmgURL, "it just has nothing safe to download")
    }

    func testParseReturnsNilForGarbageData() {
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
    }

    func testParseReturnsNilWhenRequiredFieldsMissing() {
        let json = "{\"tag_name\": \"v1.0.0\"}"
        XCTAssertNil(UpdateChecker.parse(Data(json.utf8)))
    }

    // MARK: - What one finished request amounts to

    private static let goodJSON = Data("""
    {"tag_name": "v9.9.9", "html_url": "https://github.com/21AG21/MacNotchIsland/releases/tag/v9.9.9"}
    """.utf8)

    func testAnOfflineMacIsNeverToldItIsUpToDate() {
        // The whole point of the outcome split: "could not ask" and "asked, nothing newer"
        // used to be the same branch, and a Mac with no network was told it was current.
        let outcome = UpdateChecker.outcome(data: nil, status: 0, error: URLError(.notConnectedToInternet))
        guard case .unreachable = outcome else {
            return XCTFail("no network should be unreachable, got \(outcome)")
        }
    }

    func testAServerErrorIsNotAnAnswer() {
        guard case .unreachable = UpdateChecker.outcome(data: nil, status: 403, error: nil) else {
            return XCTFail("HTTP 403 should be unreachable")
        }
        guard case .unreachable = UpdateChecker.outcome(data: nil, status: 500, error: nil) else {
            return XCTFail("HTTP 500 should be unreachable")
        }
    }

    func testAnUnreadableAnswerIsNotAnAnswer() {
        guard case .unreachable = UpdateChecker.outcome(data: Data("not json".utf8), status: 200, error: nil) else {
            return XCTFail("garbage should be unreachable")
        }
    }

    func testNothingPublishedYetIsGenuinelyUpToDate() {
        // 404 from /releases/latest is GitHub saying there is no release. A build that
        // nothing has been released after cannot be behind one.
        XCTAssertEqual(UpdateChecker.outcome(data: nil, status: 404, error: nil), .noReleases)
    }

    func testACancelledRequestSaysAndRecordsNothing() {
        XCTAssertEqual(UpdateChecker.outcome(data: nil, status: 0, error: URLError(.cancelled)), .cancelled)
    }

    func testAGoodAnswerCarriesTheRelease() {
        guard case .latest(let release) = UpdateChecker.outcome(data: Self.goodJSON, status: 200, error: nil) else {
            return XCTFail("a good payload should be a release")
        }
        XCTAssertEqual(release.version, "9.9.9")
    }

    func testTheReasonShownIsShortEnoughToRead() {
        // It goes in the subtitle of a card, on one line. A URLError's own description
        // ("The Internet connection appears to be offline.") is longer than that line.
        for outcome in [UpdateChecker.outcome(data: nil, status: 0, error: URLError(.timedOut)),
                        UpdateChecker.outcome(data: nil, status: 502, error: nil),
                        UpdateChecker.outcome(data: Data(), status: 200, error: nil)] {
            guard case .unreachable(let reason, let detail) = outcome else {
                return XCTFail("expected unreachable, got \(outcome)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertLessThanOrEqual(reason.count, 34, "\(reason) is too long for one line")
            XCTAssertFalse(detail.isEmpty)
        }
    }

    // MARK: - shared instance sanity

    func testSharedInstanceStartsWithNoKnownUpdate() {
        // A freshly referenced singleton that has never checked should report no update yet.
        let checker = UpdateChecker.shared
        if checker.latestVersion == nil {
            XCTAssertFalse(checker.updateAvailable)
        }
    }

    // MARK: - When an automatic check is due

    func testACheckIsDueADayOnOrWhenItsStampIsFromTheFuture() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 24 * 3600
        XCTAssertTrue(UpdateChecker.isDue(last: nil, now: now, interval: day), "never checked")
        XCTAssertFalse(UpdateChecker.isDue(last: now.addingTimeInterval(-3600), now: now, interval: day))
        XCTAssertTrue(UpdateChecker.isDue(last: now.addingTimeInterval(-day), now: now, interval: day))
        // Stamped while the clock was a week ahead: it used to wait a week and a day.
        XCTAssertTrue(UpdateChecker.isDue(last: now.addingTimeInterval(7 * day), now: now, interval: day))
        XCTAssertTrue(UpdateChecker.isDue(last: now.addingTimeInterval(1), now: now, interval: day))
    }
}
