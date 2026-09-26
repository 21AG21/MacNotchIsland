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
    /// Which Focus is on, as the database names it, or nil while none is. The rail's Focus
    /// popover marks this one; `isOn` stays its own value because most of what watches the
    /// Focus only cares whether there is one, and should not redraw when Work becomes Sleep.
    @Published private(set) var active: FocusMode?

    private init() {}

    /// Announced only when it has changed: the monitor reads the file on every change to the
    /// folder, and most of those are not a Focus turning on or off.
    fileprivate func publish(_ mode: FocusMode?) {
        if active != mode { active = mode }
        if isOn != (mode != nil) { isOn = mode != nil }
    }
}

/// One of this Mac's Focus modes, as `ModeConfigurations.json` describes it: what it is called,
/// its glyph and its colour. The name is what the "Set Focus" shortcut is handed when the rail's
/// popover picks it, so it is the name the Focus pane shows, not the identifier.
struct FocusMode: Equatable, Hashable, Identifiable {
    let identifier: String
    let name: String
    let symbol: String
    let tint: String

    var id: String { identifier }

    /// Do Not Disturb is the one mode every Mac has, and the one Control Centre lists first.
    var isDoNotDisturb: Bool { identifier.hasSuffix(".default") }

    static let doNotDisturb = FocusMode(identifier: "com.apple.donotdisturb.mode.default", name: "Do Not Disturb",
                                        symbol: "moon.fill", tint: "indigo")

    /// The modes in a `ModeConfigurations.json`, Do Not Disturb first and the rest by name.
    ///
    /// The file is `data[].modeConfigurations`, a dictionary from each mode's identifier to its
    /// configuration, and the part worth having is the configuration's `mode`: `name`,
    /// `modeIdentifier`, `symbolImageName` and `tintColorName`. A dictionary has no order, so
    /// the list is given one — the order would otherwise change between two openings of the
    /// same popover. A mode with no name is left out, since the name is the one thing a pick
    /// can hand the shortcut; Do Not Disturb, whose name the system has always had, keeps it.
    /// Anything that is not that shape is no modes at all rather than a guess.
    ///
    /// Pure, so it can be tested against a fixture rather than against somebody's Mac.
    static func decode(_ data: Data) -> [FocusMode] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var modes: [FocusMode] = []
        for entry in entries {
            guard let configs = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (key, value) in configs {
                guard let config = value as? [String: Any], let mode = config["mode"] as? [String: Any] else { continue }
                let identifier = Self.text(mode["modeIdentifier"]) ?? key
                let fallback = identifier.hasSuffix(".default") ? doNotDisturb.name : nil
                guard let name = Self.text(mode["name"]) ?? fallback, seen.insert(identifier).inserted else { continue }
                modes.append(FocusMode(identifier: identifier, name: name,
                                       symbol: Self.text(mode["symbolImageName"]) ?? "moon.fill",
                                       tint: tint(from: mode["tintColorName"] as? String)))
            }
        }
        // By name as Finder sorts names (`localizedStandardCompare`): "Écriture" with the Es
        // rather than after "Work", where a comparison of bare code points put it, and
        // "Study 2" before "Study 10".
        return modes.sorted { a, b in
            if a.isDoNotDisturb != b.isDoNotDisturb { return a.isDoNotDisturb }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.identifier < b.identifier
        }
    }

    /// The mode with this identifier, or what the island has always called one it could not
    /// look up: Do Not Disturb by its identifier, anything else plain "Focus" with a moon.
    static func describe(_ identifier: String, in modes: [FocusMode]) -> FocusMode {
        if let mode = modes.first(where: { $0.identifier == identifier }) { return mode }
        return FocusMode(identifier: identifier,
                         name: identifier.hasSuffix(".default") ? doNotDisturb.name : "Focus",
                         symbol: "moon.fill", tint: "indigo")
    }

    /// The colour's name as `Color.named` spells it. The database writes UIKit's names —
    /// "systemIndigoColor" — and handed over as they stood they matched none of the island's,
    /// so every Focus was drawn white. A name that is already plain, or a hex value, is kept.
    static func tint(from raw: String?) -> String {
        guard var name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "indigo" }
        if name.hasPrefix("#") { return name }
        if name.lowercased().hasPrefix("system") { name.removeFirst("system".count) }
        if name.lowercased().hasSuffix("color") { name.removeLast("color".count) }
        return name.isEmpty ? "indigo" : name.lowercased()
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return string
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
    /// A read of the database is already waiting to happen. See `start`.
    private var checkPending = false

    /// How long after the folder changes the database is read: long enough for the write that
    /// raised the event to have finished.
    static let settleDelay: TimeInterval = 0.3

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
        FocusStatus.shared.publish(mode)
        let fd = open(dbDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.fd = fd
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        // One read for a burst of events, not one per event. A Focus turning on or off is
        // more than one change to the folder, and every event queued a read and parse of the
        // database of its own on the main thread, landing a few milliseconds apart and all
        // saying the same thing. The first event asks for a read; the rest, until it happens, are
        // already answered by it, since it comes after them. An event after the read has
        // started asks for another, so the last change is never missed.
        src.setEventHandler { [weak self] in
            guard let self, !self.checkPending else { return }
            self.checkPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
                guard let self else { return }
                self.checkPending = false
                guard self.started else { return }
                self.check()
            }
        }
        // Closes the descriptor this source was made with, not whichever one `self.fd` holds
        // when the handler runs: a cancel handler runs later, and a stop and a start in
        // between would have had it close the new watch's descriptor and leave its own open.
        // The same as `ScreenshotMonitor.bind`.
        src.setCancelHandler { [weak self] in
            close(fd)
            if self?.fd == fd { self?.fd = -1 }
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
        FocusStatus.shared.publish(nil)
    }

    private func check() {
        let mode = currentMode()
        FocusStatus.shared.publish(mode)
        let id = mode?.identifier
        guard id != lastMode else { return }
        let previous = lastMode
        // Kept current with the alerts off too, so switching them on later does not announce
        // a change that happened while they were off.
        lastMode = id
        guard alertsEnabled else { return }

        if let mode {
            show(FocusState(name: mode.name, symbol: mode.symbol, isOn: true, tint: mode.tint))
        } else if let previous {
            let old = describe(previous)
            show(FocusState(name: old.name, symbol: old.symbol, isOn: false, tint: old.tint))
        }
    }

    private func show(_ state: FocusState) {
        let activity = IslandActivity(id: "focus", kind: .focus, content: .focus(state), priority: 85)
        ActivityCenter.shared.showAlert(activity)
    }

    private func currentMode() -> FocusMode? {
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

    private func describe(_ identifier: String) -> FocusMode {
        FocusMode.describe(identifier, in: Self.readModes())
    }

    /// This Mac's Focus modes, read from the same folder as the one that is on. Empty when the
    /// file cannot be read — which, on a macOS that guards the folder, is without Full Disk
    /// Access — since every Mac has at least Do Not Disturb in it when it can.
    static func readModes() -> [FocusMode] {
        guard let data = try? Data(contentsOf: dbDirectory.appendingPathComponent("ModeConfigurations.json")) else { return [] }
        return FocusMode.decode(data)
    }
}
