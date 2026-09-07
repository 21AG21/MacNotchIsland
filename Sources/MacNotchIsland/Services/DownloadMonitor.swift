import AppKit

/// Turns in-progress browser downloads in ~/Downloads into Live Activities
/// (Safari `.download` bundles report exact progress; Chrome `.crdownload` and Firefox
/// `.part` files report the bytes received so far) and shows a "Download complete" alert.
final class DownloadMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var timer: Timer?
    private var active: [String: DownloadState] = [:]
    private var running = false

    private var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func start() {
        guard !running else { return }
        running = true
        // Seed with whatever is already in flight so we don't announce stale partials as new.
        active = scanPartials()
        for (key, state) in active { publish(key: key, state: state) }
        fd = open(downloads.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in self?.scan() }
            src.setCancelHandler { [weak self] in
                if let fd = self?.fd, fd >= 0 { close(fd) }
                self?.fd = -1
            }
            src.resume()
            source = src
        }
        updateTimer()
    }

    func stop() {
        guard running else { return }
        running = false
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
        for key in active.keys { ActivityCenter.shared.end(id: "download-" + key) }
        active.removeAll()
    }

    private func updateTimer() {
        if active.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.scan() }
        }
    }

    private func scan() {
        guard running else { return }
        let current = scanPartials()

        for (key, state) in current {
            if active[key] != state { publish(key: key, state: state) }
        }

        for (key, old) in active where current[key] == nil {
            ActivityCenter.shared.end(id: "download-" + key)
            let final = downloads.appendingPathComponent(old.name)
            let exists = FileManager.default.fileExists(atPath: final.path)
            var done = old
            done.isComplete = true
            if exists, let size = try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int64 { done.bytes = size }
            var alert = IslandActivity(id: "download-done", kind: .download, content: .download(done), priority: 85, presentation: .expanded)
            alert.openAction = exists ? .url(final) : nil
            ActivityCenter.shared.showAlert(alert, duration: 4)
            if exists && Preferences.shared.addDownloadsToShelf { ShelfStore.shared.add([final]) }
        }

        active = current
        updateTimer()
    }

    private func publish(key: String, state: DownloadState) {
        active[key] = state
        var activity = IslandActivity(id: "download-" + key, kind: .download, content: .download(state), priority: 65)
        activity.openAction = .url(downloads)
        ActivityCenter.shared.upsert(activity)
    }

    private func scanPartials() -> [String: DownloadState] {
        var found: [String: DownloadState] = [:]
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return found }
        for url in items {
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent
            switch ext {
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
                found[url.lastPathComponent] = DownloadState(name: base, bytes: bytes, total: total, app: "Safari")
            case "crdownload":
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                let name = base.hasPrefix("Unconfirmed ") ? "Download" : base
                found[url.lastPathComponent] = DownloadState(name: name, bytes: size, total: nil, app: "Chrome")
            case "part":
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                found[url.lastPathComponent] = DownloadState(name: base, bytes: size, total: nil, app: "Firefox")
            default:
                continue
            }
        }
        return found
    }
}
