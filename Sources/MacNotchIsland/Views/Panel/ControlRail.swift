import AppKit
import SwiftUI

/// The strip under every section: the Mac's two most-reached-for controls, then Wi-Fi,
/// Bluetooth, appearance, Keep Awake, the mirror, AirDrop and Settings. The same strip
/// whatever the panel shows, so hands learn where things are — with the two exceptions the
/// Mac itself makes, a control the hardware does not have, and the one control that would be
/// on screen twice.
struct ControlRail: View {
    @Binding var showingMirror: Bool
    /// The Shelf section is the one on screen. It carries an AirDrop control of its own, in
    /// its header, and that one sends the selection where this one always sends everything:
    /// two controls with the same name and the same glyph that do different things is worse
    /// than two that do the same. This is the way to the shelf from every other section, so
    /// it stands down on that one.
    var showingShelf = false
    @ObservedObject private var outputs = AudioOutputs.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var keepAwake = KeepAwake.shared
    @ObservedObject private var brightness = BrightnessControl.shared
    @ObservedObject private var toggles = SystemToggles.shared
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        // Read once, not once per mention: `isAvailable` is a DisplayServices round trip, and
        // the rail is rebuilt on every volume change and every hover.
        let hasBrightness = brightness.isAvailable
        let showsAirDrop = prefs.shelfEnabled && !shelf.items.isEmpty && !showingShelf
        // Budget at 672 pt with everything showing: two sliders (178 and 140), up to seven
        // 30 pt buttons, 12 pt gaps, and a spacer that soaks up the rest.
        return HStack(spacing: RailMetrics.gap) {
            volume
            // Beside the volume, not among the toggles: where the sound is going belongs with
            // how loud it is. Only when there is a choice to make — one output is not a
            // picker, it is a label nobody asked for.
            if outputs.devices.count > 1 { outputPicker }
            if hasBrightness { brightnessControl }
            Spacer(minLength: 8)
            if toggles.hasWiFi {
                railButton(symbol: toggles.wifiOn ? "wifi" : "wifi.slash",
                           label: toggles.wifiOn ? "Turn Wi-Fi off" : "Turn Wi-Fi on", active: toggles.wifiOn) {
                    toggles.toggleWiFi()
                }
            }
            if toggles.hasBluetooth {
                railGlyphButton(label: toggles.bluetoothOn ? "Turn Bluetooth off" : "Turn Bluetooth on",
                                active: toggles.bluetoothOn, action: { toggles.toggleBluetooth() }) {
                    BluetoothRune()
                        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 9, height: 14)
                        .opacity(toggles.bluetoothOn ? 1 : 0.5)
                }
            }
            railButton(symbol: toggles.darkMode ? "moon.fill" : "sun.max.fill",
                       label: toggles.darkMode ? "Switch to light" : "Switch to dark", active: false) {
                toggles.toggleAppearance()
            }
            railButton(symbol: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer",
                       label: keepAwake.isOn ? "Let the Mac sleep" : "Keep awake", active: keepAwake.isOn) {
                keepAwake.toggle()
            }
            if prefs.mirrorEnabled {
                railButton(symbol: showingMirror ? "camera.fill" : "camera", label: showingMirror ? "Hide mirror" : "Mirror",
                           active: showingMirror) {
                    withAnimation(IslandMotion.fade) { showingMirror.toggle() }
                }
            }
            if showsAirDrop {
                railButton(symbol: "dot.radiowaves.right", label: "AirDrop the shelf") { shelf.airDrop(shelf.urls) }
            }
            railButton(symbol: "gearshape", label: "Settings") { SettingsWindow.open() }
        }
        .frame(width: IslandLayout.panelContentWidth, height: IslandLayout.railHeight)
        // The row is not a fixed set: Wi-Fi and Bluetooth appear with the hardware, the
        // brightness slider with a display that has one, AirDrop with something on the shelf.
        // Whatever changes, the buttons beside it slide over rather than jumping.
        .animation(IslandMotion.content,
                   value: [hasBrightness, toggles.hasWiFi, toggles.hasBluetooth, prefs.mirrorEnabled,
                           showsAirDrop, outputs.devices.count > 1])
        .onAppear {
            outputs.viewerAppeared()
            brightness.viewerAppeared()
            toggles.viewerAppeared()
        }
        .onDisappear {
            outputs.viewerDisappeared()
            brightness.viewerDisappeared()
            toggles.viewerDisappeared()
        }
    }

    // MARK: - Sliders

    private static let leadingGlyph: CGFloat = RailMetrics.glyph

    private var volume: some View {
        HStack(spacing: RailMetrics.groupGap) {
            Button(action: { outputs.setMuted(!outputs.isMuted) }) {
                Image(systemName: outputs.isMuted || (outputs.volume ?? 0) <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: Self.leadingGlyph, height: 28, alignment: .leading)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IslandButtonStyle())
            .help(outputs.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(outputs.isMuted ? "Unmute" : "Mute")
            IslandSlider(value: outputs.isMuted ? 0 : Double(outputs.volume ?? 0),
                         onChange: { outputs.setVolume(Float($0)) },
                         // Dragging the volume up from a muted Mac means "unmute", the way it
                         // does in Control Centre; the slider would otherwise write a level
                         // nobody can hear.
                         onBegin: { if outputs.isMuted { outputs.setMuted(false) } })
                .frame(width: RailMetrics.volumeSlider)
                .opacity(outputs.volume == nil ? 0.3 : 1)
                .disabled(outputs.volume == nil)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(((outputs.volume ?? 0) * 100).rounded())) percent")
        }
    }

    /// Where the sound goes. It used to live in the Now Playing header, which meant it was
    /// there only while something was playing and only on that one section — and switching to
    /// headphones is not a thing you only want to do mid-track. The rail is under every
    /// section, so it is here, once.
    private var outputPicker: some View {
        Menu {
            ForEach(outputs.devices) { device in
                Button(action: { outputs.select(device) }) {
                    if device == outputs.current {
                        Label(device.shortName, systemImage: "checkmark")
                    } else {
                        Text(device.shortName)
                    }
                }
            }
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                Image(systemName: outputs.current?.symbol ?? "airplayaudio")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: RailMetrics.button, height: RailMetrics.button)
            .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(outputs.current.map { "Sound is going to \($0.name)" } ?? "Choose the output")
        .accessibilityLabel("Output: \(outputs.current?.name ?? "unknown")")
    }

    private var brightnessControl: some View {
        HStack(spacing: RailMetrics.groupGap) {
            Image(systemName: brightness.level < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: Self.leadingGlyph, height: 28, alignment: .leading)
                .accessibilityHidden(true)
            IslandSlider(value: brightness.level, onChange: { brightness.set($0) })
                .frame(width: RailMetrics.brightnessSlider)
                .accessibilityLabel("Brightness")
                .accessibilityValue("\(Int((brightness.level * 100).rounded())) percent")
        }
    }

    // MARK: - Buttons

    private func railButton(symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        railGlyphButton(label: label, active: active, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
    }

    /// The same disc for a glyph the system does not draw: Bluetooth has no symbol of its own.
    private func railGlyphButton<Glyph: View>(label: String, active: Bool = false, action: @escaping () -> Void,
                                              @ViewBuilder glyph: () -> Glyph) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(active ? 0.9 : 0.10))
                glyph()
                    .foregroundStyle(active ? Color.black : Color.white.opacity(0.85))
            }
            .frame(width: RailMetrics.button, height: RailMetrics.button)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Every measure the rail is built from, in one place, because they add up to something that
/// has to fit: the panel's content width. `RailMetricsTests` adds them up.
enum RailMetrics {
    /// The rail's first glyph is the panel's leftmost mark. Centring it in a 24 pt box set it
    /// 6 pt inside the column that the hairline above it, every section title and the switcher
    /// all stand on; it hangs from the leading edge instead, and keeps its full hit area.
    static let glyph: CGFloat = 22
    static let volumeSlider: CGFloat = 120
    static let brightnessSlider: CGFloat = 104
    /// Between a glyph and the slider it belongs to.
    static let groupGap: CGFloat = 6
    /// Between one control and the next.
    static let gap: CGFloat = 12
    static let button: CGFloat = 30
    /// Wi-Fi, Bluetooth, light/dark, Keep Awake, the mirror, AirDrop, Settings.
    static let maxButtons = 7
    /// The least the spacer in the middle may be.
    static let minSpacer: CGFloat = 8

    /// Every control the rail can show, at once: both sliders, the output picker, and all
    /// seven buttons. A Mac with a brightness slider, Wi-Fi, Bluetooth, a second output and
    /// something on the shelf shows exactly this.
    static var widest: CGFloat {
        let volume = glyph + groupGap + volumeSlider
        let brightness = glyph + groupGap + brightnessSlider
        let buttons = CGFloat(maxButtons + 1) * button          // the seven, and the output
        let children = 2 + 1 + (maxButtons + 1)                 // sliders, spacer, buttons
        return volume + brightness + minSpacer + buttons + CGFloat(children - 1) * gap
    }
}

/// Display brightness as the rail reads and writes it, through the same private DisplayServices
/// calls the brightness HUD watches.
///
/// The level is published so the rail's slider follows the brightness keys and anything else
/// that dims the screen, rather than showing whatever it read the one time it appeared. There
/// is no notification for brightness, so it is polled — but only while the rail is on screen,
/// and each read is one cheap DisplayServices call.
final class BrightnessControl: ObservableObject {
    static let shared = BrightnessControl()
    private let monitor = BrightnessMonitor()
    private var timer: Timer?
    private var viewers = 0
    /// A write the display has not reported back yet. Until it does, the slider keeps showing
    /// what the user set instead of flickering back for one poll. Held on the clock that only
    /// counts forwards: on the wall clock a backwards step would freeze the slider for as long
    /// as the offset lasted, and a forwards one would clear it at once.
    private var pending: (value: Double, until: TimeInterval)?

    @Published private(set) var level: Double = BrightnessControl.read() ?? 0.5

    static let pollInterval: TimeInterval = 0.5
    static let writeSettle: TimeInterval = 1.0

    var isAvailable: Bool { monitor.currentBrightness() != nil }
    func current() -> Double? { monitor.currentBrightness().map { Double($0) } }

    private static func read() -> Double? { BrightnessMonitor().currentBrightness().map { Double($0) } }

    /// When the rail's own slider last wrote the brightness. See `LocalWrite`.
    private(set) static var lastLocalWrite = LocalWrite.never

    static func wroteRecently(now: TimeInterval = LocalWrite.now()) -> Bool {
        LocalWrite.isRecent(lastLocalWrite, now: now)
    }

    /// See `AudioOutputs.markLocalWriteForTesting`.
    static func markLocalWriteForTesting(_ stamp: TimeInterval) { lastLocalWrite = stamp }

    func set(_ value: Double) {
        let clamped = min(1, max(0, value))
        Self.lastLocalWrite = LocalWrite.now()
        pending = (clamped, LocalWrite.now() + Self.writeSettle)
        if level != clamped { level = clamped }
        _ = monitor.setBrightness(Float(clamped))
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

    private func refresh() {
        guard let value = current() else { return }
        if let pending {
            guard LocalWrite.now() >= pending.until || abs(pending.value - value) < 0.02 else { return }
            self.pending = nil
        }
        if abs(level - value) > 0.001 { level = value }
    }
}
