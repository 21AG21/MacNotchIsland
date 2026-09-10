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
    /// When the rail went on screen, and nothing until it has. Everything the rail shows is read
    /// just after that moment, over the top of the panel's opening spring. See `RailAssembly`.
    @State private var mountedAt: TimeInterval?
    /// The rail is on screen. The three services under it are told a turn later than that — see
    /// `onAppear` — and a panel can be shut again inside that turn.
    @State private var onScreen = false
    /// The three services have been told, and are owed the other half of the pair. Each of them
    /// starts reading the system on its first viewer and stops on its last, so a count that is
    /// given back without ever having been taken leaves a Mac polling for nobody, or a rail that
    /// is still on screen holding readings that have stopped arriving.
    @State private var counted = false

    var body: some View {
        // A reading the brightness service already has, rather than a fresh walk of the display
        // list: the rail is rebuilt on every volume change and every hover.
        let hasBrightness = brightness.isAvailable
        let showsAirDrop = prefs.shelfEnabled && !shelf.items.isEmpty && !showingShelf
        // The row is not a fixed set: Wi-Fi and Bluetooth appear with the hardware, the
        // brightness slider with a display that has one, AirDrop with something on the shelf.
        let shape = [hasBrightness, toggles.hasWiFi, toggles.hasBluetooth, prefs.mirrorEnabled,
                     showsAirDrop, outputs.devices.count > 1]
        let motion: Animation? = RailAssembly.slides(mountedAt: mountedAt) ? IslandMotion.content : nil
        // Budget at 672 pt with everything showing: two sliders (178 and 140), up to seven
        // 30 pt buttons, 12 pt gaps, and a spacer that soaks up the rest.
        return HStack(spacing: RailMetrics.gap) {
            volume
            // Beside the volume, not among the toggles: where the sound is going belongs with
            // how loud it is. Only when there is a choice to make — one output is not a
            // picker, it is a label nobody asked for.
            if outputs.devices.count > 1 || RenderMode.isGallery { outputPicker }
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
        // Whatever changes, the buttons beside it slide over rather than jumping — everything
        // except the readings the rail is assembled from. See `RailAssembly`.
        .animation(motion, value: shape)
        .onAppear {
            onScreen = true
            mountedAt = LocalWrite.now()
            // Each of the three reads the system the moment it is told it has a viewer: a whole
            // CoreAudio enumeration, a DisplayServices call, and both radios over XPC. Done on
            // the turn the rail is mounted, that burst goes in front of the panel's opening
            // spring rather than behind it, and the first frames of the growth are spent on it.
            // A turn later is still at once to anyone watching, and by then the panel is already
            // moving.
            DispatchQueue.main.async {
                guard onScreen, !counted else { return }
                counted = true
                outputs.viewerAppeared()
                brightness.viewerAppeared()
                toggles.viewerAppeared()
            }
        }
        .onDisappear {
            onScreen = false
            guard counted else { return }
            counted = false
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
        Group {
            if RenderMode.isGallery {
                // A menu is AppKit's, and `ImageRenderer` draws one as a yellow block with a
                // red line through it. The gallery gets the disc without the menu behind it,
                // which is the whole of what anybody sees at rest.
                outputGlyph
            } else {
                Menu {
                    // Both halves of Control Centre's Sound module. The input is the one
                    // nobody can reach without opening System Settings, and it is the one
                    // that matters at the moment a call starts.
                    Section("Output") {
                        ForEach(outputs.devices) { device in
                            Button(action: { outputs.select(device) }) {
                                if device == outputs.current {
                                    Label(device.shortName, systemImage: "checkmark")
                                } else {
                                    Text(device.shortName)
                                }
                            }
                        }
                    }
                    if outputs.inputs.count > 1 {
                        Section("Input") {
                            ForEach(outputs.inputs) { device in
                                Button(action: { outputs.selectInput(device) }) {
                                    if device == outputs.currentInput {
                                        Label(device.shortName, systemImage: "checkmark")
                                    } else {
                                        Text(device.shortName)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    outputGlyph
                }
                // Borderless, with no indicator: `.button` draws AppKit's own bezel, which put
                // a rounded rectangle in a row of discs and was the one control on the rail
                // that did not look like it belonged to the island.
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .help(outputs.current.map { "Sound is going to \($0.name)" } ?? "Choose where the sound goes")
        .accessibilityLabel("Sound: \(outputs.current?.name ?? "unknown")")
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

    /// The disc the picker wears: the current output's symbol, the same size as every other
    /// button on the rail.
    private var outputGlyph: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.10))
            Image(systemName: outputs.current?.symbol ?? "airplayaudio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: RailMetrics.button, height: RailMetrics.button)
        .contentShape(Circle())
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

/// Whether a change to what the rail is holding slides the buttons over, or is simply there when
/// the rail arrives.
///
/// The rail is mounted before it knows what it holds: the audio devices, the brightness and both
/// radios are read a turn after the panel has started growing, and every one of them adds or
/// takes away a control. Sliding the whole row sideways to make room for those, on top of the
/// opening spring, reads as the panel stumbling rather than as the rail filling itself in — so
/// for as long as the panel is still opening the rail assembles in silence. After that it is a
/// thing that is already there, and a pair of headphones plugged into it is a change like any
/// other: it slides.
///
/// A window rather than a count of arrivals, because on every open but the first the readings
/// are already in hand and nothing arrives at all — and a rail that is still waiting for its
/// first arrival is a rail that would take the next real change in silence, weeks later.
enum RailAssembly {
    /// The panel's opening spring is 0.44s, and a radio asked at the start of it can take most of
    /// that again to answer. Nothing a hand can do to the rail changes its shape, so there is no
    /// real change to lose inside the window.
    static let window: TimeInterval = 0.6

    /// `mountedAt` is nothing until the rail is on screen, which is where the first pass stands:
    /// nothing has been read yet, so there is nothing yet that could be worth animating. Held on
    /// the clock that only counts forwards, for the reason `LocalWrite` gives.
    static func slides(mountedAt: TimeInterval?, now: TimeInterval = LocalWrite.now()) -> Bool {
        guard let mountedAt else { return false }
        return !LocalWrite.isRecent(mountedAt, within: window, now: now)
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
    /// Held for as long as the app runs, because a display can be plugged in at any point in it.
    private var screenObserver: NSObjectProtocol?
    /// A write the display has not reported back yet. Until it does, the slider keeps showing
    /// what the user set instead of flickering back for one poll. Held on the clock that only
    /// counts forwards: on the wall clock a backwards step would freeze the slider for as long
    /// as the offset lasted, and a forwards one would clear it at once.
    private var pending: (value: Double, until: TimeInterval)?

    @Published private(set) var level: Double = 0.5
    /// Whether there is a brightness to set at all: a Mac driving nothing but an external display
    /// has none, and the rail leaves the slider out rather than showing one that does nothing.
    /// Kept rather than asked, because the rail's body wants it on every volume change, every
    /// hover and every pass of the poll below, and the answer costs a walk of the display list
    /// and a DisplayServices call. A display cannot arrive without the screen arrangement
    /// changing, and the screen arrangement changing is announced.
    @Published private(set) var isAvailable = false

    static let pollInterval: TimeInterval = 0.5
    static let writeSettle: TimeInterval = 1.0

    private init() {
        let reading = monitor.currentBrightness().map { Double($0) }
        level = reading ?? 0.5
        isAvailable = reading != nil
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func current() -> Double? { monitor.currentBrightness().map { Double($0) } }

    /// What the display says it is set to, straight from DisplayServices. Internal because
    /// the gesture router reads it too, for the scroll that carries Option.
    static func read() -> Double? { BrightnessMonitor().currentBrightness().map { Double($0) } }

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
        // Every reading is also an answer about whether there is anything to read, which is the
        // only thing that keeps `isAvailable` honest between one screen arrangement and the next.
        let reading = current()
        if isAvailable != (reading != nil) { isAvailable = reading != nil }
        guard let value = reading else { return }
        if let pending {
            guard LocalWrite.now() >= pending.until || abs(pending.value - value) < 0.02 else { return }
            self.pending = nil
        }
        if abs(level - value) > 0.001 { level = value }
    }
}
