import AppKit
import Combine

/// Turns in-progress browser downloads in ~/Downloads into Live Activities
/// (Safari `.download` bundles report exact progress; Chrome `.crdownload` and Firefox
/// `.part` files report the bytes received so far) and shows a "Download complete" alert.
///
/// None of the looking happens on the main thread. Downloads is the busiest folder on most
/// Macs, and answering it meant listing the whole of it and asking the file system about every
/// entry — at launch, on every event the folder raised, and once a second for as long as
/// anything was downloading — all on the thread that draws the island, for something that is
/// nearly always three names out of several hundred. The folder is watched and read on
/// `queue`; entries are picked out by name before anything is asked of the disk; and the main
/// thread is handed only what changed, to put up, take down or announce.
final class DownloadMonitor {
    private static let baseInterval: TimeInterval = 1

    /// What each browser leaves in the folder while a download is running. Lower case.
    static let partialExtensions: Set<String> = ["download", "crdownload", "part"]

    /// Where the watching and reading happen. The descriptor, the source and what is in
    /// flight are touched on this queue and nowhere else, as `ScreenshotMonitor` keeps its own.
    private let queue = DispatchQueue(label: "com.macnotchisland.downloads", qos: .utility)

    // On `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var watching = false
    /// Which run of the monitor the queue is serving, handed back with everything it reports.
    private var ticket = 0
    private var active: [String: DownloadState] = [:]

    // On the main thread.
    private var running = false
    /// Bumped on every start and stop, so a report from a run that has since ended is dropped.
    private var generation = 0
    /// The cards up now, by key: what `stop` takes down without asking the queue.
    private var shown = Set<String>()
    private var timer: Timer?
    private var energyCancellable: AnyCancellable?

    private static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        let run = generation
        queue.async { [weak self] in self?.beginWatching(run) }
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescheduleTimer() }
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        timer?.invalidate()
        timer = nil
        energyCancellable?.cancel()
        energyCancellable = nil
        for key in shown { ActivityCenter.shared.end(id: "download-" + key) }
        shown.removeAll()
        queue.async { [weak self] in self?.endWatching() }
    }

    // MARK: - The queue

    private func beginWatching(_ run: Int) {
        guard !watching else { return }
        watching = true
        ticket = run
        // Seed with whatever is already in flight so we don't announce stale partials as new.
        active = Self.scanPartials(in: Self.downloads)
        report(Report(changed: active, ended: [], finished: [], inFlight: !active.isEmpty))
        let fd = open(Self.downloads.path, O_EVTONLY)
        guard fd >= 0 else {
            // Nothing would ever be heard from the folder again, and nothing said so: a Mac
            // that has refused this app its Downloads folder, or that has none, simply never
            // showed a download. The reason is the system's own ("Operation not permitted").
            let reason = String(cString: strerror(errno))
            IslandLog.island.error("could not watch Downloads: \(reason, privacy: .public)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func endWatching() {
        guard watching else { return }
        watching = false
        source?.cancel()
        source = nil
        active.removeAll()
    }

    private func scan() {
        guard watching else { return }
        let folder = Self.downloads
        let current = Self.scanPartials(in: folder)
        var changed: [String: DownloadState] = [:]
        for (key, state) in current where active[key] != state { changed[key] = state }
        var ended: [String] = []
        var finished: [(state: DownloadState, url: URL)] = []
        for (key, old) in active where current[key] == nil {
            ended.append(key)
            let final = folder.appendingPathComponent(old.name)
            // A partial file goes away for more reasons than finishing: a cancelled download
            // takes it with it, and Chrome renames "Unconfirmed 123.crdownload" to the real
            // name part of the way through. Only a file that is actually there, with something
            // in it, is complete — see `finishedSize`.
            let size = try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int64
            guard let bytes = Self.finishedSize(size) else { continue }
            var done = old
            done.isComplete = true
            done.bytes = bytes
            finished.append((state: done, url: final))
        }
        active = current
        report(Report(changed: changed, ended: ended, finished: finished, inFlight: !current.isEmpty))
    }

    /// What one look at the folder found, for the main thread to act on.
    private struct Report {
        var changed: [String: DownloadState]
        var ended: [String]
        var finished: [(state: DownloadState, url: URL)]
        var inFlight: Bool
    }

    private func report(_ report: Report) {
        let run = ticket
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.generation == run else { return }
            self.apply(report)
        }
    }

    // MARK: - The main thread

    private func apply(_ report: Report) {
        let folder = Self.downloads
        for (key, state) in report.changed {
            shown.insert(key)
            var activity = IslandActivity(id: "download-" + key, kind: .download, content: .download(state), priority: 65)
            activity.openAction = .url(folder)
            ActivityCenter.shared.upsert(activity)
        }
        for key in report.ended {
            shown.remove(key)
            ActivityCenter.shared.end(id: "download-" + key)
        }
        for finished in report.finished {
            var alert = IslandActivity(id: "download-done", kind: .download, content: .download(finished.state),
                                       priority: 85, presentation: .expanded)
            alert.openAction = .url(finished.url)
            ActivityCenter.shared.showAlert(alert, duration: 4)
            // The shelf's own switch first, as a screenshot's is: with the shelf off there is
            // nowhere to see what was put on it.
            let prefs = Preferences.shared
            if prefs.shelfEnabled && prefs.addDownloadsToShelf { ShelfStore.shared.add([finished.url]) }
        }
        updateTimer(inFlight: report.inFlight)
    }

    /// The once-a-second look runs only while something is downloading: a partial file's
    /// size grows without the folder saying so.
    private func updateTimer(inFlight: Bool) {
        if !inFlight {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            scheduleTimer()
        }
    }

    /// Rebuilds the running timer at the current policy interval (e.g. after waking, or a
    /// battery/Low Power change). A no-op when no downloads are in flight.
    private func rescheduleTimer() {
        guard running, timer != nil else { return }
        scheduleTimer()
    }

    private func scheduleTimer() {
        let interval = Self.baseInterval * EnergyPolicy.shared.pollingMultiplier
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.scan() }
        }
        t.tolerance = interval * 0.2
        timer = t
    }

    // MARK: - Reading the folder

    /// The names in a folder listing that are a download still running, in the order given:
    /// by extension alone, and never a hidden file. Pure, and the gate every entry passes
    /// before the disk is asked a single thing about it — the listing is names only, so the
    /// hundreds of finished files beside the three that matter cost nothing but a look.
    static func partials(in names: [String]) -> [String] {
        names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            return partialExtensions.contains((name as NSString).pathExtension.lowercased())
        }
    }

    /// How big a download is, if what is under its own name once its partial file has gone is
    /// the download, finished; nil if it is not. Nothing there is not a download. Neither is an
    /// empty file: Firefox holds the finished name with an empty placeholder for as long as it
    /// is downloading, and a cancelled download can leave it behind for a moment after the
    /// `.part` has gone — which was announced as finished and put on the shelf. Pure.
    static func finishedSize(_ size: Int64?) -> Int64? {
        guard let size, size > 0 else { return nil }
        return size
    }

    private static func scanPartials(in folder: URL) -> [String: DownloadState] {
        var found: [String: DownloadState] = [:]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return found }
        for name in partials(in: names) {
            let url = folder.appendingPathComponent(name)
            let base = url.deletingPathExtension().lastPathComponent
            switch url.pathExtension.lowercased() {
            case "download":
                // Safari: a bundle with Info.plist tracking progress.
                let plist = url.appendingPathComponent("Info.plist")
                var bytes: Int64 = 0
                var total: Int64? = nil
                if let data = try? Data(contentsOf: plist),
                   let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    bytes = (dict["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value ?? 0
                    let t = (dict["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value ?? 0
                    if t > 0 { total = t }
                }
                found[name] = DownloadState(name: base, bytes: bytes, total: total, app: "Safari")
            case "crdownload":
                let title = base.hasPrefix("Unconfirmed ") ? "Download" : base
                found[name] = DownloadState(name: title, bytes: fileSize(url), total: nil, app: "Chrome")
            case "part":
                found[name] = DownloadState(name: base, bytes: fileSize(url), total: nil, app: "Firefox")
            default:
                continue
            }
        }
        return found
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
    }
}
