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

    // MARK: - isNewer

    func testIsNewerComparesNumericallyNotLexically() {
        // "1.10.0" is numerically newer than "1.2.0" even though "1" < "2" as a string.
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0", than: "1.10.0"))
    }

    func testIsNewerTreatsMissingComponentsAsZero() {
        XCTAssertFalse(UpdateChecker.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0", than: "1.2"))
        XCTAssertTrue(UpdateChecker.isNewer("1.3", than: "1.2.0"))
    }

    func testIsNewerPreReleaseSortsBelowPlainVersion() {
        XCTAssertFalse(UpdateChecker.isNewer("2.0.0-beta", than: "2.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "2.0.0-beta"))
    }

    func testIsNewerHandlesVPrefixOnEitherSide() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.3.0", than: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0", than: "v1.3.0"))
    }

    func testIsNewerFalseWhenEqual() {
        XCTAssertFalse(UpdateChecker.isNewer("1.2.3", than: "1.2.3"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.2.3", than: "1.2.3"))
    }

    func testIsNewerFalseWhenCurrentIsAheadOnAnEarlierComponent() {
        XCTAssertFalse(UpdateChecker.isNewer("1.9.9", than: "2.0.0"))
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
}
