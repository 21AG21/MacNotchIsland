import AppKit

/// Watches the user's screenshot folder (com.apple.screencapture "location", default
/// ~/Desktop), drops each new capture on the shelf and shows a brief "Screenshot" alert in
/// the island.
///
/// Event-driven only: a DispatchSource on the directory fires when macOS adds a capture.
/// The only timers are the short one-shots that confirm a new file has finished writing.
final class ScreenshotMonitor {
    /// A file counts as new when its creation date is within this many seconds of the event.
    static let recencyWindow: TimeInterval = 10
    /// Upper bound on the paths remembered for de-duplication.
    static let maxRemembered = 200
    /// What macOS and the usual capture tools write.
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "mov"]

    private static let settleDelay: TimeInterval = 0.3
    private static let maxSettleChecks = 10
    private static let alertDuration: TimeInterval = 2.5

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

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        let dir = Self.currentDirectory()
        directory = dir
        seen.removeAll()
        settling.removeAll()
        // Captures already there are old news; only what lands from now on is announced.
        for url in candidates(in: dir, now: Date()) { remember(url.path) }

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.fd = fd
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            close(fd)
            if self?.fd == fd { self?.fd = -1 }
        }
        src.resume()
        source = src
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        source?.cancel()
        source = nil
        settling.removeAll()
        directory = nil
    }

    // MARK: - Watching

    private func scan() {
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
        for url in items {
            let path = url.path
            guard !seen.contains(path), !settling.contains(path) else { continue }
            guard Self.isCandidate(name: url.lastPathComponent) else { continue }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            guard Self.isRecent(creation: values.creationDate ?? values.contentModificationDate, now: now) else { continue }
            found.append(url)
        }
        return found
    }

    /// macOS writes captures atomically, but a third-party tool might not: publish only once
    /// the size has held still across two reads ~300 ms apart. Bounded, so a file that keeps
    /// growing is eventually written off rather than checked forever.
    private func settle(_ url: URL, checks: Int = 0) {
        let path = url.path
        settling.insert(path)
        let before = Self.fileSize(at: url)
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
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

    private func publish(_ url: URL) {
        ShelfStore.shared.add([url])
        let name = url.lastPathComponent
        let isRecording = url.pathExtension.lowercased() == "mov"
        let custom = CustomActivity(title: isRecording ? "Screen recording" : "Screenshot",
                                    subtitle: name,
                                    symbol: isRecording ? "record.circle" : "camera.viewfinder",
                                    url: url)
        var alert = IslandActivity(id: "screenshot-" + name, kind: .custom, content: .custom(custom), priority: 85)
        alert.openAction = .url(url)
        // The shelf already gave a haptic tap for the new item.
        ActivityCenter.shared.showAlert(alert, duration: Self.alertDuration, haptic: false)
    }

    private func remember(_ path: String) {
        seen.insert(path)
        while seen.count > Self.maxRemembered, let victim = seen.first { seen.remove(victim) }
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    /// The folder macOS is saving captures to right now. Re-read on every start so a
    /// `defaults write com.apple.screencapture location …` change is picked up. A location
    /// that no longer exists falls back to the Desktop, as macOS itself does.
    private static func currentDirectory() -> URL {
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
