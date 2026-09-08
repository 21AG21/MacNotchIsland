import AppKit
import SwiftUI

/// The strip under every section: the Mac's two most-reached-for controls, then Keep Awake,
/// the mirror, AirDrop and Settings. Identical whatever the panel shows, so hands learn where
/// things are.
struct ControlRail: View {
    @Binding var showingMirror: Bool
    @ObservedObject private var outputs = AudioOutputs.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var keepAwake = KeepAwake.shared
    @ObservedObject private var brightness = BrightnessControl.shared
    @ObservedObject private var toggles = SystemToggles.shared
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var center: ActivityCenter

    var body: some View {
        // Budget at 672 pt with everything showing: two sliders (182 and 144), up to seven
        // 30 pt buttons, 12 pt gaps, and a spacer that soaks up the rest.
        HStack(spacing: 12) {
            volume
            if BrightnessControl.shared.isAvailable { brightnessControl }
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
                    withAnimation(IslandMotion.quick) { showingMirror.toggle() }
                }
            }
            if prefs.shelfEnabled && !shelf.items.isEmpty {
                railButton(symbol: "dot.radiowaves.right", label: "AirDrop the shelf") { shelf.airDrop(shelf.urls) }
            }
            railButton(symbol: "gearshape", label: "Settings") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        .frame(width: IslandLayout.panelContentWidth, height: IslandLayout.railHeight)
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

    private var volume: some View {
        HStack(spacing: 8) {
            Button(action: { outputs.setMuted(!outputs.isMuted) }) {
                Image(systemName: outputs.isMuted || (outputs.volume ?? 0) <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 24, height: 24)
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
                .frame(width: 150)
                .opacity(outputs.volume == nil ? 0.3 : 1)
                .disabled(outputs.volume == nil)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(((outputs.volume ?? 0) * 100).rounded())) percent")
        }
    }

    private var brightnessControl: some View {
        HStack(spacing: 8) {
            Image(systemName: brightness.level < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            IslandSlider(value: brightness.level, onChange: { brightness.set($0) })
                .frame(width: 112)
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
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle())
        .help(label)
        .accessibilityLabel(label)
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
    /// what the user set instead of flickering back for one poll.
    private var pending: (value: Double, until: Date)?

    @Published private(set) var level: Double = BrightnessControl.read() ?? 0.5

    static let pollInterval: TimeInterval = 0.5
    static let writeSettle: TimeInterval = 1.0

    var isAvailable: Bool { monitor.currentBrightness() != nil }
    func current() -> Double? { monitor.currentBrightness().map { Double($0) } }

    private static func read() -> Double? { BrightnessMonitor().currentBrightness().map { Double($0) } }

    func set(_ value: Double) {
        let clamped = min(1, max(0, value))
        pending = (clamped, Date().addingTimeInterval(Self.writeSettle))
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
            guard Date() >= pending.until || abs(pending.value - value) < 0.02 else { return }
            self.pending = nil
        }
        if abs(level - value) > 0.001 { level = value }
    }
}
