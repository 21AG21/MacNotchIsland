import Combine
import Foundation

/// What came past on a banner, kept.
///
/// The Mac has never had a notification history. A banner you did not look up in time is
/// gone — Apple's own support forums say so in as many words — and Notification Centre is not
/// the answer to it: what sits there is whatever each app chose to leave behind, so anything
/// posted and withdrawn in the same breath, or cleared by the app that sent it, was never
/// there at all. Every other thing in the notch shows you a notification as it arrives. This
/// is the part that still knows about it an hour later, which is the part people actually ask
/// for.
///
/// The rules below are static and free of side effects, because the watcher that feeds them
/// reads a system UI that cannot be relied upon and re-reads the same banner more than once.
/// The rules are where the correctness lives, so they are the part that is tested; the
/// reading is deliberately dumb.
final class NotificationInbox: ObservableObject {
    static let shared = NotificationInbox()

    /// One notification, as it came past.
    ///
    /// A great deal of this is optional on purpose. What can be read off a banner varies with
    /// the app that posted it, with the notification's style, and with whatever Apple did to
    /// the Notification Centre window tree in the last point release. An entry that carries
    /// nothing but the app and the moment is still worth having — "something from Messages at
    /// twenty past" is the answer to most of the questions this feature exists to answer — so
    /// the thin entry is a first-class citizen here, not a failure.
    struct Entry: Identifiable, Equatable, Codable {

        /// Where a banner goes when there is no telling which app sent it. A real bundle
        /// identifier can never collide with this: identifiers have at least one dot in them.
        static let unknownBundleID = "unknown"

        /// What such an entry is called in a list.
        static let unknownAppName = "Notification"

        /// Made once, written down, and kept through every collapse of a repeat, so a row in
        /// an open list never changes identity under the pointer.
        var id: UUID
        var bundleID: String
        var appName: String
        var title: String
        var subtitle: String?
        var body: String?
        var date: Date

        /// Everything is spelled out rather than left to the synthesised memberwise
        /// initialiser so that every entry, wherever it came from, goes through the same
        /// tidying: text arrives from an accessibility tree with padding and stray newlines
        /// on it, and two readings of one banner have to compare equal.
        init(id: UUID = UUID(), bundleID: String, appName: String = "", title: String = "",
             subtitle: String? = nil, body: String? = nil, date: Date = Date()) {
            let bundle = Entry.tidied(bundleID) ?? Entry.unknownBundleID
            self.id = id
            self.bundleID = bundle
            self.appName = Entry.name(appName, bundleID: bundle)
            self.title = Entry.tidied(title) ?? ""
            self.subtitle = Entry.tidied(subtitle)
            self.body = Entry.tidied(body)
            self.date = date
        }

        private enum CodingKeys: String, CodingKey {
            case id, bundleID, appName, title, subtitle, body, date
        }

        /// Nothing on disk is required except that it be an object.
        ///
        /// A history is read at launch and is worth having even when it was written by a
        /// build that knew about fewer things than this one does. The alternative is an
        /// old file that throws on one missing key and takes the whole history with it,
        /// which is the one failure this feature must never have.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decodeIfPresent(UUID.self, forKey: .id)
            let bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
            let appName = try container.decodeIfPresent(String.self, forKey: .appName)
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            let subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
            let body = try container.decodeIfPresent(String.self, forKey: .body)
            let date = try container.decodeIfPresent(Date.self, forKey: .date)
            self.init(id: id ?? UUID(),
                      bundleID: bundleID ?? Entry.unknownBundleID,
                      appName: appName ?? "",
                      title: title ?? "",
                      subtitle: subtitle,
                      body: body,
                      date: date ?? Date())
        }

        /// True when the words could not be read and only the app and the moment were. The
        /// island shows such a row as the app's name and a time, and says no more than it
        /// knows.
        var isThin: Bool { title.isEmpty && subtitle == nil && body == nil }

        /// What a find is compared against. The app's name is in there because "the thing
        /// from the bank" is how a notification is remembered, far more often than by a word
        /// in it.
        var searchFields: [String] { [appName, title, subtitle ?? "", body ?? ""] }

        /// Empty is the same as absent here: a banner whose subtitle is a space said nothing.
        private static func tidied(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        /// A readable name for an app that would not give one. The last part of a bundle
        /// identifier is the app in nearly every case ("com.apple.mail" → "Mail"), and it
        /// beats showing somebody a reverse-DNS string. Only the first letter is touched:
        /// "MobileSMS" is how its own developer spelled it, and `capitalized` would make it
        /// "Mobilesms".
        private static func name(_ appName: String, bundleID: String) -> String {
            if let given = tidied(appName) { return given }
            if bundleID == unknownBundleID { return unknownAppName }
            guard let last = bundleID.split(separator: ".").last, !last.isEmpty else { return bundleID }
            return last.prefix(1).uppercased() + last.dropFirst()
        }
    }

    /// A day's notifications from one app, as a list shows them.
    struct AppGroup: Identifiable, Equatable {
        var bundleID: String
        var appName: String
        var entries: [Entry]

        var id: String { bundleID }
        /// When this app last had something to say, which is where its group sits in the list.
        var newest: Date { entries.first?.date ?? .distantPast }
    }

    @Published private(set) var entries: [Entry] = []

    /// The most that are kept.
    ///
    /// A busy Mac can put a couple of hundred banners past you in a working day, and this is
    /// a record of what you missed rather than an archive of the year. Two hundred is a few
    /// tens of kilobytes of JSON — read at launch without anyone noticing — and further back
    /// than anybody scrolls.
    static let maxEntries = 200

    /// How old one may be before it is dropped, whatever the cap says.
    ///
    /// Three days, because the gap this exists to bridge is a long meeting, a night, or a
    /// weekend away, and because a notification older than that has either been dealt with or
    /// never mattered. It also means a Mac that is quiet for a fortnight comes back to an
    /// empty list rather than to a fortnight-old crumb.
    static let maxAge: TimeInterval = 72 * 60 * 60

    /// How close together two identical notifications have to be to count as one.
    ///
    /// Two minutes. The watcher reads the same banner more than once by design — when it is
    /// re-scanned after the tree changes shape, when the app redraws it, when the watcher is
    /// restarted — and every one of those readings is the same notification. The cost is that
    /// two genuinely separate notifications with exactly the same app, title and words inside
    /// two minutes become one line whose time is the later of them, which is a fair price and
    /// is what a mail client's own list does anyway.
    static let duplicateWindow: TimeInterval = 120

    /// How long a thin entry stands in for whatever banner is on screen.
    ///
    /// Much shorter than the window above, and deliberately so. A thin entry says "something
    /// arrived and could not be read", so the very next reading that *can* be read is almost
    /// certainly that same something and fills it in rather than making a second line. Twenty
    /// seconds is longer than it takes to walk a window tree and far shorter than the gap
    /// between two unrelated notifications, so an unnamed placeholder cannot swallow a real
    /// notification that has nothing to do with it.
    static let placeholderWindow: TimeInterval = 20

    private static let fileName = "notifications.json"

    private var persistWork: DispatchWorkItem?

    private init() {
        entries = NotificationInbox.trimmed(NotificationInbox.loadPersisted())
    }

    // MARK: - Pure rules (unit-tested)

    /// Whether a notification just read is one already in the list.
    ///
    /// The identity of a notification is the app that sent it and the words it showed, within
    /// a short window — there is nothing else to go on, because the banner carries no
    /// identifier that survives being redrawn. A thin reading is treated as the same
    /// notification as anything else from that moment, which is what makes the degraded path
    /// safe: recording something you could not read never costs you a duplicate once it
    /// becomes readable.
    static func isRepeat(_ entry: Entry, of stored: Entry,
                         window: TimeInterval = NotificationInbox.duplicateWindow) -> Bool {
        let gap = abs(entry.date.timeIntervalSince(stored.date))
        if entry.isThin || stored.isThin {
            guard gap <= min(window, NotificationInbox.placeholderWindow) else { return false }
            // A placeholder has no app to compare, so an unnamed one matches anything of that
            // moment; two named ones still have to be the same app.
            return entry.bundleID == stored.bundleID
                || entry.bundleID == Entry.unknownBundleID
                || stored.bundleID == Entry.unknownBundleID
        }
        guard gap <= window else { return false }
        return entry.bundleID == stored.bundleID
            && entry.title == stored.title
            && entry.subtitle == stored.subtitle
            && entry.body == stored.body
    }

    /// What one entry becomes when a second reading of it arrives: the older one's identity,
    /// the newer one's time, and whatever either of them could read. A reading that could name
    /// the app fills in one that could not, and a reading with words fills in one without.
    static func merging(_ entry: Entry, into stored: Entry) -> Entry {
        var merged = stored
        merged.date = max(stored.date, entry.date)
        if stored.isThin, !entry.isThin {
            merged.title = entry.title
            merged.subtitle = entry.subtitle
            merged.body = entry.body
        }
        if merged.bundleID == Entry.unknownBundleID, entry.bundleID != Entry.unknownBundleID {
            merged.bundleID = entry.bundleID
            merged.appName = entry.appName
        }
        return merged
    }

    /// Files one notification, collapsing it into the entry it repeats where there is one.
    /// Newest first, always: the list is read that way by everything that draws it.
    static func dedupe(_ entry: Entry, into entries: [Entry],
                       window: TimeInterval = NotificationInbox.duplicateWindow) -> [Entry] {
        var result = entries
        guard let index = result.firstIndex(where: { isRepeat(entry, of: $0, window: window) }) else {
            return inserting(entry, into: result)
        }
        let merged = merging(entry, into: result[index])
        result.remove(at: index)
        return inserting(merged, into: result)
    }

    /// Puts one entry where the newest-first order says it belongs, rather than at the front:
    /// a history read back off disk, or a seeded gallery, is not necessarily handed over in
    /// the order it happened.
    private static func inserting(_ entry: Entry, into entries: [Entry]) -> [Entry] {
        var result = entries
        let index = result.firstIndex { $0.date <= entry.date } ?? result.count
        result.insert(entry, at: index)
        return result
    }

    /// The cap and the expiry, in that order, which is the whole of what keeps this from
    /// growing without end.
    static func trimmed(_ entries: [Entry], now: Date = Date(),
                        limit: Int = NotificationInbox.maxEntries,
                        expiry: TimeInterval = NotificationInbox.maxAge) -> [Entry] {
        let cutoff = now.addingTimeInterval(-expiry)
        let live = entries.filter { $0.date > cutoff }
        let cap = max(0, limit)
        guard live.count > cap else { return live }
        return Array(live.prefix(cap))
    }

    /// Whether one entry answers to what was typed. The comparison is the panel's own, so a
    /// find in this section behaves exactly as a find in the clipboard or the shelf does.
    static func matches(_ entry: Entry, query: String?) -> Bool {
        PanelFind.matches(entry.searchFields, query: query)
    }

    /// The list as a section draws it: one block per app, newest app first, and inside each
    /// block the newest notification first.
    ///
    /// Twenty notifications from one chat and one from the calendar is the ordinary case, and
    /// a flat list of twenty-one buries the one that mattered.
    static func grouped(_ entries: [Entry]) -> [AppGroup] {
        // Sorted by hand rather than with `sorted(by:)` alone, because that sort is not
        // stable: two notifications that arrived in the same second would otherwise swap
        // places on every redraw.
        let ordered = entries.enumerated().sorted { first, second in
            if first.element.date == second.element.date { return first.offset < second.offset }
            return first.element.date > second.element.date
        }.map { $0.element }

        var order: [String] = []
        var groups: [String: AppGroup] = [:]
        for entry in ordered {
            if var group = groups[entry.bundleID] {
                group.entries.append(entry)
                groups[entry.bundleID] = group
            } else {
                order.append(entry.bundleID)
                groups[entry.bundleID] = AppGroup(bundleID: entry.bundleID,
                                                  appName: entry.appName,
                                                  entries: [entry])
            }
        }
        return order.compactMap { groups[$0] }
    }

    // MARK: - Mutation

    /// Files what the watcher read.
    ///
    /// Called from the watcher's own run loop as often as from the main thread, so it puts
    /// itself on the main queue rather than trusting its caller: `entries` is published, and a
    /// published property written from a background thread is a redraw from a background
    /// thread.
    func record(_ entry: Entry) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.record(entry) }
            return
        }
        let updated = Self.trimmed(Self.dedupe(entry, into: entries))
        guard updated != entries else { return }
        entries = updated
        schedulePersist()
    }

    func remove(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        schedulePersist()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        schedulePersist()
    }

    /// Fills the history for the rendered gallery, which starts with nothing to show. Does
    /// nothing outside the gallery.
    func seedForGallery(_ entries: [Entry]) {
        guard RenderMode.isGallery else { return }
        self.entries = entries
    }

    // MARK: - Persistence

    private static func loadPersisted() -> [Entry] {
        guard let data = IslandFiles.read(fileName),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return decoded
    }

    /// Writes the history now rather than most of a second from now. Quitting is quicker than
    /// the debounce, and what arrived in the last minute before a quit is exactly what somebody
    /// will come back looking for. Nothing is written for a history nothing has touched.
    func flush() {
        guard persistWork != nil else { return }
        persistWork?.cancel()
        persistWork = nil
        Self.persist(entries)
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem { NotificationInbox.persist(snapshot) }
        persistWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private static func persist(_ entries: [Entry]) {
        do {
            try IslandFiles.write(try JSONEncoder().encode(entries), to: fileName)
        } catch {
            IslandLog.notifications.error("notification history save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
