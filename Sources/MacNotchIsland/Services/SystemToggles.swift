import AppKit
import CoreWLAN
import IOBluetooth

/// The three switches people reach for most, in the rail under every section: Wi-Fi,
/// Bluetooth and the Mac's appearance. Control Centre's job, without leaving the notch.
///
/// Each one is read from the system rather than remembered here, so the rail always shows the
/// truth even when something else did the switching. Reads are cheap and only happen while the
/// rail is on screen.
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
    private var pending: [String: (value: Bool, until: Date)] = [:]

    static let pollInterval: TimeInterval = 1.5
    static let writeSettle: TimeInterval = 2.5

    private init() {
        refresh()
    }

    // MARK: - Lifetime

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

    func refresh() {
        let interface = CWWiFiClient.shared().interface()
        if hasWiFi != (interface != nil) { hasWiFi = interface != nil }
        read(.wifi, as: interface?.powerOn() ?? false)

        let bluetooth = Self.bluetoothPower()
        if hasBluetooth != (bluetooth != nil) { hasBluetooth = bluetooth != nil }
        if let bluetooth { read(.bluetooth, as: bluetooth) }

        read(.appearance, as: Self.systemIsDark())
    }

    /// Takes a fresh reading unless the user has just asked for the opposite and the system
    /// has not caught up.
    private func read(_ key: Switch, as value: Bool) {
        if let waiting = pending[key.rawValue] {
            guard Date() >= waiting.until || waiting.value == value else { return }
            pending[key.rawValue] = nil
        }
        show(key, value)
    }

    /// What the user just asked for, shown at once and held until the system agrees.
    private func expect(_ key: Switch, _ value: Bool) {
        pending[key.rawValue] = (value, Date().addingTimeInterval(Self.writeSettle))
        show(key, value)
    }

    private func show(_ key: Switch, _ value: Bool) {
        switch key {
        case .wifi: if wifiOn != value { wifiOn = value }
        case .bluetooth: if bluetoothOn != value { bluetoothOn = value }
        case .appearance: if darkMode != value { darkMode = value }
        }
    }

    static func systemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    // MARK: - Switching

    func toggleWiFi() {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        let wanted = !interface.powerOn()
        expect(.wifi, wanted)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? interface.setPower(wanted)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func toggleBluetooth() {
        guard let current = Self.bluetoothPower() else { return }
        let wanted = !current
        expect(.bluetooth, wanted)
        Self.setBluetoothPower(wanted)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    /// Switches the Mac between light and dark. There is no API for this that does not go
    /// through System Events, so the first use asks for permission to control it.
    func toggleAppearance() {
        let wanted = !darkMode
        expect(.appearance, wanted)
        let source = """
        tell application "System Events" to tell appearance preferences to set dark mode to \(wanted)
        """
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

    static func bluetoothPower() -> Bool? {
        guard let symbol = dlsym(rtldDefault, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(symbol, to: GetPower.self)() != 0
    }

    static func setBluetoothPower(_ on: Bool) {
        guard let symbol = dlsym(rtldDefault, "IOBluetoothPreferenceSetControllerPowerState") else { return }
        unsafeBitCast(symbol, to: SetPower.self)(on ? 1 : 0)
    }
}
