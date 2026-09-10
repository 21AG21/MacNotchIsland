import AppKit
import XCTest
@testable import MacNotchIsland

/// The notification rules are pure functions so they can be exercised without a banner, a
/// permission, or a Notification Centre to read one out of. They carry the whole of what makes
/// a history trustworthy: what counts as the same notification seen twice, what is kept, what
/// is let go of, and what a history written by an older build turns into.
final class NotificationInboxTests: XCTestCase {

    private func entry(_ title: String,
                       app: String = "Mail",
                       bundle: String = "com.apple.mail",
                       subtitle: String? = nil,
                       body: String? = nil,
                       at seconds: TimeInterval = 0) -> NotificationInbox.Entry {
        NotificationInbox.Entry(bundleID: bundle, appName: app, title: title,
                                subtitle: subtitle, body: body,
                                date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func thin(_ bundle: String = NotificationInbox.Entry.unknownBundleID,
                      at seconds: TimeInterval = 0) -> NotificationInbox.Entry {
        NotificationInbox.Entry(bundleID: bundle, date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    // MARK: - The same notification twice

    func testTheSameBannerSeenTwiceIsOneNotification() {
        let first = entry("Two new messages", body: "Ada: lunch?", at: 0)
        let again = entry("Two new messages", body: "Ada: lunch?", at: 3)
        let entries = NotificationInbox.dedupe(again, into: [first])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, first.id, "the row keeps its place under the pointer")
        XCTAssertEqual(entries.first?.date, again.date, "remembered as the later of the two")
    }

    func testTwoReadingsOfOneBannerAreOneDespiteTheWhitespace() {
        // Accessibility hands back what the label holds, padding and newlines and all.
        let first = entry("Two new messages", at: 0)
        let padded = entry("  Two new messages\n", at: 2)
        XCTAssertEqual(NotificationInbox.dedupe(padded, into: [first]).count, 1)
    }

    func testTheSameNotificationAgainMuchLaterIsItsOwnLine() {
        let first = entry("Two new messages", at: 0)
        let again = entry("Two new messages", at: NotificationInbox.duplicateWindow + 1)
        let entries = NotificationInbox.dedupe(again, into: [first])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0.date }, [again.date, first.date], "newest first")
    }

    func testTwoAppsSayingTheSameThingAreTwoNotifications() {
        let mail = entry("Reminder", at: 0)
        let calendar = entry("Reminder", app: "Calendar", bundle: "com.apple.iCal", at: 1)
        XCTAssertEqual(NotificationInbox.dedupe(calendar, into: [mail]).count, 2)
    }

    func testTheSameWordsWithADifferentBodyAreTwoNotifications() {
        let first = entry("Ada Lovelace", body: "lunch?", at: 0)
        let second = entry("Ada Lovelace", body: "half twelve?", at: 4)
        XCTAssertEqual(NotificationInbox.dedupe(second, into: [first]).count, 2)
    }

    // MARK: - Banners that could not be read

    func testABannerThatCouldNotBeReadIsStillRecorded() {
        let placeholder = thin("com.apple.MobileSMS", at: 0)
        XCTAssertTrue(placeholder.isThin)
        XCTAssertEqual(NotificationInbox.dedupe(placeholder, into: []).count, 1)
        XCTAssertEqual(NotificationInbox.trimmed([placeholder],
                                                 now: Date(timeIntervalSinceReferenceDate: 60)).count, 1,
                       "nothing is dropped for want of words")
    }

    func testTheFirstReadingWithWordsInItFillsInThePlaceholder() {
        let placeholder = thin(at: 0)
        let read = entry("Two new messages", at: 1)
        let entries = NotificationInbox.dedupe(read, into: [placeholder])
        XCTAssertEqual(entries.count, 1, "one banner, not two")
        XCTAssertEqual(entries.first?.id, placeholder.id)
        XCTAssertEqual(entries.first?.title, "Two new messages")
        XCTAssertEqual(entries.first?.bundleID, "com.apple.mail", "and it is named at last")
        XCTAssertEqual(entries.first?.appName, "Mail")
    }

    func testAPlaceholderDoesNotStandInForSomethingThatArrivesLongAfterIt() {
        let placeholder = thin(at: 0)
        let unrelated = entry("Two new messages", at: NotificationInbox.placeholderWindow + 1)
        XCTAssertEqual(NotificationInbox.dedupe(unrelated, into: [placeholder]).count, 2)
    }

    func testABannerWithNothingToGoOnIsStillCalledSomething() {
        let nameless = NotificationInbox.Entry(bundleID: "  ")
        XCTAssertEqual(nameless.bundleID, NotificationInbox.Entry.unknownBundleID)
        XCTAssertEqual(nameless.appName, NotificationInbox.Entry.unknownAppName)
        XCTAssertTrue(nameless.isThin)
    }

    // MARK: - What is kept

    func testOnlyTheMostRecentAreKept() {
        var entries: [NotificationInbox.Entry] = []
        for index in 0..<5 {
            entries = NotificationInbox.dedupe(entry("t\(index)", at: TimeInterval(index) * 600), into: entries)
        }
        let kept = NotificationInbox.trimmed(entries, now: Date(timeIntervalSinceReferenceDate: 2_400),
                                             limit: 3, expiry: NotificationInbox.maxAge)
        XCTAssertEqual(kept.map { $0.title }, ["t4", "t3", "t2"])
    }

    func testWhatIsOlderThanTheHistoryGoesIsDropped() {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let today = entry("today", at: 100_000 - 60)
        let lastWeek = entry("last week", at: 100_000 - NotificationInbox.maxAge - 60)
        XCTAssertEqual(NotificationInbox.trimmed([today, lastWeek], now: now).map { $0.title }, ["today"])
    }

    func testTheExpiryAndTheCapBothApply() {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let entries = [entry("a", at: 99_990),
                       entry("b", at: 99_980),
                       entry("c", at: 100_000 - NotificationInbox.maxAge - 1)]
        XCTAssertEqual(NotificationInbox.trimmed(entries, now: now, limit: 1,
                                                 expiry: NotificationInbox.maxAge).map { $0.title }, ["a"])
    }

    // MARK: - Looking for one

    func testEveryFieldIsSearched() {
        let one = entry("Two new messages", app: "Mail", subtitle: "Inbox",
                        body: "Ada Lovelace: lunch?", at: 0)
        XCTAssertTrue(NotificationInbox.matches(one, query: "mail"), "by the app it came from")
        XCTAssertTrue(NotificationInbox.matches(one, query: "messages"), "by its title")
        XCTAssertTrue(NotificationInbox.matches(one, query: "inbox"), "by its subtitle")
        XCTAssertTrue(NotificationInbox.matches(one, query: "lovelace"), "by what it said")
        XCTAssertFalse(NotificationInbox.matches(one, query: "calendar"))
    }

    func testNothingTypedMatchesEverything() {
        XCTAssertTrue(NotificationInbox.matches(entry("anything"), query: nil))
        XCTAssertTrue(NotificationInbox.matches(entry("anything"), query: "   "), "spaces are not a search")
    }

    // MARK: - Grouped by app

    func testGroupsAreOrderedByTheirNewestNotification() {
        let entries = [entry("newest mail", at: 300),
                       entry("calendar", app: "Calendar", bundle: "com.apple.iCal", at: 200),
                       entry("older mail", at: 100)]
        let groups = NotificationInbox.grouped(entries)
        XCTAssertEqual(groups.map { $0.appName }, ["Mail", "Calendar"])
        XCTAssertEqual(groups.first?.entries.map { $0.title }, ["newest mail", "older mail"])
        XCTAssertEqual(groups.first?.newest, Date(timeIntervalSinceReferenceDate: 300))
        XCTAssertEqual(groups.first?.id, "com.apple.mail")
    }

    func testAGroupIsNewestFirstWhateverOrderItWasHandedIn() {
        let groups = NotificationInbox.grouped([entry("older", at: 100), entry("newer", at: 300)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.entries.map { $0.title }, ["newer", "older"])
    }

    func testAnEmptyHistoryHasNoGroups() {
        XCTAssertTrue(NotificationInbox.grouped([]).isEmpty)
    }

    // MARK: - What is on disk

    func testAnEntryRoundTrips() throws {
        let stored = entry("Two new messages", subtitle: "Inbox", body: "Ada: lunch?", at: 1_234)
        let decoded = try JSONDecoder().decode([NotificationInbox.Entry].self,
                                               from: JSONEncoder().encode([stored]))
        XCTAssertEqual(decoded, [stored])
    }

    func testAHistoryWrittenBeforeAFieldExistedStillReadsBack() throws {
        // The app's name, the subtitle and the body were all added to what is written down;
        // an older file simply does not carry them, and it is still somebody's morning.
        let json = Data("""
        [{"id":"\(UUID().uuidString)","bundleID":"com.apple.mail","title":"Two new messages","date":0}]
        """.utf8)
        let decoded = try JSONDecoder().decode([NotificationInbox.Entry].self, from: json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.title, "Two new messages")
        XCTAssertNil(decoded.first?.subtitle)
        XCTAssertNil(decoded.first?.body)
        XCTAssertEqual(decoded.first?.appName, "Mail", "named from the bundle identifier it does carry")
        XCTAssertEqual(decoded.first?.date, Date(timeIntervalSinceReferenceDate: 0))
    }

    func testAnEntryWrittenWithNothingButATimeStillReadsBack() throws {
        let json = Data("[{\"date\":0}]".utf8)
        let decoded = try JSONDecoder().decode([NotificationInbox.Entry].self, from: json)
        XCTAssertEqual(decoded.count, 1, "one odd line must not take the whole history with it")
        XCTAssertEqual(decoded.first?.bundleID, NotificationInbox.Entry.unknownBundleID)
        XCTAssertTrue(decoded.first?.isThin == true)
    }

    // MARK: - What the watcher makes of a banner

    func testABannerNobodyCanReadIsStillANotification() {
        let banner = NotificationWatcher.Banner(texts: [], position: CGPoint(x: 900, y: 20))
        let made = NotificationWatcher.entry(from: banner, at: Date(timeIntervalSinceReferenceDate: 0),
                                             apps: [:])
        XCTAssertTrue(made.isThin)
        XCTAssertEqual(made.bundleID, NotificationInbox.Entry.unknownBundleID)
        XCTAssertEqual(NotificationInbox.dedupe(made, into: []).count, 1, "and it is kept")
    }

    func testABannerIsReadAsItsAppAndThenItsWords() {
        let banner = NotificationWatcher.Banner(texts: ["Mail", "Ada Lovelace", "Lunch", "Half twelve?"])
        let made = NotificationWatcher.entry(from: banner, at: Date(timeIntervalSinceReferenceDate: 0),
                                             apps: ["Mail": "com.apple.mail"])
        XCTAssertEqual(made.bundleID, "com.apple.mail")
        XCTAssertEqual(made.appName, "Mail")
        XCTAssertEqual(made.title, "Ada Lovelace")
        XCTAssertEqual(made.subtitle, "Lunch")
        XCTAssertEqual(made.body, "Half twelve?")
    }

    func testAFirstLineThatNamesNoAppIsTakenAsTheTitle() {
        let banner = NotificationWatcher.Banner(texts: ["Ada Lovelace", "Lunch?"])
        let made = NotificationWatcher.entry(from: banner, at: Date(timeIntervalSinceReferenceDate: 0),
                                             apps: [:])
        XCTAssertEqual(made.bundleID, NotificationInbox.Entry.unknownBundleID)
        XCTAssertEqual(made.title, "Ada Lovelace")
        XCTAssertEqual(made.body, "Lunch?")
        XCTAssertFalse(made.isThin, "there are words in it, whoever sent it")
    }

    func testABannerStillOnScreenLooksLikeTheSameBanner() {
        let up = NotificationWatcher.Banner(texts: ["Mail", "Ada"], position: CGPoint(x: 900, y: 20))
        let moved = NotificationWatcher.Banner(texts: ["Mail", "Ada"], position: CGPoint(x: 900, y: 90))
        XCTAssertEqual(up.digest, moved.digest, "further down the stack, but the same banner")
        let unreadable = NotificationWatcher.Banner(texts: [], position: CGPoint(x: 900, y: 20))
        XCTAssertNotEqual(unreadable.digest, up.digest)
        XCTAssertNotEqual(unreadable.digest,
                          NotificationWatcher.Banner(texts: [], position: CGPoint(x: 900, y: 90)).digest,
                          "two banners nobody can read are still two banners")
    }
}
