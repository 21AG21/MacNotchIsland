import Foundation

/// Focus (Do Not Disturb, Work, Sleep…) on/off alerts. macOS keeps the active Focus
/// assertions in ~/Library/DoNotDisturb/DB; the folder is watched for changes.
final class FocusMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var lastMode: String?
    private var started = false

    /// Whether a Focus is on right now, as the island last saw it. Read by the alert queue,
    /// which holds back what can wait while one is on.
    private(set) static var isOn = false

    private var dbDirectory: URL { Self.dbDirectory }

    static var dbDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    /// Whether the Focus database can be read (it lives in the user's own Library, but a
    /// future macOS could move it or gate it).
    static var isReadable: Bool {
        FileManager.default.isReadableFile(atPath: dbDirectory.appendingPathComponent("ModeConfigurations.json").path)
    }

    func start() {
        guard !started else { return }
        started = true
        let mode = currentMode()
        lastMode = mode?.identifier
        // Read once at the start as well as on every change: a Mac that was already in a
        // Focus when the island launched is still in one.
        Self.isOn = mode != nil
        fd = open(dbDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.check() }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        src.resume()
        source = src
    }

    func stop() {
        guard started else { return }
        started = false
        source?.cancel()
        source = nil
        // Nothing is watching any more, so nothing may be held back on the strength of what
        // this last saw.
        Self.isOn = false
    }

    private struct Mode {
        var identifier: String
        var name: String
        var symbol: String
        var tint: String
    }

    private func check() {
        let mode = currentMode()
        let id = mode?.identifier
        guard id != lastMode else { return }
        let previous = lastMode
        lastMode = id

        if let mode {
            show(FocusState(name: mode.name, symbol: mode.symbol, isOn: true, tint: mode.tint))
        } else if let previous, let old = describe(previous) {
            show(FocusState(name: old.name, symbol: old.symbol, isOn: false, tint: old.tint))
        }
    }

    private func show(_ state: FocusState) {
        Self.isOn = state.isOn
        let activity = IslandActivity(id: "focus", kind: .focus, content: .focus(state), priority: 85)
        ActivityCenter.shared.showAlert(activity)
    }

    private func currentMode() -> Mode? {
        let url = dbDirectory.appendingPathComponent("Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return nil }
        for entry in entries {
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { continue }
            for record in records {
                if let details = record["assertionDetails"] as? [String: Any],
                   let id = details["assertionDetailsModeIdentifier"] as? String {
                    return describe(id)
                }
            }
        }
        return nil
    }

    private func describe(_ identifier: String) -> Mode? {
        var name = "Focus"
        var symbol = "moon.fill"
        var tint = "indigo"
        if identifier.hasSuffix(".default") { name = "Do Not Disturb" }
        let url = dbDirectory.appendingPathComponent("ModeConfigurations.json")
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = json["data"] as? [[String: Any]] {
            for entry in entries {
                guard let configs = entry["modeConfigurations"] as? [String: Any],
                      let config = configs[identifier] as? [String: Any],
                      let mode = config["mode"] as? [String: Any] else { continue }
                if let n = mode["name"] as? String, !n.isEmpty { name = n }
                if let s = mode["symbolImageName"] as? String, !s.isEmpty { symbol = s }
                if let t = mode["tintColorName"] as? String, !t.isEmpty { tint = t }
            }
        }
        return Mode(identifier: identifier, name: name, symbol: symbol, tint: tint)
    }
}
