import Combine
import Foundation

/// Whether a Focus is on right now, as the island last saw it — something a view can watch.
///
/// Its own object rather than a flag on the monitor, for two reasons. A plain flag changed
/// under everything that showed it, so the rail's Focus button stayed lit or dark until
/// something else happened to redraw it. And the monitor's switch is the Focus *alerts*
/// switch: whether a Focus is on is true whatever that says, so switching the alerts off no
/// longer makes it read as off. Main thread only.
final class FocusStatus: ObservableObject {
    static let shared = FocusStatus()

    @Published private(set) var isOn = false

    private init() {}

    /// Announced only when it has changed: the monitor reads the file on every change to the
    /// folder, and most of those are not a Focus turning on or off.
    fileprivate func publish(_ on: Bool) {
        if isOn != on { isOn = on }
    }
}

/// Focus (Do Not Disturb, Work, Sleep…): whether one is on, and the on/off alerts. macOS keeps
/// the active Focus assertions in ~/Library/DoNotDisturb/DB; the folder is watched for changes.
///
/// Watching and alerting are separate. The watch keeps `FocusStatus` current, which the rail
/// and the alert queue read, and runs whatever the alerts switch says; `alertsEnabled` decides
/// only whether a change is also announced in the island.
final class FocusMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var lastMode: String?
    private var started = false

    /// Whether a Focus turning on or off is announced in the island: the Focus switch.
    var alertsEnabled = false

    /// Whether a Focus is on right now, as the island last saw it. Read by the alert queue,
    /// which holds back what can wait while one is on. Forwarded from `FocusStatus`, which is
    /// what a view that shows it should observe.
    static var isOn: Bool { FocusStatus.shared.isOn }

    private var dbDirectory: URL { Self.dbDirectory }

    static var dbDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    /// Whether the Focus database can actually be read: the file the monitor reads, read.
    ///
    /// It lives in the user's own Library, and macOS guards that folder all the same. Asking
    /// `isReadableFile` only consults the file's permissions, which say yes — so Privacy said
    /// "Readable" on the very Mac where every read was being refused and no Focus was ever
    /// seen. Only a read that comes back with something is an answer.
    static var isReadable: Bool {
        (try? Data(contentsOf: dbDirectory.appendingPathComponent("Assertions.json"))) != nil
    }

    func start() {
        guard !started else { return }
        started = true
        let mode = currentMode()
        lastMode = mode?.identifier
        // Read once at the start as well as on every change: a Mac that was already in a
        // Focus when the island launched is still in one.
        FocusStatus.shared.publish(mode != nil)
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
        // this last saw. Only a stop does this — the alerts switch going off does not.
        FocusStatus.shared.publish(false)
    }

    private struct Mode {
        var identifier: String
        var name: String
        var symbol: String
        var tint: String
    }

    private func check() {
        let mode = currentMode()
        FocusStatus.shared.publish(mode != nil)
        let id = mode?.identifier
        guard id != lastMode else { return }
        let previous = lastMode
        // Kept current with the alerts off too, so switching them on later does not announce
        // a change that happened while they were off.
        lastMode = id
        guard alertsEnabled else { return }

        if let mode {
            show(FocusState(name: mode.name, symbol: mode.symbol, isOn: true, tint: mode.tint))
        } else if let previous, let old = describe(previous) {
            show(FocusState(name: old.name, symbol: old.symbol, isOn: false, tint: old.tint))
        }
    }

    private func show(_ state: FocusState) {
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
