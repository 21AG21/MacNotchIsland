import AppKit
import ApplicationServices
import Combine
import ImageIO
import UniformTypeIdentifiers

/// One entry in the clipboard history.
///
/// `text` carries the payload for every kind: the copied string, the absolute URL, the
/// newline-separated file paths, or a short label for images (whose bytes live in
/// `imageData` and are deliberately never written to disk).
struct ClipboardItem: Identifiable, Equatable, Codable {

    enum Kind: String, Codable {
        case text, url, file, image

        /// SF Symbol shown at the leading edge of a row.
        var symbol: String {
            switch self {
            case .text: return "doc.text"
            case .url: return "link"
            case .file: return "doc"
            case .image: return "photo"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind = .text
    var text: String
    var date: Date = Date()
    /// Pinned items are never dropped when the ring buffer overflows.
    var pinned: Bool = false
    /// PNG bytes for `.image` items. Excluded from `CodingKeys`: images stay in memory only.
    var imageData: Data? = nil
    /// The app that was in front when this was copied — as good a guess at where it came from
    /// as the pasteboard allows, and the thing that makes a list of fifty snippets searchable
    /// by memory rather than by reading all of them.
    var app: String? = nil

    private enum CodingKeys: String, CodingKey { case id, kind, text, date, pinned, app }

    /// Whether this entry is something a drag could carry. Cheap enough to ask on every pass
    /// of a fifty-row list: nothing here touches the disk.
    var canDrag: Bool {
        switch kind {
        case .text, .url: return !text.isEmpty
        case .file: return !fileURLs.isEmpty
        case .image: return imageData != nil
        }
    }

    /// The entry as a drag can carry it into another app — the text, the link, the file
    /// itself, or the picture. Dragging one out is the other half of clicking one, which puts
    /// it back on the pasteboard.
    func dragProvider() -> NSItemProvider? {
        switch kind {
        case .text:
            return NSItemProvider(object: text as NSString)
        case .url:
            // A link that will not parse is still text somebody copied.
            guard let url = URL(string: text) else { return NSItemProvider(object: text as NSString) }
            return NSItemProvider(object: url as NSURL)
        case .file:
            guard let url = fileURLs.first else { return nil }
            return NSItemProvider(contentsOf: url)
        case .image:
            guard let data = imageData else { return nil }
            let provider = NSItemProvider()
            provider.suggestedName = "Image.png"
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
    }

    /// File URLs for a `.file` item (empty for every other kind).
    var fileURLs: [URL] {
        guard kind == .file else { return [] }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// Single-line summary for a row.
    var preview: String {
        switch kind {
        case .file:
            let names = fileURLs.map { $0.lastPathComponent }
            guard let first = names.first else { return text }
            return names.count > 1 ? "\(first) + \(names.count - 1) more" : first
        case .image:
            return text.isEmpty ? "Image" : text
        case .text, .url:
            let line = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        }
    }

    /// Compact relative age: "now", "4m", "3h", "2d".
    func age(at now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

/// What one pasteboard change looks like, already read out of `NSPasteboard`. Keeping this
/// a plain value lets the capture rules be unit-tested without a real pasteboard.
struct ClipboardSnapshot {
    var types: [String] = []
    var text: String? = nil
    var fileURLs: [URL] = []
    var imageData: Data? = nil
    var imagePixelSize: CGSize? = nil
    /// A picture offered only as TIFF, not yet turned into the PNG the history keeps. Read out
    /// of the pasteboard on the main thread and converted on the store's `converter` queue, see
    /// `ClipboardStore.finishingImage`.
    var tiffData: Data? = nil
}

/// Clipboard history: polls `NSPasteboard.general` for changes, keeps a small ring buffer of
/// what was copied, and can put any entry back on the pasteboard.
///
/// The poll interval follows `EnergyPolicy` (0.4 s on wall power, up to 3.2 s asleep) and a
/// tick that finds an unchanged `changeCount` does no work at all, so the idle cost is a
/// timer wake-up and one integer compare.
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipboardItem] = []
    @Published private var thumbnails: [UUID: NSImage] = [:]
    /// The entries whose files have all gone, as of the last sweep. Kept here, keyed by the
    /// entry's own id, because the row that shows it is redrawn far more often than the answer
    /// can possibly change.
    @Published private var missingFileIDs: Set<UUID> = []

    /// The stamps a copy can carry that say a history must not keep it.
    ///
    /// All three of the ones nspasteboard.org defines, not two: `ConcealedType` is what a
    /// password manager puts on a password, `TransientType` is for something meant to live a
    /// moment, and `AutoGeneratedType` is what a tool puts on a copy it made rather than a
    /// person — which is exactly the kind a history should not fill up with. Leaving the third
    /// out meant recording work that was never anybody's to keep.
    static let concealedTypeIdentifiers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    /// Very large copies are clipped so history can't pin megabytes in memory.
    static let maxTextLength = 100_000

    /// How many bytes of pictures the history holds between them. A picture is kept whole, at
    /// full resolution, for as long as it is in the list — a Retina screenshot is ten or twenty
    /// megabytes of PNG — and with fifty entries allowed, nothing stopped a morning of copied
    /// screenshots from holding a gigabyte. Past this, the oldest pictures go; see
    /// `withinImageBudget`.
    static let imageBudget = 64 << 20

    private static let basePollInterval: TimeInterval = 0.4
    private static let fileName = "clipboard.json"

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var lastChangeCount = 0
    private var running = false
    private var cancellables = Set<AnyCancellable>()
    private var persistWork: DispatchWorkItem?
    private var pendingThumbnails: Set<UUID> = []
    /// The TIFF half of the last picture put back on the pasteboard, still only promised. Held
    /// here as well as by the pasteboard item, so it is there for as long as the entry is.
    private var tiffPromise: TIFFPromise?
    /// Whether what is on disk has been read back yet.
    private var hasLoaded = false
    /// Set when a history on disk that could not be read could not be moved aside either.
    /// Nothing is written over it for the rest of the run. See `IslandFiles.readBack`.
    private var heldBack = false
    /// Watches "Keep history across relaunches" for as long as the app runs, not only while
    /// the clipboard is recording: switching it off has to take the file with it either way.
    private var persistence: AnyCancellable?
    /// Where the history is written and erased, and nothing else. One queue, in order, so an
    /// erase can never be overtaken by a write that was already on its way.
    private static let io = DispatchQueue(label: "com.macnotchisland.clipboard.io", qos: .utility)
    /// Where a copy is made ready to keep (`finishingImage`). Its own queue, not `io`: `flush`
    /// waits on `io` from quit, sleep and power-off, and it must wait for the disk, not for a
    /// 5K TIFF on its way to a PNG that is never written to disk anyway.
    private static let converter = DispatchQueue(label: "com.macnotchisland.clipboard.convert", qos: .utility)
    /// Copies through `converter` and not yet in the list, oldest first.
    private let arrivals = Arrivals()

    /// Fills the history for the rendered gallery, which starts with an empty pasteboard.
    /// Does nothing outside the gallery.
    func seedForGallery(_ items: [ClipboardItem]) {
        guard RenderMode.isGallery else { return }
        self.items = items
        // The gallery's history is the whole of its history; nothing on disk may land on top
        // of it later, and no Clear from an earlier scene is waiting to be taken back.
        hasLoaded = true
        forgetUndo()
        refreshMissingFiles()
    }

    private init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Reads the history back from disk, once. Harmless to ask twice.
    ///
    /// Kept out of `init` on purpose, because the two happen at different moments for a
    /// reason. A second launch asks the copy already running to quit, and that copy writes its
    /// history — everything copied in its last few seconds — on the way out. The whole history
    /// is one file, rewritten whole, so a new copy that had read it before that write landed
    /// would put it back afterwards with those seconds missing, and both files would look
    /// perfectly well-formed. The delegate says when the older copy has gone.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        watchPersistence()
        // Read back only while the history is kept across relaunches. Otherwise — which is how
        // it ships — a file left behind by a build that always wrote one, or from before the
        // switch went off, is erased rather than read back and carried on with.
        guard Preferences.shared.clipboardPersists else {
            Self.erasePersisted()
            return
        }
        switch Self.readHistory() {
        case .value(let kept):
            items = kept
        case .missing, .unreadable(.moved(_)):
            break
        case .unreadable(.stuck):
            heldBack = true
            // A write scheduled before the read did not know to hold back.
            persistWork?.cancel()
            persistWork = nil
        }
    }

    private func watchPersistence() {
        guard persistence == nil else { return }
        persistence = Preferences.shared.$clipboardPersists
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] keeps in self?.persistenceChanged(keeps) }
    }

    /// Switched on, what is in memory is written now rather than at the next copy. Switched
    /// off, anything on its way to the disk is stopped and the file goes.
    private func persistenceChanged(_ keeps: Bool) {
        if keeps {
            if !items.isEmpty { schedulePersist() }
        } else {
            persistWork?.cancel()
            persistWork = nil
            Self.erasePersisted()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        // Before the first `changeCount` is read, and so before anything can be captured: a
        // capture into an empty history would be saved as the whole of it.
        loadIfNeeded()
        // Whatever is already on the pasteboard at launch is not a new copy.
        lastChangeCount = pasteboard.changeCount
        EnergyPolicy.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rescheduleTimer() }
            .store(in: &cancellables)
        // "Items kept" is what is kept now, not what the next copy will trim to: lowering it
        // used to change nothing until something else was copied. The first value arrives
        // here too, for a limit lowered while the clipboard was off.
        Preferences.shared.$clipboardLimit
            .receive(on: RunLoop.main)
            .sink { [weak self] limit in self?.trim(to: limit) }
            .store(in: &cancellables)
        rescheduleTimer()
        // The history was read back from disk before any of it was drawn, and the files it
        // points at may not have survived the time the app was shut.
        refreshMissingFiles()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        timerInterval = 0
        cancellables.removeAll()
    }

    private var pollInterval: TimeInterval {
        ClipboardStore.basePollInterval * max(1, EnergyPolicy.shared.pollingMultiplier)
    }

    /// Re-creates the poll timer whenever the energy policy asks for a different cadence.
    private func rescheduleTimer() {
        guard running else { return }
        let interval = pollInterval
        guard timer == nil || abs(interval - timerInterval) > 0.01 else { return }
        timer?.invalidate()
        timerInterval = interval
        let scheduled = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        scheduled.tolerance = interval * 0.3
        timer = scheduled
    }

    /// Reads what changed on the main thread, where the pasteboard and the frontmost app are,
    /// and does everything a picture costs on `converter`.
    ///
    /// Every copy takes the same road, text included, so a picture still being converted is
    /// never overtaken by the line of text copied just after it: `converter` is serial, and
    /// `arrivals` hands them over in the order they came off it, so entries land in the order
    /// they were copied. For text the detour is a hop and nothing more.
    private func tick() {
        guard running else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let snapshot = readSnapshot()
        let app = Self.frontmostAppName()
        let date = Date()
        let arrivals = self.arrivals
        Self.converter.async {
            guard let item = ClipboardStore.item(from: ClipboardStore.finishingImage(snapshot), date: date, app: app) else { return }
            arrivals.add(item)
            DispatchQueue.main.async { [weak self] in self?.takeArrivals() }
        }
    }

    /// Puts every copy that has come through `converter` into the list, oldest first. Main
    /// thread: from the hop each copy makes once it is through, and from `flush`, which cannot
    /// wait for that hop — at quit it is queued behind `terminate` and never runs.
    private func takeArrivals() {
        let arrived = arrivals.takeAll()
        // Switched off while the picture was being converted: it was never recorded.
        guard running else { return }
        for item in arrived { append(item) }
    }

    /// The hand-over between `converter` and the main thread: a copy is added the moment it is
    /// ready and taken by whichever comes first, its own hop or a `flush`. In order, and each
    /// copy taken once. Safe from any thread.
    final class Arrivals {
        private let lock = NSLock()
        private var waiting: [ClipboardItem] = []

        func add(_ item: ClipboardItem) {
            lock.lock()
            waiting.append(item)
            lock.unlock()
        }

        /// Everything added since the last call, oldest first.
        func takeAll() -> [ClipboardItem] {
            lock.lock()
            defer { lock.unlock() }
            let taken = waiting
            waiting.removeAll()
            return taken
        }
    }

    // MARK: - Reading the pasteboard

    private func readSnapshot() -> ClipboardSnapshot {
        var snapshot = ClipboardSnapshot()
        snapshot.types = (pasteboard.types ?? []).map { $0.rawValue }
        guard !ClipboardStore.isConcealed(types: snapshot.types) else { return snapshot }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            snapshot.fileURLs = urls.filter { $0.isFileURL }
        }
        snapshot.text = pasteboard.string(forType: .string)

        let hasText = !(snapshot.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Spreadsheets put a picture of the selection next to the text; text wins. Only the
        // bytes are read here: turning a TIFF into PNG, and finding out how big it is, are
        // `finishingImage`'s job, on `io`.
        if snapshot.fileURLs.isEmpty && !hasText {
            if let png = pasteboard.data(forType: .png) {
                snapshot.imageData = png
            } else {
                snapshot.tiffData = pasteboard.data(forType: .tiff)
            }
        }
        return snapshot
    }

    // MARK: - Pictures, off the main thread

    /// A snapshot with its picture made ready to keep: a TIFF turned into PNG, and the size
    /// read out of the file's header. On `converter`.
    ///
    /// Both used to happen on the main thread on every picture copied — the TIFF re-encoded,
    /// and then the whole PNG decoded into a bitmap for no reason but to ask it how wide it
    /// was. A 5K screenshot is a hundred-odd megabytes of pixels to count two numbers from.
    /// The size is in the header, and ImageIO reads it without drawing a pixel. Bytes that are
    /// not a picture ImageIO can read are not recorded as one, as before.
    static func finishingImage(_ snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        var done = snapshot
        if done.imageData == nil, let tiff = done.tiffData { done.imageData = pngData(fromTIFF: tiff) }
        done.tiffData = nil
        guard let png = done.imageData else { return done }
        guard let size = pixelSize(of: png) else {
            done.imageData = nil
            done.imagePixelSize = nil
            return done
        }
        if done.imagePixelSize == nil { done.imagePixelSize = size }
        return done
    }

    /// How big a picture is, from its header alone: nothing is decoded.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// A TIFF, as the PNG the history keeps. Through ImageIO, which is safe on any thread.
    static func pngData(fromTIFF tiff: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    // MARK: - Pure capture rules (unit-tested)

    static func isConcealed(types: [String]) -> Bool {
        types.contains { concealedTypeIdentifiers.contains($0) }
    }

    static func isURL(_ text: String, types: [String] = []) -> Bool {
        guard !text.isEmpty, text.count < 2048 else { return false }
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        if ["http", "https", "ftp", "ftps", "mailto", "file"].contains(scheme) { return true }
        return types.contains("public.url")
    }

    /// Turns one pasteboard change into an item, or nothing when it should not be recorded.
    static func item(from snapshot: ClipboardSnapshot, date: Date = Date(),
                     app: String? = nil) -> ClipboardItem? {
        guard !isConcealed(types: snapshot.types) else { return nil }

        if !snapshot.fileURLs.isEmpty {
            let paths = snapshot.fileURLs.map { $0.path }.joined(separator: "\n")
            return ClipboardItem(kind: .file, text: paths, date: date, app: app)
        }

        let raw = snapshot.text ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if isURL(trimmed, types: snapshot.types) {
                return ClipboardItem(kind: .url, text: trimmed, date: date, app: app)
            }
            return ClipboardItem(kind: .text, text: String(raw.prefix(maxTextLength)), date: date, app: app)
        }

        if let data = snapshot.imageData {
            var label = "Image"
            if let size = snapshot.imagePixelSize, size.width > 1, size.height > 1 {
                label = "Image \(Int(size.width)) × \(Int(size.height))"
            }
            return ClipboardItem(kind: .image, text: label, date: date, imageData: data, app: app)
        }
        return nil
    }

    /// The app the copy most likely came from: whichever was in front when the pasteboard
    /// changed. Never this one — reading the pasteboard does not change it, but putting an
    /// entry *back* does, and the island must not sign its own name to somebody's snippet.
    static func frontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app.localizedName
    }

    /// Ring-buffer insert: collapses a repeat of the newest entry, then drops the oldest
    /// unpinned entries until the list fits. Pinned entries are never dropped.
    static func inserting(_ item: ClipboardItem, into items: [ClipboardItem], limit: Int) -> [ClipboardItem] {
        var result = items
        if let newest = result.first, newest.kind == item.kind, newest.text == item.text,
           newest.imageData == item.imageData {
            result[0].date = item.date
            return result
        }
        result.insert(item, at: 0)
        return capped(result, limit: limit)
    }

    /// Drops the oldest unpinned entries until the list fits, in count and in the bytes its
    /// pictures take. Pinned entries are never dropped, and nor is the newest.
    static func capped(_ items: [ClipboardItem], limit: Int, imageBudget: Int = ClipboardStore.imageBudget) -> [ClipboardItem] {
        var result = items
        let cap = max(1, limit)
        var index = result.count - 1
        while result.count > cap && index > 0 {
            if !result[index].pinned { result.remove(at: index) }
            index -= 1
        }
        return withinImageBudget(result, budget: imageBudget)
    }

    /// Whether a picture of `bytes` can be kept beside the `keptImageBytes` already kept.
    static func imageFits(bytes: Int, keptImageBytes: Int, budget: Int = ClipboardStore.imageBudget) -> Bool {
        keptImageBytes + bytes <= budget
    }

    /// The list with its oldest pictures gone, past the point where they stop fitting the
    /// budget: counted from the newest, the first unpinned picture that does not fit goes, and
    /// every unpinned picture older than it goes too, the way the ring buffer drops from the
    /// old end rather than picking holes in the middle. Text, links and files cost nothing
    /// here and are never touched. The newest entry stays whatever it weighs — it is the copy
    /// somebody made a moment ago — and so does a pinned picture, which counts against the
    /// budget all the same.
    static func withinImageBudget(_ items: [ClipboardItem], budget: Int = ClipboardStore.imageBudget) -> [ClipboardItem] {
        var kept = 0
        var over = false
        var result: [ClipboardItem] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard let bytes = item.imageData?.count else {
                result.append(item)
                continue
            }
            if index == 0 || item.pinned {
                kept += bytes
                result.append(item)
            } else if !over, imageFits(bytes: bytes, keptImageBytes: kept, budget: budget) {
                kept += bytes
                result.append(item)
            } else {
                over = true
            }
        }
        return result
    }

    /// "Items kept" as a count. A figure edited into defaults by hand that is not a number
    /// at all would otherwise stop the app on the conversion.
    static func itemLimit(_ value: Double) -> Int {
        guard value.isFinite else { return 50 }
        return Int(min(max(value, 1), 10_000).rounded())
    }

    // MARK: - Mutation

    private func append(_ item: ClipboardItem) {
        let limit = Self.itemLimit(Preferences.shared.clipboardLimit)
        let updated = ClipboardStore.inserting(item, into: items, limit: limit)
        guard updated != items else { return }
        items = updated
        pruneThumbnails()
        refreshMissingFiles()
        schedulePersist()
    }

    /// Brings the history down to a lowered "Items kept" straight away.
    private func trim(to limit: Double) {
        let kept = Self.capped(items, limit: Self.itemLimit(limit))
        guard kept != items else { return }
        items = kept
        pruneThumbnails()
        refreshMissingFiles()
        schedulePersist()
    }

    /// Pastes into whatever the user was working in, a moment after the island has handed the
    /// keyboard back. Needs the Accessibility permission to synthesise the keystroke; without
    /// it the item is simply on the pasteboard, ready for a ⌘V of the user's own.
    /// The wait is a little longer than the island's own hand-back of key status
    /// (`NotchPanel.keyReleaseDelay`), so the keystroke can never land on the island itself.
    static func pasteIntoFrontmostApp(after delay: TimeInterval = 0.7) {
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .combinedSessionState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// kVK_ANSI_V. The paste shortcut is ⌘V on every keyboard layout macOS ships, because the
    /// menu shortcut is defined by the key's position, not by the letter printed on it.
    static let vKeyCode: CGKeyCode = 9

    /// Puts an entry back on the pasteboard. The resulting change is ignored by the poller.
    func copy(item: ClipboardItem) {
        pasteboard.clearContents()
        tiffPromise = nil
        switch item.kind {
        case .file where !item.fileURLs.isEmpty:
            // Only the files that are still there; when they have all gone, their paths as
            // text, which is the one useful thing left to hand over.
            let live = item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !live.isEmpty else {
                pasteboard.setString(item.fileURLs.map(\.path).joined(separator: "\n"), forType: .string)
                // The poller must not read this write back as a fresh copy and file it twice.
                lastChangeCount = pasteboard.changeCount
                return
            }
            let files: [NSPasteboardWriting] = live.map { $0 as NSURL }
            pasteboard.writeObjects(files)
        case .image:
            let entry = NSPasteboardItem()
            if let data = item.imageData {
                // PNG as it is kept, which every app reads. TIFF only promised: making it meant
                // decoding the picture and writing it out again uncompressed, on the main
                // thread, at the click — tens of megabytes for a screenshot — for the rare app
                // that asks for nothing else. Now it is made only if one does.
                entry.setData(data, forType: .png)
                let promise = TIFFPromise(png: data)
                if entry.setDataProvider(promise, forTypes: [.tiff]) { tiffPromise = promise }
            } else {
                entry.setString(item.text, forType: .string)
            }
            pasteboard.writeObjects([entry])
        case .url:
            let entry = NSPasteboardItem()
            entry.setString(item.text, forType: .string)
            entry.setString(item.text, forType: .URL)
            pasteboard.writeObjects([entry])
        default:
            let entry = NSPasteboardItem()
            entry.setString(item.text, forType: .string)
            pasteboard.writeObjects([entry])
        }
        // Our own write must not come back as a new history entry.
        lastChangeCount = pasteboard.changeCount
    }

    /// Whether picking a row pastes it into the app in front, rather than only putting it back
    /// on the pasteboard: "Paste after picking an item" on, and Accessibility allowing the
    /// keystroke. The rule `pick(item:)` follows, read by the row so it says what a click does.
    static var pickPastes: Bool {
        Preferences.shared.pasteOnPick && MediaKeyInterceptor.isTrusted
    }

    /// What picking a row does, for VoiceOver's hint. Pure, so the words follow the rule.
    static func pickHint(pastes: Bool) -> String {
        pastes ? "Pastes it where you were typing" : "Copies it again"
    }

    /// The row's tooltip: what a click does, and the drag that is the other way to use it.
    static func pickHelp(pastes: Bool) -> String {
        (pastes ? "Click to paste it where you were typing" : "Click to copy it again")
            + ", or drag it straight into a document."
    }

    /// Picking a row: put it back on the pasteboard, and then either paste it where the user
    /// was typing or say that it has been copied. Lives here rather than in the row that
    /// draws it, because Return in the find field picks one too.
    func pick(item: ClipboardItem) {
        copy(item: item)
        // "Put this where I was typing". The panel goes first, so the keyboard is back with
        // that app before the keystroke lands; without the permission to synthesise one, the
        // item is on the pasteboard and the user pastes it themselves.
        if Self.pickPastes {
            ActivityCenter.shared.collapse(reason: "clipboard item picked")
            Self.pasteIntoFrontmostApp()
            return
        }
        let activity = IslandActivity(id: "clipboard-copied",
                                      kind: .custom,
                                      content: .custom(CustomActivity(title: "Copied",
                                                                      symbol: "doc.on.clipboard",
                                                                      trailingText: "Copied")),
                                      priority: 80)
        ActivityCenter.shared.showAlert(activity, duration: 1.0, haptic: false)
        // Alerts linger while the pointer is on the island, and the pointer is by definition
        // still here after a click, so retire this one ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            if ActivityCenter.shared.alert?.id == activity.id { ActivityCenter.shared.dismissAlert() }
        }
    }

    func remove(item: ClipboardItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        pendingThumbnails.remove(item.id)
        missingFileIDs.remove(item.id)
        schedulePersist()
    }

    func togglePin(item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        schedulePersist()
    }

    // MARK: - Clearing, and taking it back

    /// What the section's Clear takes: every entry that answers the find — all of them, with
    /// nothing typed — except the pinned ones.
    ///
    /// A pin is somebody saying "keep this", and the ring buffer has always honoured it; Clear
    /// took the pins with everything else, which made pinning something the one way to lose it
    /// to a single stray click. The matching is the list's own (`ClipboardView.ordered`), so
    /// Clear never takes a row the list is not showing.
    static func clearing(_ items: [ClipboardItem], query: String?) -> [ClipboardItem] {
        ClipboardView.ordered(items, query: query).filter { !$0.pinned }
    }

    /// What Undo Clear leaves: the entries the Clear took, back in their places by the time
    /// they were copied, beside whatever has been copied since. The history fills itself while
    /// the offer stands, so the offer cannot wait for it to hold still the way the scratchpad's
    /// does; an entry that is somehow already back is not put back twice.
    static func restoring(_ cleared: [ClipboardItem], into items: [ClipboardItem], limit: Int) -> [ClipboardItem] {
        let present = Set(items.map(\.id))
        var result = items
        for entry in cleared where !present.contains(entry.id) {
            // After everything copied at the same moment or later, so what was cleared keeps
            // its own order and never jumps ahead of a copy made since.
            let index = result.firstIndex { $0.date < entry.date } ?? result.count
            result.insert(entry, at: index)
        }
        return capped(result, limit: limit)
    }

    /// How long "Undo Clear" is offered for: the same moment the scratchpad gives.
    static let undoWindow: TimeInterval = NotesStore.undoWindow

    /// What the last Clear took, for as long as the offer to put it back stands.
    @Published private(set) var clearedItems: [ClipboardItem]?
    private var clearedWork: DispatchWorkItem?

    /// The section's Clear: what the list is showing, less the pins, and for a moment
    /// afterwards it can be put back. A second Clear supersedes the first, as the scratchpad's
    /// does.
    func clear(matching query: String?) {
        let going = Self.clearing(items, query: query)
        guard !going.isEmpty else { return }
        let ids = Set(going.map(\.id))
        items.removeAll { ids.contains($0.id) }
        pruneThumbnails()
        pendingThumbnails.subtract(ids)
        missingFileIDs.subtract(ids)
        schedulePersist()
        forgetUndo()
        clearedItems = going
        let work = DispatchWorkItem { [weak self] in self?.forgetUndo() }
        clearedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow, execute: work)
    }

    /// Puts back what the last Clear took.
    func undoClear() {
        guard let cleared = clearedItems else { return }
        forgetUndo()
        let restored = Self.restoring(cleared, into: items, limit: Self.itemLimit(Preferences.shared.clipboardLimit))
        guard restored != items else { return }
        items = restored
        refreshMissingFiles()
        schedulePersist()
    }

    private func forgetUndo() {
        clearedWork?.cancel()
        clearedWork = nil
        clearedItems = nil
    }

    // MARK: - Which entries have lost their files

    /// Whether this entry pointed at files and not one of them is there any more, as of the
    /// last sweep. A row asks this as it draws itself, which is on every hover and every
    /// scroll of a fifty-row list, so the answer is a lookup and nothing else.
    func filesAreGone(_ item: ClipboardItem) -> Bool { missingFileIDs.contains(item.id) }

    /// Works the answers out again, away from the thread that draws.
    ///
    /// Nothing tells us when somebody moves or deletes a copied file behind our back, so the
    /// only way to know is to ask the disk; asking from inside a row's body meant a `stat` per
    /// file per redraw. Once when the history changes and once when the section is opened is
    /// enough. A file that vanishes while the panel is already open therefore goes unnoticed
    /// until the next sweep, which is a fair trade: the row is honest again a moment later,
    /// and picking a dead one still hands over its paths as text rather than nothing.
    ///
    /// Call this from the main thread; the sweep itself is not done there.
    func refreshMissingFiles() {
        let entries = ClipboardStore.fileEntries(in: items)
        guard !entries.isEmpty else {
            if !missingFileIDs.isEmpty { missingFileIDs = [] }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var gone = Set<UUID>()
            for entry in entries {
                let isGone = ClipboardStore.filesAreGone(urls: entry.urls,
                                                         exists: { FileManager.default.fileExists(atPath: $0.path) })
                if isGone { gone.insert(entry.id) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // The history can have moved on while the disk was being asked.
                let answers = ClipboardStore.pruned(gone, to: self.items)
                if answers != self.missingFileIDs { self.missingFileIDs = answers }
            }
        }
    }

    /// The entries a sweep has to ask the disk about at all: the ones that point at files.
    /// Text, links and pictures are answered from memory, which is nearly all of a history.
    static func fileEntries(in items: [ClipboardItem]) -> [(id: UUID, urls: [URL])] {
        var entries: [(id: UUID, urls: [URL])] = []
        for item in items {
            let urls = item.fileURLs
            guard !urls.isEmpty else { continue }
            entries.append((id: item.id, urls: urls))
        }
        return entries
    }

    /// A copied set of files has gone once not one of them is there any more: copying it back
    /// would put a dead reference on the pasteboard, so the row says so instead. The existence
    /// check is handed in, so the rule can be exercised without a disk under it.
    static func filesAreGone(urls: [URL], exists: (URL) -> Bool) -> Bool {
        guard !urls.isEmpty else { return false }
        return !urls.contains(where: exists)
    }

    /// Drops answers for entries the history no longer holds. Everything here is keyed by the
    /// entry's id, which is what goes to disk with it, so an answer still points at the row it
    /// was worked out for after the history has been read back.
    static func pruned(_ ids: Set<UUID>, to items: [ClipboardItem]) -> Set<UUID> {
        ids.intersection(items.map { $0.id })
    }

    // MARK: - Thumbnails (lazy, images only)

    /// Returns a cached thumbnail, kicking off a background decode the first time.
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard let data = item.imageData, !pendingThumbnails.contains(item.id) else { return nil }
        pendingThumbnails.insert(item.id)
        let id = item.id
        DispatchQueue.global(qos: .utility).async {
            let image = ClipboardStore.makeThumbnail(from: data, maxPixel: 64)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingThumbnails.remove(id)
                if let image { self.thumbnails[id] = image }
            }
        }
        return nil
    }

    private static func makeThumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func pruneThumbnails() {
        let live = Set(items.map { $0.id })
        let stale = thumbnails.keys.filter { !live.contains($0) }
        for id in stale { thumbnails[id] = nil }
    }

    // MARK: - Persistence (text, URLs and files only)

    /// The history on disk, read back, pictures left out. A file that is there and cannot be
    /// read — written by a newer build, say, with a kind of entry this one does not know — is
    /// moved aside rather than read as an empty history, which the next save used to write over
    /// it. Internal for the tests.
    static func readHistory(now: Date = Date()) -> IslandFiles.ReadBack<[ClipboardItem]> {
        IslandFiles.readBack(fileName, now: now) { data in
            try JSONDecoder().decode([ClipboardItem].self, from: data).filter { $0.kind != .image }
        }
    }

    /// Writes the history now rather than eight tenths of a second from now. Quitting is
    /// faster than the debounce, and the last thing somebody copied is exactly the thing they
    /// are about to want. Nothing is written for a history that has never been touched, nor
    /// for one that is not kept across relaunches.
    ///
    /// A copy already through `converter` is in what is written, though its hop to the main
    /// queue has not run. One still on it is not waited for, nor one queued behind it: the wait
    /// would be on the main thread, at quit, behind a picture that is never written to disk.
    func flush() {
        takeArrivals()
        guard persistWork != nil else { return }
        persistWork?.cancel()
        persistWork = nil
        guard !heldBack else { return }
        guard let snapshot = Self.toPersist(items, keeping: Preferences.shared.clipboardPersists) else { return }
        // Behind anything already being written, on the same queue, which does nothing else.
        Self.io.sync { Self.persist(snapshot) }
    }

    private func schedulePersist() {
        persistWork?.cancel()
        persistWork = nil
        guard !heldBack else { return }
        guard let snapshot = Self.toPersist(items, keeping: Preferences.shared.clipboardPersists) else { return }
        let work = DispatchWorkItem { ClipboardStore.persist(snapshot) }
        persistWork = work
        Self.io.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// What goes to disk, or nothing at all. Nothing while the history is not kept across
    /// relaunches, which is how it ships; and never a picture, whose bytes stay in memory.
    static func toPersist(_ items: [ClipboardItem], keeping: Bool) -> [ClipboardItem]? {
        keeping ? items.filter { $0.kind != .image } : nil
    }

    private static func persist(_ items: [ClipboardItem]) {
        do {
            try IslandFiles.write(try JSONEncoder().encode(items), to: fileName)
        } catch {
            IslandLog.store.error("clipboard history save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Takes the history off the disk, behind anything already on its way there.
    private static func erasePersisted() {
        io.async {
            guard let url = IslandFiles.folder?.appendingPathComponent(Self.fileName),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                IslandLog.store.error("clipboard history could not be erased: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// The TIFF of a picture put back on the pasteboard, made only when an app asks for it. PNG is
/// on the pasteboard already and is what nearly every app reads.
final class TIFFPromise: NSObject, NSPasteboardItemDataProvider {
    let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }
}
