import Foundation
import Combine

/// One timed line of an LRC file.
struct LyricLine: Equatable, Codable {
    let time: TimeInterval
    let text: String
}

/// Time-synced lyrics for the current track, from LRCLIB (free, no API key).
///
/// Work only happens when it has to: one fetch per track (memory + disk cached, misses
/// included, so a track without lyrics is never asked for twice), and a 0.25 s ticker that
/// runs only while a *synced* track is actually playing and the Mac is awake.
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    /// The line that should be on screen right now, or nil when there is nothing to show.
    @Published private(set) var currentLine: String? = nil
    /// The line after `currentLine`, for views that want to preview it.
    @Published private(set) var nextLine: String? = nil
    /// True when the track only has unsynced lyrics, so there is nothing to follow along with.
    @Published private(set) var hasPlainLyrics = false

    private static let userAgent = "NotchIsland/1.0 (https://github.com/21AG21/MacNotchIsland)"
    private static let maxMemoryEntries = 50
    private static let maxDiskEntries = 500
    private static let tick: TimeInterval = 0.25

    private var cancellables = Set<AnyCancellable>()
    private var running = false
    private var timer: Timer?
    private var task: URLSessionDataTask?

    private var latest: NowPlayingInfo?
    private var currentKey: TrackKey?
    private var lines: [LyricLine] = []

    private var memory: [TrackKey: CachedLyrics] = [:]
    private var order: [TrackKey] = []
    private let ioQueue = DispatchQueue(label: "island.lyrics.io", qos: .utility)

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        NowPlayingService.shared.$info
            .sink { [weak self] info in self?.handle(info) }
            .store(in: &cancellables)
        EnergyPolicy.shared.$isAsleep
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateTimer() }
            .store(in: &cancellables)
        handle(NowPlayingService.shared.info)
        pruneDiskCache()
    }

    func stop() {
        guard running else { return }
        running = false
        cancellables.removeAll()
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        latest = nil
        currentKey = nil
        lines = []
        hasPlainLyrics = false
        publish(nil, nil)
    }

    // MARK: - Track changes

    /// `@Published` delivers the *new* value before the property is updated, so everything
    /// downstream reads the value handed to us here rather than `NowPlayingService.info`.
    private func handle(_ info: NowPlayingInfo?) {
        latest = info
        let key = info.flatMap { TrackKey($0) }
        if key != currentKey { trackChanged(to: key) }
        updateTimer()
    }

    private func trackChanged(to key: TrackKey?) {
        task?.cancel()
        task = nil
        currentKey = key
        lines = []
        hasPlainLyrics = false
        publish(nil, nil)
        guard let key else { return }
        if let cached = memory[key] {
            remember(cached, for: key)
            apply(cached, for: key)
            return
        }
        loadFromDisk(key) { [weak self] cached in
            guard let self, key == self.currentKey else { return }
            if let cached {
                self.remember(cached, for: key)
                self.apply(cached, for: key)
            } else {
                self.fetch(key)
            }
        }
    }

    private func apply(_ cached: CachedLyrics, for key: TrackKey) {
        guard key == currentKey else { return }
        lines = cached.lines
        hasPlainLyrics = cached.hasPlain
        updateTimer()
    }

    // MARK: - Ticking

    private func updateTimer() {
        let playing = latest?.isPlaying ?? false
        let wanted = running && playing && !lines.isEmpty && !EnergyPolicy.shared.isAsleep
        if wanted {
            if timer == nil {
                let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.refresh() }
                t.tolerance = Self.tick / 4
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else if timer != nil {
            timer?.invalidate()
            timer = nil
        }
        refresh()
    }

    /// Picks the line for the current playback position. Cheap enough to run on every tick.
    private func refresh() {
        guard !lines.isEmpty, let info = latest else {
            publish(nil, nil)
            return
        }
        guard let index = Self.line(at: info.position(at: Date()), in: lines) else {
            publish(nil, nil)
            return
        }
        let current = lines[index].text
        let following = index + 1 < lines.count ? lines[index + 1].text : ""
        publish(current.isEmpty ? nil : current, following.isEmpty ? nil : following)
    }

    private func publish(_ current: String?, _ next: String?) {
        if currentLine != current { currentLine = current }
        if nextLine != next { nextLine = next }
    }

    // MARK: - LRC parsing

    /// Parses an LRC document into sorted, timed lines.
    ///
    /// Handles `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss.xxx]` and `[mm:ss:xx]`, several timestamps on
    /// one line, metadata tags (`[ar:…]`, which are skipped) and enhanced-LRC word timings
    /// (`<00:12.34>`, which are stripped). Lines whose text is empty are kept, because in LRC
    /// they mark an instrumental gap; callers turn those into "no line".
    static func parse(lrc: String) -> [LyricLine] {
        var result: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var stamps: [TimeInterval] = []
            var rest = raw[...]
            while true {
                while let first = rest.first, first == " " || first == "\t" { rest = rest.dropFirst() }
                guard rest.first == "[", let close = rest.firstIndex(of: "]") else { break }
                let body = rest[rest.index(after: rest.startIndex)..<close]
                guard let time = timestamp(from: body) else { break }
                stamps.append(time)
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let text = stripInlineTimestamps(String(rest)).trimmingCharacters(in: .whitespaces)
            for time in stamps { result.append(LyricLine(time: time, text: text)) }
        }
        // Stable: equal timestamps keep the order they appeared in.
        return result.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map { $0.element }
    }

    /// Index of the last line whose time is at or before `time`, or nil before the first line.
    static func line(at time: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard let first = lines.first, time >= first.time else { return nil }
        var low = 0
        var high = lines.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    /// "01:23.45" / "01:23.456" / "01:23" / "01:23:45" -> seconds. Nil for metadata tags.
    static func timestamp(from body: Substring) -> TimeInterval? {
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        var secondsText = parts[1]
        var fraction: TimeInterval = 0
        if parts.count == 3 {
            guard let value = fractionValue(parts[2]) else { return nil }
            fraction = value
        } else if let dot = secondsText.firstIndex(where: { $0 == "." || $0 == "," }) {
            guard let value = fractionValue(secondsText[secondsText.index(after: dot)...]) else { return nil }
            fraction = value
            secondsText = secondsText[..<dot]
        }
        guard let seconds = Int(secondsText), seconds >= 0 else { return nil }
        return TimeInterval(minutes * 60 + seconds) + fraction
    }

    private static func fractionValue(_ digits: Substring) -> TimeInterval? {
        guard !digits.isEmpty, digits.count <= 3, let value = Int(digits), value >= 0 else { return nil }
        switch digits.count {
        case 1: return TimeInterval(value) / 10
        case 2: return TimeInterval(value) / 100
        default: return TimeInterval(value) / 1000
        }
    }

    /// Removes enhanced-LRC word timings such as `<00:12.34>` while leaving other angle
    /// brackets (lyrics do contain them) alone.
    private static func stripInlineTimestamps(_ text: String) -> String {
        guard text.contains("<"), text.contains(">") else { return text }
        var out = ""
        var buffer = ""
        var inTag = false
        for character in text {
            if character == "<" {
                if inTag { out += "<" + buffer }
                inTag = true
                buffer = ""
            } else if character == ">" && inTag {
                if timestamp(from: buffer[...]) == nil { out += "<" + buffer + ">" }
                inTag = false
                buffer = ""
            } else if inTag {
                buffer.append(character)
            } else {
                out.append(character)
            }
        }
        if inTag { out += "<" + buffer }
        return out
    }

    // MARK: - LRCLIB

    private struct Record: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?

        var synced: String { syncedLyrics ?? "" }
        var plain: String { plainLyrics ?? "" }
        var hasLyrics: Bool { !synced.isEmpty || !plain.isEmpty }
    }

    private func fetch(_ key: TrackKey) {
        guard key.duration > 0, let url = Self.getURL(key) else {
            search(key)
            return
        }
        request(url) { [weak self] data in
            guard let self else { return }
            if let data, let record = try? JSONDecoder().decode(Record.self, from: data), record.hasLyrics {
                self.finish(key, record: record)
            } else {
                self.search(key)
            }
        }
    }

    private func search(_ key: TrackKey) {
        guard let url = Self.searchURL(key) else {
            finish(key, record: nil)
            return
        }
        request(url) { [weak self] data in
            guard let self else { return }
            guard let data, let records = try? JSONDecoder().decode([Record].self, from: data) else {
                self.finish(key, record: nil)
                return
            }
            self.finish(key, record: Self.bestMatch(in: records, duration: key.duration))
        }
    }

    /// Network problems are not worth telling the user about: no lyrics is the fallback.
    private func request(_ url: URL, completion: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200..<300).contains(code)
            DispatchQueue.main.async { completion(ok ? data : nil) }
        }
        self.task = task
        task.resume()
    }

    /// Prefers entries that actually carry synced lyrics, then the closest duration.
    private static func bestMatch(in records: [Record], duration: Int) -> Record? {
        let synced = records.filter { !$0.synced.isEmpty }
        let pool = synced.isEmpty ? records.filter { !$0.plain.isEmpty } : synced
        guard !pool.isEmpty else { return nil }
        guard duration > 0 else { return pool.first }
        let target = Double(duration)
        return pool.min { lhs, rhs in
            abs((lhs.duration ?? .greatestFiniteMagnitude) - target) < abs((rhs.duration ?? .greatestFiniteMagnitude) - target)
        }
    }

    private func finish(_ key: TrackKey, record: Record?) {
        let synced = record?.synced ?? ""
        let plain = record?.plain ?? ""
        let parsed = synced.isEmpty ? [] : Self.parse(lrc: synced)
        let cached = CachedLyrics(lines: parsed, hasPlain: parsed.isEmpty && !plain.isEmpty)
        remember(cached, for: key)
        saveToDisk(cached, for: key)
        apply(cached, for: key)
    }

    private static func getURL(_ key: TrackKey) -> URL? {
        URL(string: "https://lrclib.net/api/get?artist_name=\(escape(key.artist))&track_name=\(escape(key.title))"
            + "&album_name=\(escape(key.album))&duration=\(key.duration)")
    }

    private static func searchURL(_ key: TrackKey) -> URL? {
        var string = "https://lrclib.net/api/search?track_name=\(escape(key.title))"
        if !key.artist.isEmpty { string += "&artist_name=\(escape(key.artist))" }
        return URL(string: string)
    }

    /// Percent-encodes everything outside RFC 3986's unreserved set, so "&", "+", "=" and any
    /// non-ASCII character in a title can't break the query.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    // MARK: - Caching

    struct TrackKey: Hashable {
        var title: String
        var artist: String
        var album: String
        var duration: Int

        init?(_ info: NowPlayingInfo) {
            let title = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            self.title = title
            self.artist = info.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            self.album = info.album.trimmingCharacters(in: .whitespacesAndNewlines)
            self.duration = info.duration > 0 ? Int(info.duration.rounded()) : 0
        }

        /// Stable across launches, unlike `hashValue`, so it can name a file on disk.
        var identity: String {
            "\(artist.lowercased())|\(title.lowercased())|\(album.lowercased())|\(duration)"
        }
    }

    private struct CachedLyrics: Codable {
        var lines: [LyricLine]
        var hasPlain: Bool
    }

    private static let cacheDirectory: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("MacNotchIsland", isDirectory: true)
            .appendingPathComponent("lyrics", isDirectory: true)
    }()

    private static func cacheFile(for key: TrackKey) -> URL? {
        cacheDirectory?.appendingPathComponent(fnv1a(key.identity) + ".json")
    }

    private static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private func remember(_ cached: CachedLyrics, for key: TrackKey) {
        memory[key] = cached
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.maxMemoryEntries {
            let oldest = order.removeFirst()
            memory[oldest] = nil
        }
    }

    private func loadFromDisk(_ key: TrackKey, completion: @escaping (CachedLyrics?) -> Void) {
        guard let url = Self.cacheFile(for: key) else {
            completion(nil)
            return
        }
        ioQueue.async {
            var cached: CachedLyrics?
            if let data = try? Data(contentsOf: url) {
                cached = try? JSONDecoder().decode(CachedLyrics.self, from: data)
            }
            DispatchQueue.main.async { completion(cached) }
        }
    }

    private func saveToDisk(_ cached: CachedLyrics, for key: TrackKey) {
        guard let url = Self.cacheFile(for: key), let data = try? JSONEncoder().encode(cached) else { return }
        ioQueue.async {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Keeps the on-disk cache from growing forever; runs once per start, off the main thread.
    private func pruneDiskCache() {
        guard let directory = Self.cacheDirectory else { return }
        ioQueue.async {
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: [.contentModificationDateKey],
                                                               options: [.skipsHiddenFiles]),
                  files.count > Self.maxDiskEntries else { return }
            let dated: [(url: URL, date: Date)] = files.map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (url: url, date: date ?? Date.distantPast)
            }
            let oldestFirst = dated.sorted { $0.date < $1.date }
            for entry in oldestFirst.prefix(oldestFirst.count - Self.maxDiskEntries) {
                try? manager.removeItem(at: entry.url)
            }
        }
    }
}
