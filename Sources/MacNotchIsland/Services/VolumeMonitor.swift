import AppKit
import Combine

/// External disks: the one plugged in, the one pulled out, and the one that would not eject.
///
/// A Mac's own answer to a drive arriving is an icon on a desktop nobody can see under their
/// windows; its answer to one leaving badly is a dialog in the corner of the screen. The island
/// is where you are already looking, so it says both there — and because the reason people pull
/// a drive out without ejecting it is that ejecting it is a trip to Finder, the card it shows
/// has the Eject button on it.
final class VolumeMonitor: ObservableObject {
    /// One owner, so the Eject button on a card reaches the same monitor the hub started.
    static let shared = VolumeMonitor()

    /// Every external volume mounted right now. Published for the card and for anything else
    /// that wants to know what is attached.
    @Published private(set) var volumes: [DriveState] = []

    private var observers: [NSObjectProtocol] = []
    private var running = false
    /// Volumes macOS warned it was about to unmount. A clean eject announces itself first; a
    /// drive pulled out of the socket does not, and that difference is the only way to tell
    /// "safe to unplug" from "you were meant to eject that".
    private var expected: Set<String> = []

    private init() {}

    /// How long the "connected" and "ejected" alerts stay up.
    static let alertDuration: TimeInterval = 4

    /// The keys a mounted volume is asked for. `volumeIsBrowsable` is what tells a real disk
    /// apart from the dozens of system mounts every Mac carries.
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsBrowsableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    func start() {
        guard !running else { return }
        running = true
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
                self?.mounted(note)
            },
            center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
                guard let url = Self.volumeURL(from: note) else { return }
                self?.expected.insert(url.path)
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
                self?.unmounted(note)
            },
            center.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            },
        ]
        refresh()
    }

    func stop() {
        guard running else { return }
        running = false
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        expected.removeAll()
        volumes = []
    }

    // MARK: - What is attached

    /// Re-reads every mounted volume. Cheap enough to do on any change: a Mac has a handful.
    func refresh() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { Self.state(of: $0) }
    }

    /// Reads one volume, or returns nil where it is not an external disk anybody would think
    /// of as "a drive": the boot volume, the system's own read-only mounts, and the hidden
    /// helpers all fall out here.
    static func state(of url: URL, event: DriveState.Event = .connected) -> DriveState? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let ejectable = values.volumeIsEjectable ?? false
        let removable = values.volumeIsRemovable ?? false
        guard isWorthMentioning(internalDisk: values.volumeIsInternal ?? false,
                                ejectable: ejectable, removable: removable,
                                browsable: values.volumeIsBrowsable ?? false) else { return nil }
        let name = values.volumeName ?? url.lastPathComponent
        return DriveState(name: name,
                          path: url.path,
                          total: Int64(values.volumeTotalCapacity ?? 0),
                          free: Int64(values.volumeAvailableCapacity ?? 0),
                          event: event,
                          isEjectable: ejectable || removable)
    }

    /// Whether a mounted volume is a disk anybody would call a drive.
    ///
    /// Browsable rules out the dozens of system mounts a Mac carries that nothing can open; the
    /// rest rules out the volume the Mac boots from and its siblings, which are not going
    /// anywhere and are not news. Everything else — a stick, an SSD, a card, a disk image, a
    /// share — is something that arrived, and something that has to be got out again.
    ///
    /// Pure, so the rule can be tested without a disk to plug in.
    static func isWorthMentioning(internalDisk: Bool, ejectable: Bool, removable: Bool, browsable: Bool) -> Bool {
        browsable && (!internalDisk || ejectable || removable)
    }

    // MARK: - Arriving and leaving

    private func mounted(_ note: Notification) {
        refresh()
        guard let url = Self.volumeURL(from: note), let state = Self.state(of: url) else { return }
        show(state, id: "drive-" + state.path)
    }

    private func unmounted(_ note: Notification) {
        guard let url = Self.volumeURL(from: note) else { return refresh() }
        // Read it before the list is rebuilt: once it is gone the only thing left to say about
        // it is its name, and that is what the alert is for.
        let known = volumes.first { $0.path == url.path }
        let announced = expected.remove(url.path) != nil
        refresh()
        guard let known else { return }
        var state = known
        state.event = announced ? .ejected : .surprise
        show(state, id: "drive-" + state.path)
    }

    private static func volumeURL(from note: Notification) -> URL? {
        note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    }

    private func show(_ state: DriveState, id: String) {
        var activity = IslandActivity(id: id, kind: .drive, content: .drive(state),
                                      priority: 80, presentation: .expanded)
        activity.openAction = .url(URL(fileURLWithPath: state.path))
        ActivityCenter.shared.showAlert(activity, duration: Self.alertDuration)
    }

    // MARK: - Ejecting

    /// Unmount and eject, and say which of the two things happened. Called from the card's
    /// Eject button, which is the whole point of the card.
    func eject(_ state: DriveState) {
        let url = URL(fileURLWithPath: state.path)
        // Marked before the call: an eject that unmounts without announcing itself first must
        // still read as a clean one.
        expected.insert(state.path)
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            // The unmount notification does the talking; this only covers the case where the
            // call succeeds without one arriving.
            refresh()
        } catch {
            IslandLog.island.error("eject refused: \(error.localizedDescription, privacy: .public)")
            expected.remove(state.path)
            var refused = state
            refused.event = .busy
            show(refused, id: "drive-" + state.path)
        }
    }
}
