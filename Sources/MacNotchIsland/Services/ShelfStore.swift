import AppKit
import Combine
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One file kept on the shelf. `addedAt` drives the age label and the expiry sweep.
struct ShelfItem: Identifiable, Equatable, Hashable {
    let url: URL
    var addedAt: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Files dropped on the notch. Persists paths (with the date they landed) across launches,
/// caches thumbnails, sweeps items older than `Preferences.shelfExpiryHours`, and performs
/// the Finder-style actions the shelf offers (open, reveal, AirDrop, share, copy, trash).
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet {
            guard items != oldValue else { return }
            publishActivity()
            // The offer to take a Clear back is an offer to put what it took back beside
            // whatever is on the shelf by then, and it holds until it no longer can be — see
            // `offerStands`. A download or a screenshot landing in the meantime is not that.
            if let offer = clearOffer, !Self.offerStands(taken: offer.taken, on: items, cap: maxItems) {
                settleClear()
            }
        }
    }
    @Published private var thumbnails: [URL: NSImage] = [:]
    /// Whether this store owns the island's "shelf" activity. Only the shared store does;
    /// the stores the tests build must not touch the real ActivityCenter unless asked.
    var publishesActivity: Bool

    /// Hours after which an item is swept off the shelf (0 = never). Injectable for tests.
    var expiryHoursProvider: () -> Double = { Preferences.shared.shelfExpiryHours }

    private let defaults: UserDefaults
    private let key: String
    private let maxItems: Int
    /// False in tests: no sweep timer and no QuickLook traffic.
    private let backgroundWork: Bool

    private var sweepTimer: Timer?
    /// The share picker, kept while it is up and let go of once it has finished
    /// (`sharingFinished`). It holds the view it was shown from, and that may be in a panel
    /// that has since been rebuilt; kept until the next share, it kept that view as well.
    private var sharingPicker: NSSharingServicePicker?
    /// The picker's delegate. Its `delegate` is weak, so the relay is kept here.
    private lazy var sharingRelay = SharingPickerRelay { [weak self] picker in self?.sharingFinished(picker) }
    private var quitObserver: NSObjectProtocol?

    private var thumbnailQueue: [URL] = []
    private var thumbnailsInFlight = 0
    private static let maxConcurrentThumbnails = 4
    private static let baseSweepInterval: TimeInterval = 300

    init(defaults: UserDefaults = .standard,
         key: String = "shelfItems",
         maxItems: Int = 24,
         backgroundWork: Bool = true,
         expiryHours: (() -> Double)? = nil,
         publishesActivity: Bool? = nil) {
        self.defaults = defaults
        self.key = key
        self.maxItems = max(1, maxItems)
        self.backgroundWork = backgroundWork
        self.publishesActivity = publishesActivity ?? backgroundWork
        if let expiryHours { expiryHoursProvider = expiryHours }

        var loaded = Self.load(from: defaults, key: key)
        // The same rule the sweep uses: a file that has gone is dropped, a file whose whole
        // folder has gone is on a disk that is not plugged in and is kept.
        loaded = loaded.filter { Self.stillThere($0) }
        if loaded.count > self.maxItems { loaded = Array(loaded.prefix(self.maxItems)) }
        items = loaded

        // A Clear whose offer was still standing when the app last stopped — it crashed, or
        // was killed, inside the moment — left the island's own files it took neither on the
        // shelf nor in the Trash. They go now, where they would have gone then.
        discardOwned(Self.orphans(in: Self.loadPendingTrash(from: defaults, key: key), onShelf: items))
        defaults.removeObject(forKey: Self.pendingTrashKey(key))

        sweepExpired()
        persist()
        for item in items { requestThumbnail(item.url) }
        rescheduleSweep()
        // `didSet` does not run during init; announce whatever was loaded.
        publishActivity()
        // A Clear that could still be taken back has not sent the island's own files to the
        // Trash yet. Quitting ends the offer, so it sends them now, before the process goes.
        if backgroundWork {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
                self?.settleClear(waiting: true)
            }
        }
    }

    // MARK: - Island activity

    /// The shelf activity: the island's way of showing that files are waiting. It lives while
    /// the shelf holds anything and ends when the last file leaves.
    static let activityID = "shelf"

    static func activity(for items: [ShelfItem]) -> IslandActivity? {
        guard let latest = items.first else { return nil }
        let type = UTType(filenameExtension: latest.url.pathExtension)
        let state = ShelfState(count: items.count, latestName: latest.name,
                               latestIsImage: type?.conforms(to: .image) ?? false)
        return IslandActivity(id: activityID, kind: .shelf, content: .shelf(state), priority: 30)
    }

    /// Re-evaluates the activity, e.g. when the shelf is switched on or off in Settings.
    func refreshActivity() { publishActivity() }

    private func publishActivity() {
        guard publishesActivity else { return }
        let center = ActivityCenter.shared
        if Preferences.shared.shelfEnabled, let activity = Self.activity(for: items) {
            center.upsert(activity)
        } else {
            center.end(id: Self.activityID)
        }
    }

    // MARK: - Contents

    var urls: [URL] { items.map(\.url) }

    func contains(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        return items.contains { $0.url == target }
    }

    func thumbnail(for url: URL) -> NSImage? { thumbnails[url.standardizedFileURL] }

    func add(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL }.map { $0.standardizedFileURL }
        guard !files.isEmpty else { return }

        let now = Date()
        // Capped *before* asking for thumbnails, so dropping hundreds of files stays cheap.
        let admission = Self.admitting(files, into: items, cap: maxItems, now: now)
        let before = Set(items.map(\.url))
        items = Self.pruned(admission.items, expiryHours: expiryHoursProvider(), now: now)
        // Anything the expiry swept off takes its file with it when the file was ours to begin
        // with; otherwise the drop folder would grow forever. So does a picture or a piece of
        // text written for a drop there was no room for: it never reached the shelf, and the
        // island has said so. The cap itself never pushes one of ours off — see `admitting`.
        let leaving = before.union(files).subtracting(items.map(\.url))
        discardOwned(Array(leaving))
        if !admission.refused.isEmpty { announceNoRoom(admission.refused.count) }

        pruneThumbnailCache()
        for item in items { requestThumbnail(item.url) }
        persist()
        rescheduleSweep()
        Haptics.tap()
    }

    /// What a drop does to the shelf, worked out before anything is touched.
    struct Admission: Equatable {
        /// The shelf afterwards, newest first.
        var items: [ShelfItem]
        /// Files from Finder that were already on the shelf and left it to make room. Only the
        /// shelf's reference to each goes; the file stays where it always was.
        var evicted: [URL]
        /// Files from the drop there was no room for, in the order they were dragged.
        var refused: [URL]
    }

    /// The cap, as a rule: what a drop leaves on a shelf that holds at most `cap` things.
    ///
    /// Each file goes in at the front as it comes, so the last one dragged is the first on the
    /// shelf. Room is made from the far end — the oldest — and only out of files that came
    /// from Finder, because letting go of one of those loses nothing: the file is still where
    /// it was. A picture, a link or a piece of text the island wrote for an earlier drop has
    /// nowhere else to live, and pushing it off the shelf sent it to the Trash; twenty-five
    /// files dragged from Finder used to do exactly that to a snippet somebody had parked, and
    /// to the first file of the drop itself, without a word. Whatever still does not fit is
    /// turned away from the end of the drop — what was dragged first gets in — and the caller
    /// says how many. A file already on the shelf is never turned away: dropping it again only
    /// brings it to the front.
    static func admitting(_ files: [URL], into items: [ShelfItem], cap: Int, now: Date = Date(),
                          isOwned: (URL) -> Bool = ShelfStore.isOwned) -> Admission {
        // One of each, in the order they were dragged.
        var seen = Set<URL>()
        let drop = files.filter { seen.insert($0).inserted }
        let onShelf = Set(items.map(\.url))
        let fresh = drop.filter { !onShelf.contains($0) }
        var staying = items.filter { !seen.contains($0.url) }

        var over = staying.count + drop.count - max(1, cap)
        var evicted: [URL] = []
        var index = staying.count - 1
        while over > 0, index >= 0 {
            if !isOwned(staying[index].url) {
                evicted.append(staying[index].url)
                staying.remove(at: index)
                over -= 1
            }
            index -= 1
        }

        let refused = over > 0 ? Array(fresh.suffix(over)) : []
        let turnedAway = Set(refused)
        let front = drop.filter { !turnedAway.contains($0) }
            .reversed()
            .map { ShelfItem(url: $0, addedAt: now) }
        return Admission(items: front + staying, evicted: evicted, refused: refused)
    }

    /// What the island says when a drop did not all fit.
    static func noRoomTitle(_ count: Int) -> String { "\(count) didn't fit" }

    /// A drop bigger than the room the shelf had. Said as the card, like a drop that carried
    /// nothing: somebody has just let go over the island and is looking straight at it.
    private func announceNoRoom(_ count: Int) {
        guard publishesActivity else { return }
        let custom = CustomActivity(title: Self.noRoomTitle(count),
                                     subtitle: "The shelf holds \(maxItems). Make some room and drop \(count == 1 ? "it" : "them") again.",
                                     symbol: "tray.full", tint: "orange")
        ActivityCenter.shared.showAlert(IslandActivity(id: "shelf-full", kind: .custom,
                                                       content: .custom(custom), priority: 85,
                                                       presentation: .expanded),
                                        duration: 3)
    }

    func remove(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let targets = Set(urls.map { $0.standardizedFileURL })
        let before = items.count
        items.removeAll { targets.contains($0.url) }
        guard items.count != before else { return }
        discardOwned(Array(targets))
        pruneThumbnailCache()
        persist()
        rescheduleSweep()
    }

    func remove(_ url: URL) { remove([url]) }

    /// Takes items off the shelf without touching what is behind them. For a file that has
    /// gone somewhere on purpose: it is somewhere else now, not gone, and the Trash pass
    /// `remove` makes has no business anywhere near it.
    func forget(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let targets = Set(urls.map { $0.standardizedFileURL })
        let before = items.count
        items.removeAll { targets.contains($0.url) }
        guard items.count != before else { return }
        pruneThumbnailCache()
        persist()
        rescheduleSweep()
    }

    /// Everything off the shelf at once, for good: what the menu bar's Clear Shelf, the island's
    /// menu and a script ask for. The section's own pill is `clear(matching:)`, which can be
    /// taken back.
    func clear() {
        // Whatever an earlier Clear was holding goes the way this one sends everything.
        settleClear()
        guard !items.isEmpty else { return }
        let leaving = urls
        items.removeAll()
        thumbnails.removeAll()
        thumbnailQueue.removeAll()
        discardOwned(leaving)
        persist()
        rescheduleSweep()
    }

    // MARK: - Clearing, and taking it back

    /// The files whose names answer to what was typed, in shelf order; everything when nothing
    /// was. The strip shows this, the gesture router counts it, and Clear takes it.
    static func matching(_ items: [ShelfItem], query: String?) -> [ShelfItem] {
        items.filter { PanelFind.matches([$0.url.lastPathComponent], query: query) }
    }

    /// What the section's Clear takes: what the strip is showing. With a find up that is the
    /// matches and nothing else — the pill counts them, and a pill that says "Clear 2" while
    /// eight more go with them is a pill that does more than it says.
    static func clearing(_ items: [ShelfItem], query: String?) -> [ShelfItem] {
        matching(items, query: query)
    }

    /// How long "Undo Clear" is offered for: the same moment the scratchpad gives.
    static let undoWindow: TimeInterval = NotesStore.undoWindow

    /// What the last Clear took, and the shelf before it, which is where the order it goes back
    /// in comes from.
    private struct ClearOffer {
        let before: [ShelfItem]
        let taken: [ShelfItem]
    }

    private var clearOffer: ClearOffer? {
        didSet { clearedItems = clearOffer?.taken }
    }
    private var clearWork: DispatchWorkItem?

    /// What the last Clear took off the shelf, for as long as the offer to put it back stands.
    /// The section's pill reads this.
    @Published private(set) var clearedItems: [ShelfItem]?

    /// The section's Clear: what the strip is showing comes off, and can be put back for a
    /// moment afterwards.
    ///
    /// The island's own files are not sent to the Trash until the offer has gone — putting
    /// back a snippet that is already in the Trash would put back a tile with nothing behind
    /// it. A second Clear supersedes the first, the way the scratchpad's does: one offer at a
    /// time, and always for the most recent thing taken.
    ///
    /// Which of those files are waiting is written down beside the shelf as well as held
    /// here. The shelf is saved without them at once, so an app that stopped inside the
    /// moment left them in Application Support for good, on no shelf and in no Trash; the
    /// next launch reads the list and finishes the job (`orphans`).
    func clear(matching query: String?) {
        let going = Self.clearing(items, query: query)
        guard !going.isEmpty else { return }
        settleClear()
        let before = items
        let leaving = Set(going.map(\.url))
        items.removeAll { leaving.contains($0.url) }
        pruneThumbnailCache()
        persist()
        rescheduleSweep()
        clearOffer = ClearOffer(before: before, taken: going)
        let waiting = going.map(\.url).filter { Self.isOwned($0) }
        if !waiting.isEmpty { defaults.set(waiting.map(\.path), forKey: Self.pendingTrashKey(key)) }
        let work = DispatchWorkItem { [weak self] in self?.settleClear() }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow, execute: work)
    }

    /// Puts back what the last Clear took, in the order the shelf had it, beside anything that
    /// has landed since — see `undoing`.
    func undoClear() {
        guard let offer = clearOffer else { return }
        clearWork?.cancel()
        clearWork = nil
        clearOffer = nil
        defaults.removeObject(forKey: Self.pendingTrashKey(key))
        let restored = Self.undoing(taken: offer.taken, before: offer.before, now: items)
        // A file somebody deleted in Finder while the offer stood stays gone.
        items = backgroundWork ? restored.filter { Self.stillThere($0) } : restored
        for item in items { requestThumbnail(item.url) }
        persist()
        rescheduleSweep()
    }

    /// Whether the offer to take a Clear back still stands on the shelf as it is now. Pure,
    /// so the rule is tested.
    ///
    /// It ended on any change at all, which the pill promising twelve seconds did not say: a
    /// download or a screenshot put on the shelf by itself a moment after a Clear took the
    /// Undo away, and sent the island's own snippets to the Trash with it. What it cannot
    /// outlive is what would make putting them back wrong: one of them on the shelf again,
    /// dropped a second time, which is a slot already filled; or a shelf filled since to where
    /// they would no longer fit beside what is on it, which is the cap deciding for them.
    static func offerStands(taken: [ShelfItem], on shelf: [ShelfItem], cap: Int) -> Bool {
        let back = Set(taken.map(\.url))
        return !shelf.contains { back.contains($0.url) } && shelf.count + taken.count <= max(1, cap)
    }

    /// The shelf with a Clear taken back: what has landed since, at the front where it landed,
    /// then the shelf as it stood before the Clear — the files it took back in their places,
    /// and anything that has left since left out. Pure, so the order is tested.
    ///
    /// A file that was on the shelf before and has been dropped again since keeps the date of
    /// its second landing, which is the date the expiry counts from.
    static func undoing(taken: [ShelfItem], before: [ShelfItem], now shelf: [ShelfItem]) -> [ShelfItem] {
        let earlier = Set(before.map(\.url))
        let back = Set(taken.map(\.url))
        var current: [URL: ShelfItem] = [:]
        for item in shelf where current[item.url] == nil { current[item.url] = item }
        let arrived = shelf.filter { !earlier.contains($0.url) }
        let kept = before.compactMap { item -> ShelfItem? in
            if let now = current[item.url] { return now }
            return back.contains(item.url) ? item : nil
        }
        return arrived + kept
    }

    /// The offer has gone — its moment passed, one of the files it took is back, the shelf
    /// filled past where they would fit, a second Clear came, or the app is quitting — and
    /// what it was holding goes the way a Clear always sent it: the island's own files to the
    /// Trash, anybody else's left where they are.
    private func settleClear(waiting: Bool = false) {
        guard let offer = clearOffer else { return }
        clearWork?.cancel()
        clearWork = nil
        clearOffer = nil
        let live = Set(items.map(\.url))
        discardOwned(offer.taken.map(\.url).filter { !live.contains($0) }, waiting: waiting)
        defaults.removeObject(forKey: Self.pendingTrashKey(key))
    }

    /// Where the files a standing offer is holding back from the Trash are written down: beside
    /// the shelf, under its own key, so a store the tests make with a key of their own keeps
    /// its list to itself too.
    static func pendingTrashKey(_ key: String) -> String { key + ".pendingTrash" }

    private static func loadPendingTrash(from defaults: UserDefaults, key: String) -> [URL] {
        (defaults.stringArray(forKey: pendingTrashKey(key)) ?? [])
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    /// What launch sends to the Trash of a Clear that never settled: the island's own files it
    /// was holding back, except any that are on the shelf again. Pure, so the rule is tested.
    ///
    /// Only what was written down is ever touched — never whatever else happens to be in the
    /// drop folder. A sweep of the whole folder against the shelf would, run by the tests on
    /// somebody's own Mac, have compared their real drop folder with the test runner's empty
    /// shelf.
    static func orphans(in pending: [URL], onShelf shelf: [ShelfItem],
                        isOwned: (URL) -> Bool = ShelfStore.isOwned) -> [URL] {
        let live = Set(shelf.map { $0.url.standardizedFileURL })
        return pending.map(\.standardizedFileURL).filter { !live.contains($0) && isOwned($0) }
    }

    /// A picture, a link or a piece of text the island itself wrote has nowhere else to live,
    /// so it goes to the Trash when it leaves the shelf — recoverable, and it does not pile up
    /// in Application Support. A file that came from Finder is never touched. Off the main
    /// thread, unless the app is on its way out and there is no later to do it in.
    private func discardOwned(_ urls: [URL], waiting: Bool = false) {
        let owned = urls.filter { Self.isOwned($0) }
        guard backgroundWork, !owned.isEmpty else { return }
        let discard: () -> Void = {
            for url in owned {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        if waiting {
            discard()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: discard)
        }
    }

    // MARK: - What Space previews

    /// What the strip on screen has picked out and what it is showing, as it last said. The
    /// selection is the strip's own state, and the hot key that turns Space into Quick Look
    /// lives nowhere near it; this is how the one hears about the other.
    private var stripSelection: [URL] = []
    private var stripShown: [URL] = []
    private var stripFinding = false

    /// The strip's selection or find changed. Not published: nothing is drawn from it.
    /// `finding` is whether a find is narrowing what it shows, which `shown` alone cannot say:
    /// a find that matches nothing and no find at all both leave nothing picked out.
    func stripChanged(selected: [URL], shown: [URL], finding: Bool) {
        stripSelection = selected
        stripShown = shown
        stripFinding = finding
    }

    /// What Space shows in Quick Look on the shelf.
    var quickLookTargets: [URL] {
        Self.quickLookTargets(selected: stripSelection, shown: stripShown, finding: stripFinding, on: urls)
    }

    /// What is picked out; failing that, with a find up, what it has narrowed the strip to,
    /// even if that is nothing; failing that, the whole shelf — the way Space works on a Finder
    /// window. An empty narrowing used to fall through to the whole shelf, so "zzz" typed over
    /// "No matches" and Space previewed every file the find was hiding. Only files still on
    /// the shelf count, so a strip that last spoke before something left it cannot preview a
    /// file that is not there.
    static func quickLookTargets(selected: [URL], shown: [URL], finding: Bool, on shelf: [URL]) -> [URL] {
        let live = Set(shelf)
        let picked = selected.filter { live.contains($0) }
        if !picked.isEmpty { return picked }
        if finding { return shown.filter { live.contains($0) } }
        return shelf
    }

    // MARK: - Expiry

    /// Pure expiry rule: items added more than `expiryHours` ago are dropped. 0 (or less)
    /// keeps everything forever.
    static func pruned(_ items: [ShelfItem], expiryHours: Double, now: Date = Date()) -> [ShelfItem] {
        guard expiryHours > 0 else { return items }
        let cutoff = now.addingTimeInterval(-expiryHours * 3600)
        return items.filter { $0.addedAt > cutoff }
    }

    /// Whether an item still has a file behind it.
    ///
    /// A file that was moved or deleted is gone from the shelf; a file whose whole folder has
    /// disappeared is on a disk that was unplugged, and the shelf keeps it, because plugging
    /// the disk back in should bring it back rather than having quietly emptied the shelf.
    static func stillThere(_ item: ShelfItem, fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: item.url.path) { return true }
        return !fileManager.fileExists(atPath: item.url.deletingLastPathComponent().path)
    }

    /// Drops expired items, and any whose file has gone. Returns true when something was removed.
    @discardableResult
    func sweepExpired(now: Date = Date()) -> Bool {
        let expiredGone = Self.pruned(items, expiryHours: expiryHoursProvider(), now: now)
        let kept = backgroundWork ? expiredGone.filter { Self.stillThere($0) } : expiredGone
        guard kept.count != items.count else { return false }
        let leaving = Set(items.map(\.url)).subtracting(kept.map(\.url))
        items = kept
        discardOwned(Array(leaving))
        pruneThumbnailCache()
        persist()
        rescheduleSweep()
        return true
    }

    private func rescheduleSweep() {
        guard backgroundWork, !items.isEmpty else {
            sweepTimer?.invalidate()
            sweepTimer = nil
            return
        }
        let interval = Self.baseSweepInterval * max(1, EnergyPolicy.shared.pollingMultiplier)
        if let timer = sweepTimer, timer.isValid, abs(timer.timeInterval - interval) < 1 { return }
        sweepTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sweepExpired()
            self.rescheduleSweep()
        }
        timer.tolerance = interval * 0.25
        sweepTimer = timer
    }

    // MARK: - Actions

    func open(_ urls: [URL]) {
        for url in urls { _ = NSWorkspace.shared.open(url) }
    }

    /// Files what is picked out into a folder of somebody's choosing, and takes it off the
    /// shelf once it is there.
    ///
    /// The shelf is a staging post — things land on it on the way somewhere — and "somewhere"
    /// was the one verb it did not have. A move, not a copy: leaving a second version behind
    /// is how a Downloads folder becomes what a Downloads folder becomes.
    func saveTo(_ urls: [URL]) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        // The panel is in the way of a sheet, and this app does not take focus on its own —
        // so it does now, once, for as long as the chooser is up.
        ActivityCenter.shared.collapse(reason: "filing what is on the shelf")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = files.count == 1
            ? "Where should \(files[0].lastPathComponent) go?"
            : "Where should these \(files.count) files go?"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        move(files, to: folder)
    }

    /// Moves each file, stepping around a name that is taken, and drops whatever arrived from
    /// the shelf. A file that will not move is left where it is and on the shelf, so nothing
    /// is ever lost between the two.
    func move(_ files: [URL], to folder: URL) {
        var moved: [URL] = []
        for file in files {
            let destination = Self.unusedURL(folder.appendingPathComponent(file.lastPathComponent))
            do {
                try FileManager.default.moveItem(at: file, to: destination)
                moved.append(file)
            } catch {
                IslandLog.island.error("could not move \(file.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !moved.isEmpty else { return announceMoveRefused() }
        // Off the shelf, but never into the Trash: they are somewhere else now, not gone.
        forget(moved)
        let custom = CustomActivity(title: moved.count == 1 ? "Moved" : "Moved \(moved.count) files",
                                    subtitle: folder.lastPathComponent,
                                    symbol: "folder.fill", tint: "blue",
                                    trailingText: folder.lastPathComponent)
        var alert = IslandActivity(id: "shelf-moved", kind: .custom, content: .custom(custom), priority: 80)
        alert.openAction = .url(folder)
        ActivityCenter.shared.showAlert(alert, duration: 2.5)
    }

    private func announceMoveRefused() {
        let custom = CustomActivity(title: "Could not move those", symbol: "exclamationmark.triangle.fill",
                                    tint: "orange", trailingText: "Failed")
        ActivityCenter.shared.showAlert(IslandActivity(id: "shelf-moved", kind: .custom,
                                                       content: .custom(custom), priority: 80),
                                        duration: 3)
    }

    /// Zips what is picked out and puts the archive on the shelf beside it.
    ///
    /// The one thing everybody does to a pile of files before sending them, and the reason
    /// half of those piles go to the Desktop first. Named after the file when there is one and
    /// after the folder they are in when there are several, the way Finder names its own.
    /// `ditto` rather than `zip`: it is what Finder's Compress uses, so resource forks and
    /// the extended attributes survive.
    ///
    /// `ditto` archives one thing and refuses more, so several files were never compressed at
    /// all: every one of them was handed to it at once, and the island said "Could not
    /// compress" every time. Several are gathered into a folder of their own first — cloned,
    /// on the same disk, so nothing is copied — and that folder's contents are archived, which
    /// is what Finder's own Archive.zip holds. The gathering is off the main thread.
    func compress(_ urls: [URL]) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        let destination = Self.archiveURL(for: files)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var staging: URL?
            if files.count > 1 {
                do {
                    staging = try Self.gather(files, near: destination)
                } catch {
                    IslandLog.island.error("could not gather the files to compress: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async { self?.announceCompressRefused() }
                    return
                }
            }
            // The gathered folder goes once `ditto` is done with it, whichever way that went.
            let gathered = staging
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = Self.dittoArguments(archiving: files, gatheredIn: gathered, to: destination)
            process.terminationHandler = { [weak self] task in
                if let gathered { try? FileManager.default.removeItem(at: gathered) }
                DispatchQueue.main.async {
                    guard task.terminationStatus == 0,
                          FileManager.default.fileExists(atPath: destination.path) else {
                        IslandLog.island.error("compress failed with \(task.terminationStatus, privacy: .public)")
                        self?.announceCompressRefused()
                        return
                    }
                    // Onto the shelf, but not as one of the island's own: an archive somebody
                    // asked for, sitting beside the files it was made from, is theirs. Clearing
                    // the shelf lets go of it and never deletes it.
                    self?.add([destination])
                }
            }
            do {
                try process.run()
            } catch {
                if let gathered { try? FileManager.default.removeItem(at: gathered) }
                IslandLog.island.error("could not compress: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { self?.announceCompressRefused() }
            }
        }
    }

    /// What `ditto` is asked to do: one thing to archive, and where the archive goes. One file
    /// is archived as itself; several — which `ditto` will not take — as the contents of the
    /// folder they were gathered into, so they unpack as themselves rather than inside a
    /// folder nobody made. Pure.
    static func dittoArguments(archiving files: [URL], gatheredIn staging: URL?, to destination: URL) -> [String] {
        var arguments = ["-c", "-k", "--sequesterRsrc"]
        if files.count > 1, let staging {
            arguments.append(staging.path)
        } else if let only = files.first {
            arguments += ["--keepParent", only.path]
        }
        return arguments + [destination.path]
    }

    /// The name each file has in the folder several are gathered into: its own, unless another
    /// already has it — two "Notes.txt" from two folders, or "notes.txt" beside it, since the
    /// disk does not tell the two apart — and then with a number after it, the way Finder
    /// steps around a name. Pure.
    static func gatheredNames(for files: [URL]) -> [String] {
        var taken = Set<String>()
        return files.map { file in
            let name = file.lastPathComponent
            let base = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            var candidate = name
            var n = 2
            while taken.contains(candidate.lowercased()) {
                candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                n += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
    }

    /// A fresh folder on the same disk as the archive, holding a copy of each file under the
    /// name `gatheredNames` gives it. The same disk makes each copy a clone, which costs no
    /// space and next to no time. Nothing is left behind when a copy fails.
    private static func gather(_ files: [URL], near destination: URL) throws -> URL {
        let manager = FileManager.default
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: destination.deletingLastPathComponent(), create: true)
        do {
            for (file, name) in zip(files, gatheredNames(for: files)) {
                try manager.copyItem(at: file, to: staging.appendingPathComponent(name))
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        return staging
    }

    /// Where the archive goes: beside the files when they share a folder that can be written
    /// to, and in the island's own folder when they do not.
    static func archiveURL(for files: [URL], fileManager: FileManager = .default) -> URL {
        let folder = files.count == 1 ? files[0].deletingLastPathComponent() : commonFolder(of: files)
        let base = files.count == 1
            ? files[0].deletingPathExtension().lastPathComponent
            : (folder?.lastPathComponent.isEmpty == false ? folder!.lastPathComponent : "Archive")
        let directory = folder.flatMap { fileManager.isWritableFile(atPath: $0.path) ? $0 : nil }
            ?? fileManager.temporaryDirectory
        return unusedURL(directory.appendingPathComponent(base + ".zip"), fileManager: fileManager)
    }

    /// The folder every one of them is in, when there is one.
    static func commonFolder(of files: [URL]) -> URL? {
        let folders = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard folders.count == 1, let only = folders.first else { return nil }
        return URL(fileURLWithPath: only, isDirectory: true)
    }

    /// The same name with a number after it, when the first one is taken. Bounded, so a folder
    /// full of them cannot spin.
    static func unusedURL(_ url: URL, fileManager: FileManager = .default, limit: Int = 50) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...limit {
            let candidate = folder.appendingPathComponent("\(base) \(n).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent("\(base) \(UUID().uuidString.prefix(6)).\(ext)")
    }

    private func announceCompressRefused() {
        let custom = CustomActivity(title: "Could not compress", symbol: "exclamationmark.triangle.fill",
                                    tint: "orange", trailingText: "Failed")
        ActivityCenter.shared.showAlert(IslandActivity(id: "shelf-compress", kind: .custom,
                                                       content: .custom(custom), priority: 80),
                                        duration: 3)
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func airDrop(_ urls: [URL]) {
        sendByAirDrop(urls)
    }

    /// `airDrop`, saying whether AirDrop took the files. False when there were none, or when
    /// this Mac cannot AirDrop right now — which the island has already said, with what is
    /// in the way. A file dropped straight on the well's AirDrop target goes on the shelf
    /// instead when this is false, so nothing dropped is ever simply lost.
    @discardableResult
    func sendByAirDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let objects: [Any] = urls
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: objects) else {
            // AirDrop wants Wi-Fi and Bluetooth switched on, and both of those switches are
            // on the rail this button sits on. Returning in silence made the button look
            // broken instead of pointing at the two things standing in its way.
            announceAirDropUnavailable()
            return false
        }
        // The AirDrop window takes the pointer off the island; keep the panel up and make
        // sure the picker gets focus even though this is a background app.
        ActivityCenter.shared.holdOpen(for: 30)
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: objects)
        return true
    }

    /// Files macOS would not put in the Trash.
    private func announceTrashRefused(_ count: Int) {
        guard publishesActivity else { return }
        let custom = CustomActivity(title: "Not moved to the Trash",
                                     subtitle: count == 1 ? "macOS would not move that file."
                                                          : "macOS would not move \(count) of them.",
                                     symbol: "trash.slash", tint: "orange")
        ActivityCenter.shared.showAlert(IslandActivity(id: "shelf-trash-refused", kind: .custom,
                                                       content: .custom(custom), priority: 85,
                                                       presentation: .expanded), duration: 4)
    }

    /// AirDrop asked for on a Mac that cannot do it at this moment.
    private func announceAirDropUnavailable() {
        guard publishesActivity else { return }
        let custom = CustomActivity(title: "AirDrop is not available",
                                     subtitle: "It needs Wi-Fi and Bluetooth switched on.",
                                     symbol: "dot.radiowaves.right", tint: "orange")
        ActivityCenter.shared.showAlert(IslandActivity(id: "shelf-airdrop", kind: .custom,
                                                       content: .custom(custom), priority: 85,
                                                       presentation: .expanded), duration: 3)
    }

    /// Share sheet anchored to an AppKit view. With no view (or no window) we fall back to
    /// AirDrop, which is the shelf's most common destination anyway.
    func share(_ urls: [URL], from view: NSView? = nil, rect: NSRect = .zero) {
        guard !urls.isEmpty else { return }
        guard let view, view.window != nil else {
            airDrop(urls)
            return
        }
        let objects: [Any] = urls
        let picker = NSSharingServicePicker(items: objects)
        picker.delegate = sharingRelay
        sharingPicker = picker
        let anchor = rect == .zero ? view.bounds : rect
        ActivityCenter.shared.holdOpen(for: 30)
        NSApp.activate(ignoringOtherApps: true)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    /// The picker was chosen from, or dismissed. Let go of on the next turn, not inside its
    /// own callback: a chosen service is still being handed the files when it says so.
    private func sharingFinished(_ picker: NSSharingServicePicker) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sharingPicker === picker else { return }
            self.sharingPicker = nil
        }
    }

    /// What a file will paste as, which decides what else goes on the pasteboard beside it.
    enum CopyKind { case text, image, file }

    static func copyKind(of url: URL) -> CopyKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        // A .webloc is a link, and its file is a plist: pasting the plist as text would be
        // nonsense, so it counts as a file and the URL inside it is added separately.
        if type.conforms(to: .text), !type.conforms(to: .internetShortcut) { return .text }
        return .file
    }

    /// Copies the shelf's files so a paste does the right thing wherever it lands.
    ///
    /// The file itself always goes on the pasteboard, so ⌘V in Finder makes a copy. A single
    /// text file also puts its text there, an image its picture and a link its address, so
    /// the same ⌘V in a text field, an image editor or a browser pastes what the file *is*
    /// rather than a copy of it. Reading a file to copy it happens off the main thread.
    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        announceCopy(count: urls.count)
        // Several files, or one whose content is not worth carrying: the file references are
        // all there is to write, and it can be written at once.
        guard urls.count == 1, let url = urls.first, Self.mightHaveExtras(url) else {
            Self.write(urls, extras: nil)
            return
        }
        // Reading and decoding a file belongs off the main thread; the pasteboard is then
        // written once, a few milliseconds later, with everything on it.
        DispatchQueue.global(qos: .userInitiated).async {
            let extras = Self.pasteboardExtras(for: url)
            DispatchQueue.main.async { Self.write([url], extras: extras) }
        }
    }

    /// Puts files on the pasteboard, with a single file's content beside it where there is
    /// any: one item carrying several representations, so the reader picks the one it
    /// understands and the same copy pastes as a file in Finder and as its content elsewhere.
    private static func write(_ urls: [URL], extras: [(NSPasteboard.PasteboardType, Data)]?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard let extras, !extras.isEmpty, urls.count == 1, let url = urls.first else {
            pasteboard.writeObjects(urls.map { $0 as NSURL })
            return
        }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        for (type, data) in extras { item.setData(data, forType: type) }
        pasteboard.writeObjects([item])
    }

    /// Whether a file has anything beside itself worth putting on the pasteboard.
    static func mightHaveExtras(_ url: URL) -> Bool {
        switch copyKind(of: url) {
        case .text, .image: return true
        case .file: return url.pathExtension.lowercased() == "webloc"
        }
    }

    /// The extra representations of a file: its text, its picture, or the address inside a
    /// `.webloc`. Nil for anything too big to hold in the pasteboard. Reads and decodes a
    /// file, so it is called from a background queue.
    static func pasteboardExtras(for url: URL, limit: Int = 8 * 1024 * 1024) -> [(NSPasteboard.PasteboardType, Data)]? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limit else { return nil }
        switch copyKind(of: url) {
        case .text:
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                  let utf8 = text.data(using: .utf8) else { return nil }
            return [(.string, utf8)]
        case .image:
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation else { return nil }
            var result: [(NSPasteboard.PasteboardType, Data)] = [(.tiff, tiff)]
            if let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                result.append((.png, png))
            }
            return result
        case .file:
            guard url.pathExtension.lowercased() == "webloc",
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                  let address = plist["URL"], let utf8 = address.data(using: .utf8) else { return nil }
            return [(.string, utf8)]
        }
    }

    /// The island's own "Copied" nod, so a copy from the shelf is as visible as one from the
    /// clipboard section.
    private func announceCopy(count: Int) {
        Haptics.tap()
        guard publishesActivity else { return }
        let title = count == 1 ? "Copied" : "Copied \(count) files"
        let activity = IslandActivity(id: "shelf-copied", kind: .custom,
                                      content: .custom(CustomActivity(title: title, symbol: "doc.on.doc",
                                                                      trailingText: "Copied")),
                                      priority: 80)
        ActivityCenter.shared.showAlert(activity, duration: 1.0, haptic: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            if ActivityCenter.shared.alert?.id == activity.id { ActivityCenter.shared.dismissAlert() }
        }
    }

    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        remove(urls)
        // `remove` has already trashed anything the island wrote; trashing it twice would
        // leave the second attempt logging a failure about a file that is already gone.
        let theirs = urls.filter { !Self.isOwned($0) }
        guard !theirs.isEmpty else { return }
        // Trashing can block on iCloud or network volumes; never do it on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            var refused = 0
            for url in theirs {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    refused += 1
                    IslandLog.store.error("could not trash \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
            // The tile has already gone from the shelf, so a file macOS refused to move —
            // locked, on a read-only volume, already elsewhere — would otherwise look
            // trashed and not be.
            if refused > 0 {
                DispatchQueue.main.async { [weak self] in self?.announceTrashRefused(refused) }
            }
        }
    }

    // MARK: - Drops

    /// What the island will take: a file, a picture, a link, or a piece of text. Everything
    /// that is not already a file is written into `dropFolder` first, so the shelf always
    /// holds files and anything on it can be dragged straight into another app.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .url, .text]

    static let shelfSubdirectory = "Shelf"

    /// Where text, pictures and links dropped on the island are kept: inside the app's own
    /// folder, so nothing lands in the user's Downloads without asking, and inside the *same*
    /// one as everything else it remembers. It used to write to "Notch Island/Shelf" while
    /// the clipboard, the notes and the lyrics went to "MacNotchIsland" — two Application
    /// Support folders for one app, and deleting the one with the app's name on it left the
    /// other behind full of the user's files.
    static var dropFolder: URL {
        IslandFiles.folder?.appendingPathComponent(shelfSubdirectory, isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(shelfSubdirectory, isDirectory: true)
    }

    /// The folder an earlier build wrote to. Anything still sitting in it is still this app's
    /// to tidy up when it leaves the shelf, so it counts as owned; nothing new goes there.
    static var legacyDropFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Notch Island/Shelf", isDirectory: true)
    }

    /// True for a file this app made from a drop. Those are ours to delete when they leave the
    /// shelf; a file the user dropped from Finder is never touched.
    static func isOwned(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return [dropFolder, legacyDropFolder].contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// SwiftUI `.onDrop` handler. Each provider is asked for the best thing it has, in the
    /// order a person would expect: the file itself, then a picture, then a link, then text.
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter { provider in
            Self.acceptedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        guard !usable.isEmpty else { return false }
        let group = DispatchGroup()
        // Kept in the order they were dragged. Appending as each provider answers puts them
        // on the shelf in whatever order the answers came back, which for a pile of files
        // dragged together is no order at all.
        var collected = [URL?](repeating: nil, count: usable.count)
        let lock = NSLock()
        for (index, provider) in usable.enumerated() {
            group.enter()
            Self.url(from: provider) { url in
                lock.lock(); collected[index] = url; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let files = collected.compactMap { $0 }
            // A drag can advertise a kind and then refuse to hand it over. The shelf took the
            // drop, the island lit up for it, and nothing arrived — so it says so, rather than
            // letting the highlight simply go out and leave somebody wondering where the file
            // went.
            if files.isEmpty { self?.announceNothingTaken() } else { self?.add(files) }
            ActivityCenter.shared.setDragTargeted(false)
        }
        return true
    }

    /// A drop the shelf accepted and could make nothing of.
    private func announceNothingTaken() {
        guard publishesActivity else { return }
        // As the card, not the pill: somebody is looking straight at the island, having just
        // let go over it, and the sentence is the whole point of the alert.
        let custom = CustomActivity(title: "Nothing to keep",
                                     subtitle: "That drag carried nothing the shelf could take.",
                                     symbol: "tray", tint: "orange")
        ActivityCenter.shared.showAlert(IslandActivity(id: "shelf-drop-empty", kind: .custom,
                                                       content: .custom(custom), priority: 80,
                                                       presentation: .expanded),
                                        duration: 2.5)
    }

    /// The picture formats a drag can carry, best first.
    private static let imageTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .gif, .image]
    /// The same for text: concrete first, because a provider that advertises "some text" does
    /// not always answer to that name.
    private static let textTypes: [UTType] = [.utf8PlainText, .plainText, .rtf, .text]

    /// The file a provider stands for: its own, or one written for it.
    ///
    /// The kinds are tried in the order a person would expect — the file, then a picture, then
    /// a link, then text — and a kind that is advertised but cannot be read falls through to
    /// the next rather than ending the drop. A web page's drag often carries all four.
    private static func url(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        file(from: provider) { url in
            if let url { return completion(url) }
            image(from: provider) { url in
                if let url { return completion(url) }
                link(from: provider) { url in
                    if let url { return completion(url) }
                    text(from: provider, completion: completion)
                }
            }
        }
    }

    private static func file(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return completion(nil) }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            completion(fileURL(from: item))
        }
    }

    /// Ask for a concrete kind of picture rather than the abstract one: a provider that
    /// advertises "an image" does not always hand one over when asked in those terms.
    private static func image(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        guard let type = imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            return completion(nil)
        }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let image = NSImage(data: data), image.size.width > 1 else { return completion(nil) }
            completion(write(image: image, suggested: provider.suggestedName))
        }
    }

    private static func link(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return completion(nil) }
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
            guard let url = webURL(from: item) else { return completion(nil) }
            completion(write(link: url))
        }
    }

    private static func text(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        guard let type = textTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            return completion(nil)
        }
        provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
            var text: String?
            if let string = item as? String { text = string }
            else if let data = item as? Data { text = String(data: data, encoding: .utf8) }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return completion(nil) }
            completion(write(text: text))
        }
    }

    /// The file a provider handed over, whichever of the three shapes it used. Internal
    /// because the Actions row decodes a drop the same way.
    static func fileURL(from item: Any?) -> URL? {
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let url = item as? URL { return url }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private static func webURL(from item: Any?) -> URL? {
        if let url = item as? URL, !url.isFileURL { return url }
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), !url.isFileURL { return url }
        if let string = item as? String, let url = URL(string: string), url.scheme != nil { return url }
        return nil
    }

    /// The name a drop is written under on its `attempt`th try: its own name made fit for a
    /// file, and from the second try on a number after it — "Note.txt", then "Note 2.txt". The
    /// second try is only ever made because the first name was taken by the time the file went
    /// in. Pure.
    ///
    /// At most sixty characters of its own, and never more than `nameByteLimit` bytes in all.
    /// The file system's limit is on bytes, not characters — 255 of them, counted in the
    /// decomposed form a Mac file name is compared in — and sixty characters were only ever
    /// short enough for a name in Latin letters. A Korean syllable is two or three letters once
    /// decomposed, six to nine bytes, and Devanagari and Tamil come to much the same, so the
    /// first line of a note in any of them made a name the write refused, and the drop was
    /// lost. Cut a whole character at a time, so no letter is left in pieces.
    static func dropFileName(_ name: String, extension ext: String, attempt: Int) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        var base = safe.isEmpty ? "Dropped" : String(safe.prefix(60))
        let tail = (attempt <= 1 ? "" : " \(attempt)") + ".\(ext)"
        while base.count > 1, fileNameBytes(base + tail) > nameByteLimit { base.removeLast() }
        // One character can still be too long: a letter under hundreds of combining marks.
        if fileNameBytes(base + tail) > nameByteLimit { base = "Dropped" }
        return base + tail
    }

    /// The room a drop's whole name is given, its number and extension included: the file
    /// system's 255 bytes, with a few to spare.
    static let nameByteLimit = 250

    /// A name's length as the file system counts it: bytes of UTF-8, decomposed. Pure.
    static func fileNameBytes(_ name: String) -> Int {
        name.decomposedStringWithCanonicalMapping.utf8.count
    }

    /// Writes what a drop carried as a new file inside `dropFolder`, with the folder made if it
    /// is not there yet.
    ///
    /// Never over another file, and never half of one. The name used to be looked for first and
    /// written to after, while every item of a drag is read at once: two links to one site both
    /// found "github.com.webloc" free, both wrote it, and the shelf held one file twice with the
    /// other link gone. `IslandFiles.writeNew` takes the name and the file in one step, and puts
    /// nothing under it until every byte is down.
    private static func place(_ data: Data, name: String, extension ext: String, what: String) -> URL? {
        // Made through `IslandFiles`, which shuts the folder to every other account: what
        // somebody drops on the island is theirs.
        guard let folder = IslandFiles.makeFolder(shelfSubdirectory) else {
            IslandLog.store.error("could not make the drop folder")
            return nil
        }
        do {
            return try IslandFiles.writeNew(data, in: folder) { attempt in
                dropFileName(name, extension: ext, attempt: attempt)
            }
        } catch {
            IslandLog.store.error("could not write the dropped \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The stamp that keeps one drop apart from the next: "Image 14.32.05". Pure, given `now`
    /// and `timeZone`.
    ///
    /// In the POSIX locale, as every other name the app writes a time into is: a file name is
    /// not prose. Without it the format was read in the Mac's own language — Eastern Arabic
    /// figures on a Mac in Arabic, and "HH" given twelve hours where the clock is set to them.
    static func stamp(_ kind: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH.mm.ss"
        return "\(kind) \(formatter.string(from: now))"
    }

    static func write(image: NSImage, suggested: String?) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = (suggested?.isEmpty == false ? (suggested! as NSString).deletingPathExtension : stamp("Image"))
        return place(png, name: name, extension: "png", what: "image")
    }

    static func write(text: String) -> URL? {
        // The first line names the file, the way Notes titles a note.
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let name = firstLine.trimmingCharacters(in: .whitespaces).isEmpty ? stamp("Text") : firstLine
        return place(Data(text.utf8), name: name, extension: "txt", what: "text")
    }

    /// A dropped link becomes a `.webloc`, which is what Finder makes and what every browser
    /// opens with a double click.
    static func write(link: URL) -> URL? {
        let name = link.host ?? stamp("Link")
        let plist: Data
        do {
            plist = try PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString],
                                                       format: .xml, options: 0)
        } catch {
            IslandLog.store.error("could not write the dropped link: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return place(plist, name: name, extension: "webloc", what: "link")
    }

    // MARK: - Persistence

    private static func load(from defaults: UserDefaults, key: String) -> [ShelfItem] {
        // Current format: [["path": String, "addedAt": Date]]
        if let raw = defaults.array(forKey: key) as? [[String: Any]] {
            return raw.compactMap { (entry: [String: Any]) -> ShelfItem? in
                guard let path = entry["path"] as? String, !path.isEmpty else { return nil }
                let added = entry["addedAt"] as? Date ?? Date()
                return ShelfItem(url: URL(fileURLWithPath: path).standardizedFileURL, addedAt: added)
            }
        }
        // Legacy format: a plain array of paths. Treat them as added now so an upgrade
        // doesn't sweep the whole shelf away on first launch.
        if let paths = defaults.stringArray(forKey: key) {
            let now = Date()
            return paths.compactMap { (path: String) -> ShelfItem? in
                guard !path.isEmpty else { return nil }
                return ShelfItem(url: URL(fileURLWithPath: path).standardizedFileURL, addedAt: now)
            }
        }
        return []
    }

    private func persist() {
        let encoded: [[String: Any]] = items.map { ["path": $0.url.path, "addedAt": $0.addedAt] }
        defaults.set(encoded, forKey: key)
    }

    // MARK: - Thumbnails

    private func pruneThumbnailCache() {
        let live = Set(items.map(\.url))
        thumbnails = thumbnails.filter { live.contains($0.key) }
        thumbnailQueue.removeAll { !live.contains($0) }
    }

    private func requestThumbnail(_ url: URL) {
        guard backgroundWork, thumbnails[url] == nil, !thumbnailQueue.contains(url) else { return }
        thumbnailQueue.append(url)
        pumpThumbnails()
    }

    /// Never keeps more than a handful of QuickLook requests in flight, so a big drop can't
    /// spike the CPU.
    private func pumpThumbnails() {
        while thumbnailsInFlight < Self.maxConcurrentThumbnails, !thumbnailQueue.isEmpty {
            let url = thumbnailQueue.removeFirst()
            guard thumbnails[url] == nil else { continue }
            thumbnailsInFlight += 1
            let request = QLThumbnailGenerator.Request(fileAt: url,
                                                       size: CGSize(width: 88, height: 88),
                                                       scale: 2,
                                                       representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.thumbnailsInFlight = max(0, self.thumbnailsInFlight - 1)
                    if let rep, self.items.contains(where: { $0.url == url }) {
                        self.thumbnails[url] = rep.nsImage
                    }
                    self.pumpThumbnails()
                }
            }
        }
    }
}

/// Hears the share picker finish, for `ShelfStore`, which is not an `NSObject` and so cannot be
/// the picker's delegate itself. A choice and a dismissal arrive the same way: with the service
/// the files went to, or with nil.
private final class SharingPickerRelay: NSObject, NSSharingServicePickerDelegate {
    private let finished: (NSSharingServicePicker) -> Void

    init(finished: @escaping (NSSharingServicePicker) -> Void) {
        self.finished = finished
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        finished(sharingServicePicker)
    }
}
