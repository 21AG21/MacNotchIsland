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

    private enum CodingKeys: String, CodingKey { case id, kind, text, date, pinned }

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

    /// True when this entry points at files and none of them are there any more. Copying one
    /// back would put a dead reference on the pasteboard, so the row says so instead.
    var filesAreGone: Bool {
        let urls = fileURLs
        guard !urls.isEmpty else { return false }
        return !urls.contains { FileManager.default.fileExists(atPath: $0.path) }
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

    /// Fills the history for the rendered gallery, which starts with an empty pasteboard.
    /// Does nothing outside the gallery.
    func seedForGallery(_ items: [ClipboardItem]) {
        guard RenderMode.isGallery else { return }
        self.items = items
    }

    private init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        items = ClipboardStore.loadPersisted()
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        // Whatever is already on the pasteboard at launch is not a new copy.
        lastChangeCount = pasteboard.changeCount
        EnergyPolicy.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rescheduleTimer() }
            .store(in: &cancellables)
        rescheduleTimer()
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

    private func tick() {
        guard running else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let item = ClipboardStore.item(from: readSnapshot()) else { return }
        append(item)
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
        // Spreadsheets put a picture of the selection next to the text; text wins.
        if snapshot.fileURLs.isEmpty && !hasText, let image = ClipboardStore.pngData(from: pasteboard) {
            snapshot.imageData = image.data
            snapshot.imagePixelSize = image.size
        }
        return snapshot
    }

    private static func pngData(from pasteboard: NSPasteboard) -> (data: Data, size: CGSize)? {
        var png = pasteboard.data(forType: .png)
        if png == nil, let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        guard let data = png, let rep = NSBitmapImageRep(data: data) else { return nil }
        return (data, CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
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
    static func item(from snapshot: ClipboardSnapshot, date: Date = Date()) -> ClipboardItem? {
        guard !isConcealed(types: snapshot.types) else { return nil }

        if !snapshot.fileURLs.isEmpty {
            let paths = snapshot.fileURLs.map { $0.path }.joined(separator: "\n")
            return ClipboardItem(kind: .file, text: paths, date: date)
        }

        let raw = snapshot.text ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if isURL(trimmed, types: snapshot.types) {
                return ClipboardItem(kind: .url, text: trimmed, date: date)
            }
            return ClipboardItem(kind: .text, text: String(raw.prefix(maxTextLength)), date: date)
        }

        if let data = snapshot.imageData {
            var label = "Image"
            if let size = snapshot.imagePixelSize, size.width > 1, size.height > 1 {
                label = "Image \(Int(size.width)) × \(Int(size.height))"
            }
            return ClipboardItem(kind: .image, text: label, date: date, imageData: data)
        }
        return nil
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

        let cap = max(1, limit)
        var index = result.count - 1
        while result.count > cap && index > 0 {
            if !result[index].pinned { result.remove(at: index) }
            index -= 1
        }
        return result
    }

    // MARK: - Mutation

    private func append(_ item: ClipboardItem) {
        let limit = Int(Preferences.shared.clipboardLimit.rounded())
        let updated = ClipboardStore.inserting(item, into: items, limit: limit)
        guard updated != items else { return }
        items = updated
        pruneThumbnails()
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
                entry.setData(data, forType: .png)
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                    entry.setData(tiff, forType: .tiff)
                }
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

    /// Picking a row: put it back on the pasteboard, and then either paste it where the user
    /// was typing or say that it has been copied. Lives here rather than in the row that
    /// draws it, because Return in the find field picks one too.
    func pick(item: ClipboardItem) {
        copy(item: item)
        // "Put this where I was typing". The panel goes first, so the keyboard is back with
        // that app before the keystroke lands; without the permission to synthesise one, the
        // item is on the pasteboard and the user pastes it themselves.
        if Preferences.shared.pasteOnPick, MediaKeyInterceptor.isTrusted {
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
        schedulePersist()
    }

    func togglePin(item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        schedulePersist()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        thumbnails.removeAll()
        pendingThumbnails.removeAll()
        schedulePersist()
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

    private static func loadPersisted() -> [ClipboardItem] {
        guard let data = IslandFiles.read(fileName),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return [] }
        return decoded.filter { $0.kind != .image }
    }

    /// Writes the history now rather than eight tenths of a second from now. Quitting is
    /// faster than the debounce, and the last thing somebody copied is exactly the thing they
    /// are about to want. Nothing is written for a history that has never been touched.
    func flush() {
        guard persistWork != nil else { return }
        persistWork?.cancel()
        persistWork = nil
        Self.persist(items.filter { $0.kind != .image })
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let snapshot = items.filter { $0.kind != .image }
        let work = DispatchWorkItem { ClipboardStore.persist(snapshot) }
        persistWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private static func persist(_ items: [ClipboardItem]) {
        do {
            try IslandFiles.write(try JSONEncoder().encode(items), to: fileName)
        } catch {
            IslandLog.store.error("clipboard history save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
