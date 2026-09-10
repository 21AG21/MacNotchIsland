import AppKit
import Combine
import CoreWLAN

/// The networks this Mac can see, and joining one of them.
///
/// The one thing missing before the island could stand in for Control Centre: a switch that
/// turns Wi-Fi on and off is not the same as a list you can pick a café out of.
///
/// Read from the system's own last scan rather than asking the radio to sweep the band every
/// time somebody opens a panel — a scan costs power and a second of the interface's attention,
/// and macOS is scanning anyway. A fresh sweep is asked for once when the section appears and
/// then only on the refresh interval, and only while somebody is looking at it.
///
/// Every word CoreWLAN says here — the name of the network, the profiles this Mac keeps, the
/// last scan the system took — is a round trip to the Wi-Fi daemon, and the panel doing the
/// asking is the one being animated open at that moment. So none of it happens on the main
/// thread: a pass runs on the queue below and hands its answer back to be shown.
final class WiFiScanner: ObservableObject {
    static let shared = WiFiScanner()

    /// One network, as the list shows it.
    struct Network: Identifiable, Equatable {
        var ssid: String
        var strength: Int
        var isSecure: Bool
        var isCurrent: Bool
        /// Whether this Mac has joined it before, and so can join it again without being
        /// asked for anything.
        var isKnown: Bool
        var id: String { ssid }

        /// Which of the four bars the strength lands on. RSSI runs from about -30 (next to
        /// the router) to -90 (the edge of nothing).
        var bars: Int { WiFiScanner.bars(forRSSI: strength) }
    }

    @Published private(set) var networks: [Network] = []
    @Published private(set) var isScanning = false
    /// What the interface says it is on, whether or not the list has caught up.
    @Published private(set) var current: String?

    /// How often the list is refreshed while somebody is looking at it.
    static let refreshInterval: TimeInterval = 12

    /// Where the waiting happens. Serial, so a sweep and the read that follows it cannot
    /// overtake each other.
    private let queue = DispatchQueue(label: "com.macnotchisland.wifi", qos: .utility)
    /// Main queue only, like the three published properties and the viewer count — the queue
    /// above touches nothing but the interface.
    private var pass = RadioPass()

    private var viewers = 0
    private var timer: Timer?

    private init() {}

    /// Fills in a list for the gallery, which has no radio and no location.
    func seedForGallery(_ list: [Network]) {
        networks = Self.ordered(list)
        current = list.first { $0.isCurrent }?.ssid
        isScanning = false
    }

    // MARK: - Watching

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        refresh(scan: true)
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh(scan: true)
        }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads the list, off the main thread, and shows the answer when it comes. With
    /// `scan`, the interface is asked to sweep the band first — slower again, and the reason
    /// the list says "Looking…" while it happens.
    func refresh(scan: Bool = false) {
        guard pass.start() else { return }
        if scan, !isScanning { isScanning = true }
        queue.async { [weak self] in
            let reading = Self.take(scan: scan)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pass.finish()
                if self.isScanning { self.isScanning = false }
                // A Mac with no Wi-Fi interface has no list, which is what an empty one says.
                let fresh = reading?.networks ?? []
                if self.networks != fresh { self.networks = fresh }
                if self.current != reading?.current { self.current = reading?.current }
            }
        }
    }

    /// What one look at the interface comes back with. The list and the name of the network
    /// on it are read a few milliseconds apart, and a row ticked as joined that the name
    /// disagrees with reads as a bug — so they travel together or not at all.
    private struct Reading {
        var networks: [Network]
        var current: String?
    }

    /// The blocking half, and the only part that runs on the queue.
    private static func take(scan: Bool) -> Reading? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        if scan {
            // A scan that fails — no permission, the radio busy, Wi-Fi off — is not an error
            // worth a word on screen: the cached list is what everybody sees anyway.
            _ = try? interface.scanForNetworks(withSSID: nil)
        }
        // The networks this Mac has joined before, which are the ones it can join again on
        // its own. `networkProfiles` is an ordered set of `CWNetworkProfile`.
        let profiles = interface.configuration()?.networkProfiles.array ?? []
        let known = Set(profiles.compactMap { ($0 as? CWNetworkProfile)?.ssid })
        let seen = interface.cachedScanResults() ?? []
        let live = interface.ssid()
        var best: [String: Network] = [:]
        for network in seen {
            guard let ssid = network.ssid, !ssid.isEmpty else { continue }
            let candidate = Network(ssid: ssid,
                                    strength: network.rssiValue,
                                    isSecure: Self.isSecure(network),
                                    isCurrent: ssid == live,
                                    isKnown: known.contains(ssid))
            // One row per name: a network with two access points is one network to a person.
            if let existing = best[ssid], existing.strength >= candidate.strength { continue }
            best[ssid] = candidate
        }
        return Reading(networks: Self.ordered(Array(best.values)), current: live)
    }

    // MARK: - Joining

    /// Joins a network. One this Mac already knows needs nothing from anybody; one it does not
    /// needs a password, and there is no honest way to ask for one from a panel that closes
    /// when the pointer leaves — so that goes to the pane of System Settings that can.
    ///
    /// Finding the network to join means reading the system's last scan, which is a round trip
    /// like any other, so the whole of this happens on the queue: the tap that starts it is on
    /// a panel that is still animating.
    func join(_ network: Network) {
        queue.async { [weak self] in
            guard let interface = CWWiFiClient.shared().interface() else { return }
            let target = (interface.cachedScanResults() ?? []).first { $0.ssid == network.ssid }
            guard network.isKnown || !network.isSecure, let target else {
                return DispatchQueue.main.async { Self.openSettings() }
            }
            var joined = false
            do {
                try interface.associate(to: target, password: nil)
                joined = true
            } catch {
                IslandLog.network.error("could not join \(network.ssid, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async {
                if !joined { Self.openSettings() }
                self?.refresh()
            }
        }
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Pure rules

    /// The order the list is read in: whatever is joined first, then the strongest.
    static func ordered(_ networks: [Network]) -> [Network] {
        networks.sorted { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            if a.strength != b.strength { return a.strength > b.strength }
            return a.ssid.localizedStandardCompare(b.ssid) == .orderedAscending
        }
    }

    /// Four bars from an RSSI. -50 and better is full; below -85 is one bar and a prayer.
    static func bars(forRSSI rssi: Int) -> Int {
        switch rssi {
        case (-50)...: return 4
        case (-65)..<(-50): return 3
        case (-75)..<(-65): return 2
        default: return 1
        }
    }

    /// Whether joining it would need a password: anything that is not an open network.
    static func isSecure(_ network: CWNetwork) -> Bool {
        !network.supportsSecurity(.none)
    }
}

// MARK: - One pass at a time

/// The bookkeeping that keeps a radio to one reader.
///
/// Both the network list and the rail's switches are read on a queue now, and both are driven
/// by a timer that does not wait to be asked twice. Two passes in flight together are two sets
/// of round trips for one answer, and the slower of them lands last carrying the older news —
/// so a pass that finds one already running stands down instead.
///
/// Lives on the main queue with everything else that decides what is shown.
struct RadioPass {
    private(set) var isRunning = false

    /// Whether the caller is the one that gets to go. Balanced by `finish()` when its answer
    /// has been shown.
    mutating func start() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    mutating func finish() {
        isRunning = false
    }
}
