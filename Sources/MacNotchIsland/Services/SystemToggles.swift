import AppKit
import CoreWLAN
import IOBluetooth

/// The three switches people reach for most, in the rail under every section: Wi-Fi,
/// Bluetooth and the Mac's appearance. Control Centre's job, without leaving the notch.
///
/// Each one is read from the system rather than remembered here, so the rail always shows the
/// truth even when something else did the switching. The rail is under every section, so this
/// poll runs for as long as any panel is on screen — and both radios answer over XPC, which
/// is to say in their own time. Nothing that waits on a radio happens on the main thread:
/// the readings are taken on the queue below, and only what is shown is decided here.
final class SystemToggles: ObservableObject {
    static let shared = SystemToggles()

    @Published private(set) var wifiOn = false
    @Published private(set) var bluetoothOn = false
    @Published private(set) var darkMode = false
    /// Wi-Fi and Bluetooth are hidden entirely on a Mac that has neither.
    @Published private(set) var hasWiFi = false
    @Published private(set) var hasBluetooth = false

    private var viewers = 0
    private var timer: Timer?
    /// A switch the system has not caught up with yet: until then the rail shows what the user
    /// asked for, so a toggle never appears to bounce back.
    private var pending: [String: Pending] = [:]
    /// Where the waiting happens. Serial, so the switch a button asked for is thrown after any
    /// reading already in the air and before the one that comes next.
    private let queue = DispatchQueue(label: "com.macnotchisland.toggles", qos: .utility)
    private var pass = RadioPass()

    static let pollInterval: TimeInterval = 1.5
    static let writeSettle: TimeInterval = 2.5

    private init() {
        refresh()
    }

    // MARK: - Lifetime

    /// Fills in the switches for the gallery, which has neither radio.
    func seedForGallery(wifi: Bool, bluetooth: Bool) {
        hasWiFi = true
        hasBluetooth = true
        wifiOn = wifi
        bluetoothOn = bluetooth
    }

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        refresh()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = Self.pollInterval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Reading

    /// The three switches, as keys for the "waiting for the system" bookkeeping.
    enum Switch: String { case wifi, bluetooth, appearance }

    /// What the user asked for, and the moment the rail stops holding it and believes the
    /// system again.
    struct Pending: Equatable {
        var value: Bool
        var until: Date
    }

    /// The appearance is AppKit's own answer about this process and costs nothing, so it is
    /// read where it is shown. The two radios are asked on the queue, one pass at a time.
    func refresh() {
        read(.appearance, as: Self.systemIsDark())
        guard pass.start() else { return }
        queue.async { [weak self] in
            let interface = CWWiFiClient.shared().interface()
            let wifi = interface.map { $0.powerOn() }
            let bluetooth = Self.bluetoothPower()
            DispatchQueue.main.async {
                guard let self else { return }
                let asked = self.pass.finish()
                if self.hasWiFi != (wifi != nil) { self.hasWiFi = wifi != nil }
                self.read(.wifi, as: wifi ?? false)
                if self.hasBluetooth != (bluetooth != nil) { self.hasBluetooth = bluetooth != nil }
                if let bluetooth { self.read(.bluetooth, as: bluetooth) }
                // A switch was thrown while this reading was in the air; the answer it is
                // waiting for is the next one, not the one after the poll comes round again.
                if asked { self.refresh() }
            }
        }
    }

    /// Takes a fresh reading unless the user has just asked for the opposite and the system
    /// has not caught up.
    private func read(_ key: Switch, as value: Bool) {
        guard Self.accepts(value, waitingFor: pending[key.rawValue]) else { return }
        pending[key.rawValue] = nil
        show(key, value)
    }

    /// Whether a reading is still worth showing, or is older than the user's own last word on
    /// the matter. A reading now leaves the radio before the tap that makes it wrong and lands
    /// after it, which is precisely the moment the rail must not flick back to what the system
    /// was saying a second ago. A reading that agrees settles the wait early; one that is still
    /// arguing when the settle window is up is believed, because by then the answer is no.
    static func accepts(_ value: Bool, waitingFor waiting: Pending?, at now: Date = Date()) -> Bool {
        guard let waiting else { return true }
        return now >= waiting.until || waiting.value == value
    }

    /// What the user just asked for, shown at once and held until the system agrees.
    private func expect(_ key: Switch, _ value: Bool) {
        pending[key.rawValue] = Pending(value: value, until: Date().addingTimeInterval(Self.writeSettle))
        show(key, value)
    }

    private func show(_ key: Switch, _ value: Bool) {
        switch key {
        case .wifi: if wifiOn != value { wifiOn = value }
        case .bluetooth: if bluetoothOn != value { bluetoothOn = value }
        case .appearance: if darkMode != value { darkMode = value }
        }
    }

    /// From AppKit rather than the `AppleInterfaceStyle` default. That key is read out of this
    /// process's cached copy of the global domain, and there is no promise it is fresh at the
    /// instant the appearance changes — which is the only instant this is ever asked about.
    /// Nothing here overrides the application's own appearance, so its effective one is the
    /// system's. Main thread, which is where the rail and its timer both are.
    static func systemIsDark() -> Bool {
        // `NSApp` is nil until an application exists — under `swift test`, and in principle
        // before launch finishes — and the default is the only reading there is then.
        guard let app = NSApp else {
            return UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
        }
        return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Switching

    /// What the switch is thrown from is what the rail is showing, not a fresh reading: asking
    /// the interface would mean waiting on it with the pointer still down, and a switch that
    /// does the opposite of the one on screen is not the one that was pressed.
    func toggleWiFi() {
        guard hasWiFi else { return }
        let wanted = !wifiOn
        expect(.wifi, wanted)
        queue.async { [weak self] in
            // Wi-Fi held off by policy, or the interface busy, or gone since the rail last
            // looked. Without this the switch showed what was asked for, held it for the
            // settle window, and then slid back on its own with nothing said — which reads
            // as the app being broken rather than as the answer being no.
            var refused = true
            if let interface = CWWiFiClient.shared().interface() {
                do {
                    try interface.setPower(wanted)
                    refused = false
                } catch {
                    IslandLog.network.error("wi-fi switch refused: \(error.localizedDescription, privacy: .public)")
                }
            }
            DispatchQueue.main.async {
                if refused { self?.pending[Switch.wifi.rawValue] = nil }
                self?.refresh()
            }
        }
    }

    /// The Bluetooth write blocks until the controller answers, which on a cold radio is long
    /// enough to be felt as the panel stopping under the pointer.
    func toggleBluetooth() {
        guard hasBluetooth else { return }
        let wanted = !bluetoothOn
        expect(.bluetooth, wanted)
        queue.async { [weak self] in
            Self.setBluetoothPower(wanted)
            // The controller answers the write before it has finished changing its mind, so
            // let it settle rather than reading it straight back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refresh() }
        }
    }

    /// Switches the Mac between light and dark. There is no API for this that does not go
    /// through System Events, so the first use asks for permission to control it.
    func toggleAppearance() {
        let wanted = !darkMode
        expect(.appearance, wanted)
        let source = """
        tell application "System Events" to tell appearance preferences to set dark mode to \(wanted)
        """
        // Its own queue rather than the radios': System Events can take seconds to answer the
        // first time, and the rail's poll should not be waiting behind it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let failed = error != nil
            DispatchQueue.main.async {
                if failed {
                    // Permission refused, or System Events is unavailable: show the truth again.
                    self?.pending[Switch.appearance.rawValue] = nil
                    SystemSettingsPane.automation.open()
                }
                self?.refresh()
            }
        }
    }

    // MARK: - Bluetooth, which has no public switch

    /// IOBluetooth carries the controller's power switch, but does not declare it in a header.
    /// The symbols are looked up in the already-loaded framework; when they are not there
    /// (a Mac without Bluetooth, or a future macOS that dropped them) the toggle is hidden
    /// rather than doing nothing.
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    /// Looked up once. The reader is on a poll that runs while the panel is open, and asking
    /// the dynamic linker for the same two symbols a couple of times a second is work nobody
    /// asked for.
    private static let getPower: GetPower? = dlsym(rtldDefault, "IOBluetoothPreferenceGetControllerPowerState")
        .map { unsafeBitCast($0, to: GetPower.self) }
    private static let putPower: SetPower? = dlsym(rtldDefault, "IOBluetoothPreferenceSetControllerPowerState")
        .map { unsafeBitCast($0, to: SetPower.self) }

    /// Both of these wait on the controller, so both belong on a queue.
    static func bluetoothPower() -> Bool? {
        guard let getPower else { return nil }
        return getPower() != 0
    }

    static func setBluetoothPower(_ on: Bool) {
        putPower?(on ? 1 : 0)
    }
}
