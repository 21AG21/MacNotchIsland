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

    /// Re-reads the list. With `scan`, asks the interface to sweep first — which blocks, so it
    /// happens off the main thread and the answer is read back from the cache either way.
    func refresh(scan: Bool = false) {
        guard let interface = CWWiFiClient.shared().interface() else {
            networks = []
            current = nil
            return
        }
        current = interface.ssid()
        guard scan else { return read(interface) }
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // A scan that fails — no permission, the radio busy, Wi-Fi off — is not an error
            // worth a word on screen: the cached list is what everybody sees anyway.
            _ = try? interface.scanForNetworks(withSSID: nil)
            DispatchQueue.main.async {
                self?.isScanning = false
                self?.read(interface)
            }
        }
    }

    private func read(_ interface: CWInterface) {
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
        networks = Self.ordered(Array(best.values))
    }

    // MARK: - Joining

    /// Joins a network. One this Mac already knows needs nothing from anybody; one it does not
    /// needs a password, and there is no honest way to ask for one from a panel that closes
    /// when the pointer leaves — so that goes to the pane of System Settings that can.
    func join(_ network: Network) {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        guard network.isKnown || !network.isSecure else { return Self.openSettings() }
        let target = (interface.cachedScanResults() ?? []).first { $0.ssid == network.ssid }
        guard let target else { return Self.openSettings() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
