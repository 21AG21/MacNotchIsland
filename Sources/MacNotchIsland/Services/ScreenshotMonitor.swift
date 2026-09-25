import AppKit
import ImageIO

/// Watches the user's screenshot folder (com.apple.screencapture "location", default
/// ~/Desktop), drops each new capture on the shelf and shows a brief "Screenshot" alert in
/// the island.
///
/// Event-driven only: a DispatchSource on the directory fires when macOS adds a capture.
/// The only timers are the short one-shots that confirm a new file has finished writing. The
/// folder itself is looked up again whenever the watcher wakes and whenever another app comes
/// to the front, so that moving the captures somewhere else moves the watch with them.
///
/// None of that happens on the main thread. The folder being watched is usually the Desktop,
/// every app that saves a file there wakes the source, and answering each wake means reading
/// the whole directory and asking the file system about the entries in it — which on a busy
/// Desktop is hundreds of calls for something that is, nine times out of ten, not a capture
/// at all. The main thread is asked for only the two things that need it: putting the file on
/// the shelf and raising the card.
final class ScreenshotMonitor {
    /// A file counts as new when its creation date is within this many seconds of the event.
    static let recencyWindow: TimeInterval = 10
    /// Upper bound on the paths remembered for de-duplication.
    static let maxRemembered = 200
    /// What macOS and the usual capture tools write.
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "mov"]

    private static let settleDelay: TimeInterval = 0.3
    private static let maxSettleChecks = 10
    /// The card stays up long enough to reach for one of its buttons — about as long as the
    /// thumbnail macOS puts in the corner of the screen.
    private static let alertDuration: TimeInterval = 4
    /// How big the picture on the card is drawn, in pixels, at Retina scale and a little over.
    static let thumbnailPixels: CGFloat = 240

    /// Leading words macOS uses for captures in the common locales, plus CleanShot.
    private static let prefixes: [String] = [
        "Screenshot", "Screen Shot", "Screen Recording", "CleanShot",
        "Bildschirmfoto",                       // German
        "Capture d'écran", "Capture d’écran",   // French (straight and typographic apostrophe)
        "Captura de pantalla",                  // Spanish
        "Schermafbeelding",                     // Dutch
        "スクリーンショット",                      // Japanese
        "屏幕快照", "截屏",                        // Chinese
    ]

    /// Where the watching is done. Everything the monitor remembers — the directory, what has
    /// been seen, what is still settling, the descriptor — is touched on this queue and
    /// nowhere else, so a serial queue is all the confinement it needs.
    private let queue = DispatchQueue(label: "com.macnotchisland.screenshots", qos: .utility)

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var directory: URL?
    /// Paths already handled, so a second directory event doesn't announce a capture twice.
    private var seen = Set<String>()
    /// Paths waiting for their size-stability check.
    private var settling = Set<String>()
    private var running = false
    /// Bumped on every start/stop so a settle check scheduled by an earlier run is ignored.
    private var generation = 0
    /// Heard on the main thread, which is where `start` and `stop` are called and the only
    /// place this is touched; what it hears is handed to the queue.
    private var activationObserver: NSObjectProtocol?

    func start() {
        queue.async { [weak self] in self?.beginWatching() }
        // The folder can be changed without a single write to the old one — the Options menu in
        // the screenshot toolbar, a `defaults write` in Terminal — so the watcher's own events
        // cannot be the only time it is looked up again. Switching apps is cheap to hear and
        // comes soon after either.
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [weak self] in self?.followTheFolder() }
            }
    }

    func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        queue.async { [weak self] in self?.endWatching() }
    }

    private func beginWatching() {
        guard !running else { return }
        running = true
        generation += 1
        let dir = Self.currentDirectory()
        seen.removeAll()
        settling.removeAll()
        // Captures already there are old news; only what lands from now on is announced.
        for url in candidates(in: dir, now: Date()) { remember(url.path) }
        bind(to: dir)
    }

    /// Moves the watch to wherever macOS is saving captures now, if that is somewhere else.
    ///
    /// The folder used to be read once, at start, and `start` does nothing while running: a
    /// new location in the screenshot toolbar's Options menu left the watcher on the old
    /// folder, and the card never came again until the app was relaunched. What has been
    /// seen is kept — its paths are whole paths, so nothing in the new folder is mistaken for
    /// something in the old — and the new folder is walked once straight away, because the
    /// capture that follows a change of folder is often taken before anything notices it: it
    /// has the recency window to be found in, like any other.
    private func followTheFolder() {
        guard running else { return }
        let current = Self.currentDirectory()
        guard Self.needsRebind(watching: directory, current: current) else { return }
        IslandLog.island.notice("screenshots are saved somewhere else now; watching the new folder")
        unbind()
        bind(to: current)
        walk()
    }

    /// Whether the folder being watched is not the one captures are saved to. Nothing being
    /// watched is no reason to rebind: that is a monitor that has not started, and starting
    /// reads the folder for itself. Compared by path, so a trailing slash is not a new folder.
    /// Pure, so it is tested.
    static func needsRebind(watching: URL?, current: URL) -> Bool {
        guard let watching else { return false }
        return watching.standardizedFileURL.path != current.standardizedFileURL.path
    }

    /// Opens `dir` and starts listening to it. Nothing is announced from here: the caller
    /// decides whether what is already there is old news or worth a look.
    private func bind(to dir: URL) {
        directory = dir
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.fd = fd
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            close(fd)
            if self?.fd == fd { self?.fd = -1 }
        }
        src.resume()
        source = src
    }

    /// Stops listening to the folder being watched. A capture already settling finishes: it
    /// is a whole path, and still a capture wherever the watch has gone.
    private func unbind() {
        source?.cancel()
        source = nil
        directory = nil
    }

    private func endWatching() {
        guard running else { return }
        running = false
        generation += 1
        unbind()
        settling.removeAll()
    }

    // MARK: - Watching

    /// The watcher has woken: whatever woke it is in the folder being watched, and every wake
    /// is also a chance to notice that the folder has moved, for the price of one preference.
    private func scan() {
        walk()
        followTheFolder()
    }

    private func walk() {
        guard running, let directory else { return }
        for url in candidates(in: directory, now: Date()) { settle(url) }
    }

    /// Regular files in `directory` that look like fresh captures and haven't been handled yet.
    private func candidates(in directory: URL, now: Date) -> [URL] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                        includingPropertiesForKeys: Array(keys),
                                                                        options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for url in Self.unhandled(items, seen: seen, settling: settling) {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            guard Self.isNewCapture(name: url.lastPathComponent,
                                    isRegularFile: values.isRegularFile == true,
                                    creation: values.creationDate ?? values.contentModificationDate,
                                    now: now) else { continue }
            found.append(url)
        }
        return found
    }

    /// The entries worth asking the file system about: not handled already, not waiting to
    /// settle, not claimed by something else in the app — the screen recorder's movie while it
    /// is being written — and named like a capture. Pure, and the very filter the watcher's
    /// walk runs, so what it walks past can be read back without a folder to watch.
    ///
    /// The name is read here and then again inside the whole rule: a name costs nothing to
    /// look at, and it spares the entries that are plainly not captures — most of a Desktop —
    /// the trip to the file system after it.
    static func unhandled(_ items: [URL], seen: Set<String>, settling: Set<String>) -> [URL] {
        items.filter { url in
            let path = url.path
            guard !seen.contains(path), !settling.contains(path), !isClaimed(path) else { return false }
            return isCandidate(name: url.lastPathComponent)
        }
    }

    /// macOS writes captures atomically, but a third-party tool might not: publish only once
    /// the size has held still across two reads ~300 ms apart. Bounded, so a file that keeps
    /// growing is eventually written off rather than checked forever.
    private func settle(_ url: URL, checks: Int = 0) {
        let path = url.path
        settling.insert(path)
        let before = Self.fileSize(at: url)
        let gen = generation
        queue.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.running, self.generation == gen else { return }
            self.settling.remove(path)
            // Gone again (moved or deleted before it settled): nothing to announce.
            guard let after = Self.fileSize(at: url) else { return }
            if after > 0, after == before {
                self.remember(path)
                self.publish(url)
            } else if checks + 1 < Self.maxSettleChecks {
                self.settle(url, checks: checks + 1)
            } else {
                self.remember(path)
            }
        }
    }

    /// Reads the capture, then hands it over. Opening the file to make the small copy is the
    /// expensive half and it belongs here, on the watcher's own queue; only the announcement
    /// itself has to be on the main thread.
    private func publish(_ url: URL) {
        let isRecording = url.pathExtension.lowercased() == "mov"
        // The picture itself, not a camera glyph: it is the one thing that says which capture
        // this is, and it is what you pick up to drag somewhere.
        // Labelled on both sides, or the ternary settles on a plain pair and the names go.
        let picture: (thumbnail: NSImage?, pixels: CGSize?) =
            isRecording ? (thumbnail: nil, pixels: nil) : Self.picture(of: url)
        DispatchQueue.main.async {
            Self.announce(url, isRecording: isRecording, picture: picture)
        }
    }

    /// The shelf, the preferences behind it and the island itself: all main-thread things, and
    /// the only part of a capture that has to wait for that thread.
    ///
    /// Static, because the island's own screen recorder hands its finished file to exactly
    /// this, whether or not the watcher is running: a recording somebody started from the
    /// island gets the same card as one macOS made.
    static func announce(_ url: URL, isRecording: Bool, picture: (thumbnail: NSImage?, pixels: CGSize?)) {
        let prefs = Preferences.shared
        let onShelf = prefs.shelfEnabled && prefs.screenshotsToShelfEnabled
        if onShelf { ShelfStore.shared.add([url]) }
        let name = url.lastPathComponent
        let state = CaptureState(path: url.path,
                                 isRecording: isRecording,
                                 thumbnail: picture.thumbnail,
                                 onShelf: onShelf,
                                 pixels: picture.pixels)
        var alert = IslandActivity(id: "screenshot-" + name, kind: .capture, content: .capture(state),
                                   priority: 85, presentation: .expanded)
        alert.openAction = .url(url)
        // The shelf already gave a haptic tap for the new item; without the shelf, this is the
        // only feedback there is.
        ActivityCenter.shared.showAlert(alert, duration: Self.alertDuration, haptic: !onShelf)
    }

    /// A small copy of the capture for the card and the pill, and how big the real thing is.
    ///
    /// Read through ImageIO rather than `NSImage`, so a 6K grab never becomes a 6K bitmap in
    /// memory to be shown at 44 points — and both answers come off one source, since opening
    /// the file is the expensive half.
    static func picture(of url: URL) -> (thumbnail: NSImage?, pixels: CGSize?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, nil) }
        var pixels: CGSize?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 {
            pixels = CGSize(width: width, height: height)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
              ] as CFDictionary) else { return (nil, pixels) }
        return (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), pixels)
    }

    private func remember(_ path: String) {
        seen.insert(path)
        while seen.count > Self.maxRemembered, let victim = seen.first { seen.remove(victim) }
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    // MARK: - Captures announced elsewhere

    /// Files something else in the app announces itself, which the watcher walks past.
    ///
    /// The island's own screen recorder writes into this same folder, and a movie that is still
    /// being recorded looks exactly like a capture that has just landed: it is new, it has the
    /// name, and between two writes its size holds still for longer than the settle check
    /// waits. Unclaimed, it was a card for half a recording in the middle of making it. Read on
    /// the watcher's queue and written on the main thread, so under a lock of its own.
    private static let claimLock = NSLock()
    private static var claimed = Set<String>()

    /// Leaves `url` to whoever claimed it, from now on.
    static func claim(_ url: URL) {
        claimLock.lock()
        defer { claimLock.unlock() }
        claimed.insert(url.path)
        while claimed.count > maxRemembered, let victim = claimed.first { claimed.remove(victim) }
    }

    static func isClaimed(_ path: String) -> Bool {
        claimLock.lock()
        defer { claimLock.unlock() }
        return claimed.contains(path)
    }

    /// The folder macOS is saving captures to right now. Re-read on every start, every wake of
    /// the watcher and every switch of app, so a new location — from the screenshot toolbar or
    /// `defaults write com.apple.screencapture location …` — is picked up without a relaunch,
    /// see `followTheFolder`. A location
    /// that no longer exists falls back to the Desktop, as macOS itself does. The screen
    /// recorder saves here too, so a recording goes wherever a screenshot would.
    static func currentDirectory() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let preferred = screenshotDirectory(defaultsLocation: location, home: home).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: preferred.path, isDirectory: &isDirectory), isDirectory.boolValue { return preferred }
        return screenshotDirectory(defaultsLocation: nil, home: home).resolvingSymlinksInPath()
    }

    // MARK: - Pure rules

    /// Expands `~` in the com.apple.screencapture location. Nil, empty and relative values
    /// mean the default, ~/Desktop. Symlinks are resolved by the caller.
    static func screenshotDirectory(defaultsLocation: String?, home: URL) -> URL {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = defaultsLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return desktop }
        let path: String
        if raw == "~" {
            path = home.path
        } else if raw.hasPrefix("~/") {
            path = home.path + String(raw.dropFirst())
        } else if raw.hasPrefix("/") {
            path = raw
        } else {
            return desktop
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// True when the file was created within `window` seconds before `now`. A little slack
    /// forward covers file-system timestamp granularity.
    static func isRecent(creation: Date?, now: Date, window: TimeInterval = ScreenshotMonitor.recencyWindow) -> Bool {
        guard let creation else { return false }
        let age = now.timeIntervalSince(creation)
        return age <= window && age >= -1
    }

    /// Everything the walk decides about one directory entry, in one piece: a regular file,
    /// named the way a capture is named, and written just now. Kept whole and kept pure so
    /// that moving the walk off the main thread could not quietly change what it announces.
    static func isNewCapture(name: String, isRegularFile: Bool, creation: Date?, now: Date) -> Bool {
        guard isRegularFile, isCandidate(name: name) else { return false }
        return isRecent(creation: creation, now: now)
    }

    /// Full filter for a directory entry: not hidden, a capture-like name and an image or
    /// movie extension (which also rules out in-flight `.crdownload` files).
    static func isCandidate(name: String) -> Bool {
        guard looksLikeScreenshot(name) else { return false }
        return extensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether a file name is one macOS (in any common locale) or a popular capture tool
    /// gives a screenshot or screen recording: a known leading phrase, or the generic
    /// `<words> <YYYY-MM-DD> at <HH.MM.SS>` shape. Hidden files never match.
    static func looksLikeScreenshot(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(".") else { return false }
        let options: NSString.CompareOptions = [.anchored, .caseInsensitive, .diacriticInsensitive]
        if prefixes.contains(where: { trimmed.range(of: $0, options: options) != nil }) { return true }
        return matchesDateTimePattern(trimmed)
    }

    /// `<words> <YYYY-MM-DD> [<connector>] <H[H].MM.SS>…` — "at" in English, "um", "à",
    /// "om" and friends elsewhere, or nothing at all. At least one word must precede the date.
    private static func matchesDateTimePattern(_ name: String) -> Bool {
        let tokens = name.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return false }
        for i in 1..<tokens.count where isDate(tokens[i]) {
            if i + 1 < tokens.count, isTime(tokens[i + 1]) { return true }
            if i + 2 < tokens.count, isConnector(tokens[i + 1]), isTime(tokens[i + 2]) { return true }
        }
        return false
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// Exactly `YYYY-MM-DD`.
    private static func isDate(_ token: String) -> Bool {
        let chars = Array(token)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return false }
        for (i, c) in chars.enumerated() where i != 4 && i != 7 {
            guard isDigit(c) else { return false }
        }
        return true
    }

    /// `H.MM.SS` or `HH.MM.SS`, optionally followed by something that isn't a digit
    /// (the extension, "@2x", …).
    private static func isTime(_ token: String) -> Bool {
        let chars = Array(token)
        var i = 0
        var hourDigits = 0
        while i < chars.count, isDigit(chars[i]) {
            hourDigits += 1
            i += 1
        }
        guard hourDigits == 1 || hourDigits == 2 else { return false }
        for _ in 0..<2 {
            guard i < chars.count, chars[i] == "." else { return false }
            i += 1
            guard i + 1 < chars.count, isDigit(chars[i]), isDigit(chars[i + 1]) else { return false }
            i += 2
        }
        return i == chars.count || !isDigit(chars[i])
    }

    /// A short word between date and time ("at", "um", "à", "om", "kl.").
    private static func isConnector(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 8 && !token.contains(where: { $0.isNumber })
    }
}
