import AppKit
import Combine
import CoreLocation
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
///
/// An NSObject because it is a delegate twice over: Location's, see `needsLocation`, and
/// CoreWLAN's, which says when the radio is switched or the network changes (`startEvents`).
final class WiFiScanner: NSObject, ObservableObject, CLLocationManagerDelegate, CWEventDelegate {
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
    /// Whether the names are being kept from us because Location has been refused.
    ///
    /// Since macOS 14 CoreWLAN only tells an app the names of the networks around it — the one
    /// it is on included — once Location allows it, because a list of network names is a good
    /// way to tell where somebody is. Without it every network in the scan comes back with no
    /// name, a nameless network is skipped, and the column said "Nothing in range" on a Mac
    /// sitting on a perfectly good network. Published so the column can say what is actually
    /// wrong, and offer the pane that puts it right.
    @Published private(set) var needsLocation = false
    /// Whether the names are being kept from us because Location has never been asked for.
    ///
    /// The list used to ask the moment Controls appeared — so arriving on the section, even on
    /// a Mac with no Wi-Fi to list, put a Location prompt on screen because somebody looked.
    /// Now the column says the names need Location and offers an "Allow Location" pill, and
    /// the question is asked from that, see `askForLocation`.
    @Published private(set) var locationUnasked = false

    /// How often the list is refreshed while somebody is looking at it.
    static let refreshInterval: TimeInterval = 12

    /// The refresh's interval at a given energy multiplier. Pure, so it is tested.
    ///
    /// Each refresh is an active sweep of the band. It ran every twelve seconds whatever the
    /// policy said — on battery, in Low Power Mode, and under a lock with the panel left open —
    /// and it slows now the way the rail's radios do (`SystemToggles.scaledPollInterval`).
    static func scaledRefreshInterval(multiplier: Double) -> TimeInterval {
        refreshInterval * max(1, multiplier)
    }

    /// How long after the island switches the radio on the list is asked again: a radio that
    /// has just come up has swept nothing and joined nothing, and the first answer is empty.
    static let powerOnSettle: TimeInterval = 4

    /// Whether a click on a row joins it. Not the network the Mac is on: joining it again went
    /// through `associate(to:password:)` and could drop the connection it already had, or send
    /// the user to Wi-Fi Settings for a password nobody needed. Pure, so it is tested.
    static func joins(_ network: Network) -> Bool {
        !network.isCurrent
    }

    /// Where the waiting happens. Serial, so a sweep and the read that follows it cannot
    /// overtake each other.
    private let queue = DispatchQueue(label: "com.macnotchisland.wifi", qos: .utility)
    /// Main queue only, like the three published properties and the viewer count — the queue
    /// above touches nothing but the interface.
    private var pass = RadioPass()

    private var viewers = 0
    private var timer: Timer?
    private var energyCancellable: AnyCancellable?
    /// Held for as long as the app runs: a manager let go before macOS has answered takes its
    /// question with it. Made the first time the list is looked at, which asks nothing — only
    /// the pill does. Main queue only, where its delegate calls arrive.
    private var location: CLLocationManager?

    private override init() {
        super.init()
    }

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
        noteLocation(locationManager().authorizationStatus)
        refresh(scan: true)
        scheduleTimer()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
        startEvents()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        energyCancellable = nil
        stopEvents()
    }

    /// The refresh at the policy's current interval, rebuilt only when that has changed: a
    /// rebuild pushes the next sweep back by a whole interval.
    private func scheduleTimer() {
        guard viewers > 0 else { return }
        let interval = Self.scaledRefreshInterval(multiplier: EnergyPolicy.shared.pollingMultiplier)
        if let timer, abs(timer.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh(scan: true) }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The island's own switch has just been thrown (`SystemToggles.toggleWiFi`). Switched on,
    /// the list said "Nothing in range" and kept its tick on the old network until the timer
    /// came round, twelve seconds later; it is asked now, and again once the radio has had time
    /// to sweep and join. Main thread.
    func radioSwitched(on: Bool) {
        guard viewers > 0 else { return }
        refresh(scan: on)
        guard on else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.powerOnSettle) { [weak self] in
            guard let self, self.viewers > 0 else { return }
            self.refresh(scan: true)
        }
    }

    // MARK: - CoreWLAN's own word

    /// Asks CoreWLAN to say when the radio is switched, the network changes or the link comes
    /// and goes, for as long as the list is on screen — whoever did the switching: the menu
    /// bar, System Settings, the island. Monitoring asks nothing of the user; the names in what
    /// is read afterwards are still Location's to give. Each call is a round trip to the Wi-Fi
    /// daemon, so they are made on the queue. A refusal leaves the timer to catch the change.
    private func startEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            let client = CWWiFiClient.shared()
            client.delegate = self
            for event in [CWEventType.powerDidChange, .ssidDidChange, .linkDidChange] {
                do {
                    try client.startMonitoringEvent(with: event)
                } catch {
                    IslandLog.network.notice("wi-fi events not available: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
        }
    }

    private func stopEvents() {
        queue.async {
            do {
                try CWWiFiClient.shared().stopMonitoringAllEvents()
            } catch {
                IslandLog.network.notice("could not stop wi-fi events: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// CoreWLAN calls these on a queue of its own; the list is refreshed from the main thread.
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.heardFromTheRadio(scan: true) }
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.heardFromTheRadio(scan: false) }
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.heardFromTheRadio(scan: false) }
    }

    /// Main thread. Only while somebody is looking: a late event after the list has gone asks
    /// nothing of the radio.
    private func heardFromTheRadio(scan: Bool) {
        guard viewers > 0 else { return }
        refresh(scan: scan)
    }

    // MARK: - Location, for the names

    /// The manager, made the first time it is needed. Making one and reading its status asks
    /// nothing of anybody.
    private func locationManager() -> CLLocationManager {
        if let location { return location }
        let manager = CLLocationManager()
        manager.delegate = self
        location = manager
        return manager
    }

    /// The column's "Allow Location": the one place Location is asked for. Never asked, it asks;
    /// otherwise the answer is System Settings' to change, and that is where it goes.
    func askForLocation() {
        let manager = locationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            SystemSettingsPane.location.open()
        }
        noteLocation(manager.authorizationStatus)
    }

    private func noteLocation(_ status: CLAuthorizationStatus) {
        let withheld = Self.namesWithheld(status)
        if needsLocation != withheld { needsLocation = withheld }
        let unasked = Self.namesUnasked(status)
        if locationUnasked != unasked { locationUnasked = unasked }
    }

    /// Whether the names are kept from us only because nobody has asked yet, which the column
    /// offers to do rather than doing it because the section appeared.
    static func namesUnasked(_ status: CLAuthorizationStatus) -> Bool {
        status == .notDetermined
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        noteLocation(manager.authorizationStatus)
        // Allowed while the list is open: the names are there to be read now, so read them
        // rather than leave the column empty until the timer comes round.
        if viewers > 0 { refresh() }
    }

    /// Whether Location's answer is one that keeps the names from us. Not yet asked is not a
    /// refusal — see `namesUnasked` — and the list is read again the moment it is answered.
    static func namesWithheld(_ status: CLAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
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
                let asked = self.pass.finish()
                if self.isScanning { self.isScanning = false }
                // A Mac with no Wi-Fi interface has no list, which is what an empty one says.
                let fresh = reading?.networks ?? []
                if self.networks != fresh { self.networks = fresh }
                if self.current != reading?.current { self.current = reading?.current }
                // Somebody joined a network, or the timer came round, while this was in the
                // air. Their answer is the one they are waiting on.
                if asked { self.refresh() }
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
        // Off, there is nothing to sweep and nothing in range: the column says "Off" rather than
        // showing a list, and the sweep used to be asked for anyway, every twelve seconds.
        guard interface.powerOn() else { return Reading(networks: [], current: nil) }
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
        guard Self.joins(network) else { return }
        queue.async { [weak self] in
            guard let interface = CWWiFiClient.shared().interface() else { return }
            let target = (interface.cachedScanResults() ?? []).first { $0.ssid == network.ssid }
            guard network.isKnown || !network.isSecure, let target else {
                DispatchQueue.main.async { Self.openSettings() }
                return
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
    /// Somebody asked while a pass was already in the air. Standing down is right — two sets
    /// of round trips for one answer — but standing down and forgetting is not: the ask that
    /// matters most is the one right after a switch has been thrown or a network joined, and
    /// dropping it left the rail showing the old state until the next tick came round, which
    /// on the network list is twelve seconds of a tick against the wrong row.
    private(set) var isPending = false

    init() {}

    /// Whether the caller is the one that gets to go. Balanced by `finish()` when its answer
    /// has been shown.
    mutating func start() -> Bool {
        guard !isRunning else {
            isPending = true
            return false
        }
        isRunning = true
        return true
    }

    /// Ends this pass, and says whether somebody asked for another while it was running. One
    /// more at most: a second ask during *that* pass sets the flag again, so a caller in a
    /// hurry gets an answer promptly without a queue of them piling up behind it.
    mutating func finish() -> Bool {
        isRunning = false
        guard isPending else { return false }
        isPending = false
        return true
    }
}
