import AppKit
import Combine
import SwiftUI

/// The strip under every section: the Mac's two most-reached-for controls, then the buttons the
/// user has chosen from `RailControl`'s catalog, in their order, Settings last. Out of the box
/// that is Wi-Fi, Bluetooth, Display, Keep Awake, the mirror, AirDrop and the keyboard's
/// backlight. The same strip whatever the panel shows, so hands learn where things are — with
/// the two exceptions the Mac itself makes, a control the hardware does not have, and the one
/// control that would be on screen twice. What does not fit goes to the top of the Controls
/// section rather than nowhere; see `RailPlan`.
struct ControlRail: View {
    @Binding var showingMirror: Bool
    /// The Shelf section is the one on screen. It carries an AirDrop control of its own, in
    /// its header, and that one sends the selection where this one always sends everything:
    /// two controls with the same name and the same glyph that do different things is worse
    /// than two that do the same. This is the way to the shelf from every other section, so
    /// it stands down on that one.
    var showingShelf = false
    @ObservedObject private var outputs = AudioOutputs.shared
    // Watched for what they decide about the rail's shape — whether AirDrop, Wi-Fi, Bluetooth
    // and the keyboard's light are on it at all — not for what the buttons show, which each
    // button watches for itself.
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var brightness = BrightnessControl.shared
    @ObservedObject private var toggles = SystemToggles.shared
    @ObservedObject private var keyboard = KeyboardLight.shared
    // A webcam plugged in or pulled out adds or takes away the mirror's disc
    // (`RailControl.Presence`); unwatched, the rail kept its shape until something else redrew it.
    @ObservedObject private var camera = CameraPresence.shared
    @EnvironmentObject private var prefs: Preferences
    /// Which display's island this rail is on, for the brightness slider (`BrightnessControl`).
    @Environment(\.islandPanelID) private var panelID
    /// The display this rail told the brightness service it is on, to be given back when it goes.
    @State private var watchedDisplay: CGDirectDisplayID?
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
        let hasPicker = outputs.hasChoice || RenderMode.isGallery
        let plan = RailPlan.current(prefs: prefs, showingShelf: showingShelf, showingMirror: showingMirror)
        // The row is not a fixed set: the brightness slider comes with a display that has one,
        // the picker with a second output or an AirPlay receiver, and the buttons with the
        // hardware, the user's choice and the room left over.
        let shape = [hasBrightness ? "brightness" : "", hasPicker ? "picker" : ""] + plan.rail.map(\.rawValue)
        let motion: Animation? = RailAssembly.slides(mountedAt: mountedAt) ? IslandMotion.content : nil
        // Budget at 672 pt: the sliders with their glyphs (148 and 132), the output picker, a
        // spacer that soaks up the rest, and as many of the chosen controls as fit, 12 pt apart.
        // `RailMetrics.room` adds it up and `RailControl.fit` spends it.
        return HStack(spacing: RailMetrics.gap) {
            volume
            // Beside the volume, not among the toggles: where the sound is going belongs with
            // how loud it is. Only when there is a choice to make — one output is not a
            // picker, it is a label nobody asked for.
            if hasPicker { outputPicker }
            if hasBrightness { brightnessControl }
            Spacer(minLength: RailMetrics.minSpacer)
            ForEach(plan.rail, id: \.self) { control in
                RailControlView(control: control, showingMirror: $showingMirror)
            }
        }
        .frame(width: IslandLayout.panelContentWidth, height: IslandLayout.railHeight)
        // Whatever changes, the buttons beside it slide over rather than jumping — everything
        // except the readings the rail is assembled from. See `RailAssembly`.
        .animation(motion, value: shape)
        .onAppear {
            onScreen = true
            mountedAt = LocalWrite.now()
            // Each of the three reads the system the moment it is told it has a viewer: a whole
            // CoreAudio enumeration, a DisplayServices call, and both radios over XPC. None of
            // that is on the main thread — each hands its reading to a queue of its own and is
            // told the answer — so what telling them costs here is a timer apiece and a hop.
            // A turn later still keeps even that out of the pass that mounts the rail, which is
            // the first frame of the panel's opening spring.
            DispatchQueue.main.async {
                guard onScreen, !counted else { return }
                counted = true
                outputs.viewerAppeared()
                // The display under this rail is read with the driven one from the first pass,
                // so it is told before the pass that `viewerAppeared` starts.
                if let display = BrightnessControl.display(forPanel: panelID) {
                    watchedDisplay = display
                    brightness.watch(display)
                }
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
            if let display = watchedDisplay {
                brightness.unwatch(display)
                watchedDisplay = nil
            }
            toggles.viewerDisappeared()
        }
    }

    // MARK: - Sliders

    private static let leadingGlyph: CGFloat = RailMetrics.glyph

    private var volume: some View {
        let mute = Self.muteButton(volume: outputs.volume, muted: outputs.isMuted, hasMute: outputs.hasMute)
        return HStack(spacing: RailMetrics.groupGap) {
            Button(action: { outputs.setMuted(!outputs.isMuted) }) {
                Image(systemName: mute.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: Self.leadingGlyph, height: 28, alignment: .leading)
                    // 22 across, 2 short of what the pointer is owed: a point further out on
                    // each side, into the panel's margin and the gap before the slider,
                    // without moving the glyph off the column it hangs from.
                    .hitOutset(horizontal: IslandHit.outset(drawn: Self.leadingGlyph), vertical: 0)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IslandButtonStyle())
            // An output with no mute of its own — a USB DAC with only a level, HDMI, some AirPlay
            // receivers — took the click and did nothing (`AudioMonitor.writeOutputMute` refuses
            // what it cannot set). Dimmed and deaf to it, as the microphone's disc is.
            .disabled(!mute.isEnabled)
            .opacity(mute.isEnabled ? 1 : 0.4)
            .help(mute.help)
            .accessibilityLabel(mute.label)
            // Muted, the bar is drawn empty, and everything about it starts from there: a drag
            // or a press of VoiceOver's increment sets a level up from nothing, and setting a
            // level above nothing unmutes, the way it does in Control Centre (`setVolume` does
            // that half). It used to unmute as the drag or the press began, whichever way it
            // went, so a decrement on a muted Mac unmuted it and wrote a level of nothing over
            // the one it had been muted at. See `volumeWrite`.
            IslandSlider(value: outputs.isMuted ? 0 : Double(outputs.volume ?? 0),
                         onChange: { level in
                             if let write = Self.volumeWrite(level, muted: outputs.isMuted) {
                                 outputs.setVolume(Float(write))
                             }
                         })
                .frame(width: RailMetrics.volumeSlider)
                .opacity(outputs.volume == nil ? 0.3 : 1)
                .disabled(outputs.volume == nil)
                .accessibilityLabel("Volume")
                .accessibilityValue(Self.volumeValue(volume: outputs.volume, muted: outputs.isMuted))
        }
    }

    /// What a move of the volume slider writes: the level asked for, except on a muted Mac
    /// taken to the bottom of the bar, where it is drawn already and nothing is written — the
    /// level it was muted at stays for the unmute to go back to. Pure, so the rule is tested.
    static func volumeWrite(_ level: Double, muted: Bool) -> Double? {
        muted && level <= 0 ? nil : level
    }

    /// What VoiceOver reads for the volume: what the bar shows. Muted, it is drawn empty and
    /// said as "Muted"; it used to read out the level it was muted at, "50 percent" over an
    /// empty bar. Pure, so the rule is tested.
    static func volumeValue(volume: Float?, muted: Bool) -> String {
        if muted { return "Muted" }
        return "\(Int(((volume ?? 0) * 100).rounded())) percent"
    }

    /// The glyph at the head of the volume, what it is called, and whether it takes a click.
    struct MuteButton: Equatable {
        var symbol: String
        var label: String
        var help: String
        var isEnabled: Bool
    }

    /// Pure, so the rule is tested. Muted, or at nothing, the struck-out speaker. With no level
    /// to read — an output that has no volume of its own, sound playing through it — a plain
    /// speaker: it used to be the struck-out one, which said "muted" over music that was
    /// playing. And only an output with a mute of its own offers one.
    static func muteButton(volume: Float?, muted: Bool, hasMute: Bool) -> MuteButton {
        let symbol: String
        if muted {
            symbol = "speaker.slash.fill"
        } else if let volume {
            symbol = volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        } else {
            symbol = "speaker.fill"
        }
        let label = muted ? "Unmute" : "Mute"
        guard hasMute else {
            return MuteButton(symbol: symbol, label: label, help: "This output has no mute", isEnabled: false)
        }
        return MuteButton(symbol: symbol, label: label, help: label, isEnabled: true)
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
                    Section(SoundList.output) {
                        ForEach(outputs.shownOutputs) { device in
                            Button(action: { outputs.select(device) }) {
                                if device == outputs.current {
                                    Label(device.shortName, systemImage: "checkmark")
                                } else {
                                    Text(device.shortName)
                                }
                            }
                        }
                    }
                    // The HomePods and Apple TVs, which Control Centre lists and CoreAudio only
                    // does as the AirPlay device's data sources. Inside the one menu, so the
                    // rail keeps its width whatever is on the network.
                    if !outputs.airPlay.isEmpty {
                        Section(SoundList.airPlay) {
                            ForEach(outputs.airPlay) { target in
                                Button(action: { outputs.selectAirPlay(target) }) {
                                    if outputs.airPlayCurrent.contains(target.source) {
                                        Label(target.name, systemImage: "checkmark")
                                    } else {
                                        Text(target.name)
                                    }
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
                // Laid out at a disc's width whatever AppKit's menu button asks for: the rail's
                // budget counts the picker as one disc (`RailMetrics.leading`), and with every
                // control on and no brightness slider it is spent to the point, so a menu drawn a
                // few points wider pushed the row past the panel's edge. Anything AppKit adds
                // around the disc lands in the gaps either side of it.
                .frame(width: RailMetrics.button, height: RailMetrics.button)
            }
        }
        .help(outputs.destinationName.map { "Sound is going to \($0)" } ?? "Choose where the sound goes")
        .accessibilityLabel("Sound: \(outputs.destinationName ?? "unknown")")
    }

    /// The brightness of the display this panel is on, where that display answers; otherwise
    /// the driven one — the built-in panel — named when there is more than one display to
    /// mistake it for. See `BrightnessControl.railTarget`.
    private var brightnessControl: some View {
        let panelDisplay = BrightnessControl.display(forPanel: panelID)
        let driven = brightness.drivenDisplay
        let target = BrightnessControl.railTarget(panelDisplay: panelDisplay, driven: driven,
                                                  answering: Set(brightness.panelLevels.keys))
        let level = target.flatMap { brightness.panelLevels[$0] } ?? brightness.level
        let drivesPanelsOwn = panelDisplay == nil || target != nil || panelDisplay == driven
        let label = BrightnessControl.sliderLabel(drivenName: drivesPanelsOwn ? nil : driven.flatMap { BrightnessControl.name(of: $0) },
                                                  drivesPanelsOwn: drivesPanelsOwn,
                                                  displaysOnline: NSScreen.screens.count)
        return HStack(spacing: RailMetrics.groupGap) {
            Image(systemName: level < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: Self.leadingGlyph, height: 28, alignment: .leading)
                .accessibilityHidden(true)
            IslandSlider(value: level, onChange: { value in
                if let target {
                    brightness.set(value, display: target)
                } else {
                    brightness.set(value)
                }
            })
                .frame(width: RailMetrics.brightnessSlider)
                .help(label)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int((level * 100).rounded())) percent")
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
}

/// What the rail holds and what it has no room for, from the live readings: the chosen controls
/// that this Mac has, fitted to what the fixed left-hand end leaves over. The rail and the
/// Controls section both ask this, so the two agree on which controls are where — the section
/// shows exactly the ones the rail could not.
enum RailPlan {
    static func current(prefs: Preferences, showingShelf: Bool, showingMirror: Bool) -> RailControl.Fit {
        let room = RailMetrics.room(hasPicker: AudioOutputs.shared.hasChoice || RenderMode.isGallery,
                                    hasBrightness: BrightnessControl.shared.isAvailable)
        return plan(RailControl.available(prefs), room: room, showingShelf: showingShelf, showingMirror: showingMirror)
    }

    /// The fit, from readings. The Shelf section carries its own AirDrop (see
    /// `ControlRail.showingShelf`), so the rail's stands down there — but only after the rail
    /// has been fitted with it, as it is on every other section. Fitted without it, the room
    /// it left went to whatever had not fitted, which came onto the rail on that one section
    /// and went again on the next: the strip changed shape with the section under it. Pure.
    static func plan(_ controls: [RailControl], room: CGFloat, showingShelf: Bool,
                     showingMirror: Bool) -> RailControl.Fit {
        var pinned: Set<RailControl> = [.settings]
        if showingMirror { pinned.insert(.mirror) }
        var fit = RailControl.fit(controls, room: room, pinned: pinned)
        if showingShelf {
            fit.rail.removeAll { $0 == .airDrop }
            fit.spill.removeAll { $0 == .airDrop }
        }
        return fit
    }
}

/// One control from the catalog, drawn the same wherever it lands: on the rail, or in the row the
/// Controls section keeps for the ones the rail had no room for.
struct RailControlView: View {
    let control: RailControl
    @Binding var showingMirror: Bool
    @ObservedObject private var toggles = SystemToggles.shared
    @ObservedObject private var keepAwake = KeepAwake.shared
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        switch control {
        case .wifi:
            RailDisc(symbol: toggles.wifiOn ? "wifi" : "wifi.slash",
                     label: toggles.wifiOn ? "Turn Wi-Fi off" : "Turn Wi-Fi on", active: toggles.wifiOn) {
                toggles.toggleWiFi()
            }
        case .bluetooth:
            if !toggles.hasBluetooth, toggles.bluetoothAccessRefused {
                // A radio this app has been refused, rather than none: the disc stays, and
                // takes the user to the pane that can give it back.
                RailDisc(label: "Bluetooth access is off. Open Privacy settings",
                         action: { SystemSettingsPane.bluetooth.open() }) {
                    BluetoothRune()
                        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 9, height: 14)
                        .opacity(0.5)
                }
            } else {
                // The same disc for a glyph the system does not draw: Bluetooth has no symbol of its own.
                RailDisc(label: toggles.bluetoothOn ? "Turn Bluetooth off" : "Turn Bluetooth on",
                         active: toggles.bluetoothOn, action: { toggles.toggleBluetooth() }) {
                    BluetoothRune()
                        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 9, height: 14)
                        .opacity(toggles.bluetoothOn ? 1 : 0.5)
                }
            }
        case .display:
            DisplayRailButton()
        case .keepAwake:
            RailDisc(symbol: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer",
                     label: keepAwake.isOn ? "Let the Mac sleep" : "Keep awake", active: keepAwake.isOn) {
                keepAwake.toggle()
            }
        case .mirror:
            RailDisc(symbol: showingMirror ? "camera.fill" : "camera", label: showingMirror ? "Hide mirror" : "Mirror",
                     active: showingMirror) {
                withAnimation(IslandMotion.fade) { showingMirror.toggle() }
            }
        case .airDrop:
            RailDisc(symbol: "dot.radiowaves.right", label: "AirDrop the shelf") { shelf.airDrop(shelf.urls) }
        case .focus:
            FocusRailButton()
        case .microphone:
            MicrophoneRailButton()
        case .lock:
            RailDisc(symbol: RailControl.lock.symbol, label: "Lock the screen") { SystemActions.lockScreen() }
        case .sleepDisplay:
            RailDisc(symbol: RailControl.sleepDisplay.symbol, label: "Sleep the display") { SystemActions.sleepDisplay() }
        case .screenshot:
            RailDisc(symbol: RailControl.screenshot.symbol, label: "Take a screenshot") { SystemActions.openScreenshotToolbar() }
        case .record:
            RecordRailButton()
        case .keyboardLight:
            KeyboardLightRailButton()
        case .settings:
            RailDisc(symbol: RailControl.settings.symbol, label: "Settings") { SettingsWindow.open() }
        }
    }
}

/// The rail's disc: a white-10% circle with the glyph on it, filled white while what it switches
/// is on.
struct RailDisc<Glyph: View>: View {
    let label: String
    var active = false
    let action: () -> Void
    let glyph: Glyph

    init(label: String, active: Bool = false, action: @escaping () -> Void, @ViewBuilder glyph: () -> Glyph) {
        self.label = label
        self.active = active
        self.action = action
        self.glyph = glyph()
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(active ? 0.9 : 0.10))
                glyph
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

extension RailDisc where Glyph == RailSymbol {
    /// A disc wearing an SF Symbol. `tint` colours the glyph where its state is worth a colour —
    /// a recording's red.
    init(symbol: String, label: String, active: Bool = false, tint: Color? = nil, action: @escaping () -> Void) {
        self.init(label: label, active: active, action: action) { RailSymbol(name: symbol, tint: tint) }
    }
}

struct RailSymbol: View {
    let name: String
    var tint: Color? = nil

    var body: some View {
        if let tint {
            symbol.foregroundStyle(tint)
        } else {
            symbol
        }
    }

    private var symbol: some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// The sun on the rail: opens the Display popover.
private struct DisplayRailButton: View {
    @State private var open = false

    var body: some View {
        RailDisc(symbol: RailControl.display.symbol, label: "Display", active: open) { open.toggle() }
            // Under the rail, where the screen is, rather than over the panel it came from.
            .popover(isPresented: $open, arrowEdge: .bottom) {
                DisplayModuleView()
            }
    }
}

/// The moon on the rail: opens the Focus popover, which lists this Mac's Focus modes and sets
/// one. It used to open Focus settings and nothing else, which is a long way round to turning on
/// Do Not Disturb; settings are a right-click away now, and at the foot of the popover.
///
/// Lit while a Focus is on, as the island last saw it, and wearing that Focus's own glyph —
/// the briefcase for Work, the bed for Sleep — where SF Symbols has it. Watched through
/// `FocusStatus`, since read through `FocusMonitor.isOn` alone the disc kept whatever it showed
/// until something else happened to redraw it.
private struct FocusRailButton: View {
    @ObservedObject private var status = FocusStatus.shared
    @State private var open = false

    var body: some View {
        let symbol = LiveActivityAPI.symbol(status.active?.symbol, fallback: RailControl.focus.symbol)
        let label: String = status.active.map { "Focus: \($0.name)" } ?? "Focus"
        return RailDisc(symbol: symbol, label: label, active: status.isOn) { open.toggle() }
            .contextMenu {
                Button("Focus Settings\u{2026}") { Self.openSettings() }
            }
            .accessibilityAction(named: "Open Focus settings") { Self.openSettings() }
            // Under the rail, the way the Display disc's popover opens.
            .popover(isPresented: $open, arrowEdge: .bottom) {
                FocusModuleView()
            }
    }

    static func openSettings() {
        if let url = RailControl.focusSettings { NSWorkspace.shared.open(url) }
    }
}

/// Mutes the microphone and says so: lit while it is muted, the way a mute key's light is.
/// Dimmed and deaf to a click while there is no microphone the island can reach — none at all,
/// or one with neither a mute nor a level to turn down — as the menu's item and the call card's
/// button already were: a press there did nothing and said nothing. The state is taken from the
/// microphone service's published values alone, the availability seeded from it so the disc is
/// not drawn dimmed for a frame on a Mac that has a microphone.
private struct MicrophoneRailButton: View {
    @State private var muted = false
    @State private var available = MicrophoneControl.shared.isAvailable

    var body: some View {
        RailDisc(symbol: muted ? "mic.slash.fill" : "mic.fill",
                 label: muted ? "Unmute the microphone" : "Mute the microphone", active: muted) {
            MicrophoneControl.shared.toggle()
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .onReceive(MicrophoneControl.shared.$isMuted) { muted = $0 }
        .onReceive(MicrophoneControl.shared.$isAvailable) { available = $0 }
    }
}

/// Starts and stops a screen recording, red while one is running. From Stop until the movie
/// is finished it says it is saving and takes no click: there is nothing left to stop then —
/// `ScreenRecorder.stop()` does nothing meanwhile — and a Stop that does nothing reads as a
/// Stop that is broken.
private struct RecordRailButton: View {
    @State private var recording = false
    @State private var saving = false

    var body: some View {
        RailDisc(symbol: saving ? "hourglass" : (recording ? "stop.circle.fill" : RailControl.record.symbol),
                 label: saving ? "Saving the recording" : (recording ? "Stop recording" : "Record the screen"),
                 tint: recording && !saving ? Color(red: 1, green: 0.27, blue: 0.23) : nil) {
            ScreenRecorder.shared.toggle()
        }
        .disabled(saving)
        .opacity(saving ? 0.6 : 1)
        .onReceive(ScreenRecorder.shared.$isRecording) { recording = $0 }
        .onReceive(ScreenRecorder.shared.$isSaving) { saving = $0 }
    }
}

/// The keyboard's backlight: a disc like the Display's, whose popover holds the slider and the
/// switch for following the room's light. A slider of its own on the rail cost the room of
/// two and a half discs, and was the first control a file on the shelf pushed off the rail —
/// and back on again on the Shelf section, where AirDrop stands down. Right-click the disc for
/// automatic adjustment, where the keyboard has it, as the lamp beside the slider had.
private struct KeyboardLightRailButton: View {
    @ObservedObject private var light = KeyboardLight.shared
    @State private var open = false

    var body: some View {
        RailDisc(symbol: RailControl.keyboardLight.symbol,
                 label: light.isAutomatic ? "Keyboard brightness, adjusting automatically" : "Keyboard brightness",
                 active: open) { open.toggle() }
            .contextMenu {
                Toggle("Adjust Keyboard Brightness Automatically", isOn: automatic)
                    .disabled(!light.canSetAutomatic)
            }
            .accessibilityAction(named: "Adjust automatically") {
                guard light.canSetAutomatic else { return }
                light.refresh()
                light.setAutomatic(!light.isAutomatic)
            }
            // `isAutomatic` is polled only while the popover is open, so after a change in System
            // Settings the menu's tick and the spoken label were stale, and a click could set
            // what was already set. Read again as the pointer arrives — before a right-click can
            // open the menu — and once the rail has finished arriving (`RailAssembly.window`),
            // off the pass that mounts it.
            .onHover { inside in
                if inside { light.refresh() }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + RailAssembly.window) { light.refresh() }
            }
            // Under the rail, the way the Display disc's popover opens.
            .popover(isPresented: $open, arrowEdge: .bottom) {
                KeyboardLightModuleView()
            }
    }

    private var automatic: Binding<Bool> {
        Binding(get: { light.isAutomatic }, set: { light.setAutomatic($0) })
    }
}

/// What the keyboard's disc opens: the backlight's slider and its Automatic switch. Built the
/// way `DisplayModuleView` is, from the system's own controls in the system's colours, since a
/// popover is its own window; and, like it, a viewer of the service for as long as it is open,
/// which is the only time the level is polled.
private struct KeyboardLightModuleView: View {
    @ObservedObject private var light = KeyboardLight.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Brightness")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Image(systemName: "light.min")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(get: { light.level }, set: { light.set($0) }), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Keyboard brightness")
                    .accessibilityValue("\(Int((light.level * 100).rounded())) percent")
                Image(systemName: "light.max")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Divider()
            // A checkbox, whose name takes the click as well as its box.
            Toggle("Adjust Keyboard Brightness Automatically",
                   isOn: Binding(get: { light.isAutomatic }, set: { light.setAutomatic($0) }))
                .font(.system(size: 12))
                .disabled(!light.canSetAutomatic)
        }
        .padding(14)
        .frame(width: DisplayModuleView.width, alignment: .leading)
        .onAppear { light.viewerAppeared() }
        .onDisappear { light.viewerDisappeared() }
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
/// has to fit: the panel's content width. `WindowsAndControlsTests` adds them up.
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
    /// The least the spacer in the middle may be.
    static let minSpacer: CGFloat = 8

    /// The fixed left-hand end: the volume with its glyph, the output picker when there is a
    /// second output, and the brightness with its glyph when there is a display that has one.
    static func leading(hasPicker: Bool, hasBrightness: Bool) -> CGFloat {
        var width = glyph + groupGap + volumeSlider
        if hasPicker { width += gap + button }
        if hasBrightness { width += gap + glyph + groupGap + brightnessSlider }
        return width
    }

    /// What is left for the catalog's controls after the left-hand end, the gap before the
    /// spacer and the least the spacer may be. Each control spends `cost(of:)` of it.
    static func room(hasPicker: Bool, hasBrightness: Bool,
                     width: CGFloat = IslandLayout.panelContentWidth) -> CGFloat {
        width - leading(hasPicker: hasPicker, hasBrightness: hasBrightness) - gap - minSpacer
    }

    /// How wide a control is drawn: a disc, every one of them. The keyboard's backlight was a
    /// lamp and a slider, 104 pt of a right-hand end that is short of room; its slider is in
    /// the popover its disc opens now, the way the displays' are in the Display disc's.
    static func width(of control: RailControl) -> CGFloat {
        button
    }

    /// A control and the gap in front of it.
    static func cost(of control: RailControl) -> CGFloat {
        gap + width(of: control)
    }
}

/// Display brightness as the rail reads and writes it, through the same private DisplayServices
/// calls the brightness HUD watches.
///
/// The level is published so the rail's slider follows the brightness keys and anything else
/// that dims the screen, rather than showing whatever it read the one time it appeared. There
/// is no notification for brightness, so it is polled — but only while the rail is on screen,
/// and slower whenever the energy policy says so.
///
/// Every read is made on `queue`. One is cheap, but it is a walk of the display list and a call
/// into a private framework — the first of them opens that framework — and they were made on
/// the main thread twice a second for as long as the rail was up, and once more at the moment
/// the rail was mounted, inside the spring that opens the panel. Only what is shown is decided
/// here. Writes to the driven display stay where the slider is: the slider must not wait on a
/// queue to move.
///
/// `level` is the driven display's: the built-in panel, or with the lid shut the main display
/// (`BrightnessMonitor.drivenDisplay`) — the one the brightness keys, the Display popover's first
/// slider and the Option-scroll all mean. A rail on a second display's island drove that same
/// panel, so the slider under a monitor dimmed the MacBook beside it. Each rail says which
/// display its panel is on (`watch`), and a display that answers DisplayServices is read here as
/// well (`panelLevels`) and driven by the slider on its own island (`railTarget`).
final class BrightnessControl: ObservableObject {
    static let shared = BrightnessControl()
    private let monitor = BrightnessMonitor()
    /// Where DisplayServices is read. Serial, and one reading at a time: a poll that comes round
    /// while the last one is still out is folded into it.
    private let queue = DispatchQueue(label: "com.macnotchisland.brightness", qos: .userInitiated)
    private var pass = RadioPass()
    private var timer: Timer?
    private var viewers = 0
    private var energyCancellable: AnyCancellable?
    /// Held for as long as the app runs, because a display can be plugged in at any point in it.
    private var screenObserver: NSObjectProtocol?
    /// A write the display has not reported back yet. Until it does, the slider keeps showing
    /// what the user set instead of flickering back for one poll. Held on the clock that only
    /// counts forwards: on the wall clock a backwards step would freeze the slider for as long
    /// as the offset lasted, and a forwards one would clear it at once.
    private var pending: (value: Double, until: TimeInterval)?
    /// The displays the rails are on, each with how many rails are on it (`watch`).
    private var watched: [CGDirectDisplayID: Int] = [:]
    /// Writes to those displays not reported back yet, as `pending` is for the driven one.
    private var panelPending: [CGDirectDisplayID: (value: Double, until: TimeInterval)] = [:]

    @Published private(set) var level: Double = 0.5
    /// Whether there is a brightness to set at all: a Mac driving nothing but an external display
    /// has none, and the rail leaves the slider out rather than showing one that does nothing.
    /// Kept rather than asked, because the rail's body wants it on every volume change, every
    /// hover and every pass of the poll below, and the answer costs a walk of the display list
    /// and a DisplayServices call. A display cannot arrive without the screen arrangement
    /// changing, and the screen arrangement changing is announced.
    @Published private(set) var isAvailable = false
    /// The display `level` belongs to, as the last reading found it; nil until one has landed.
    @Published private(set) var drivenDisplay: CGDirectDisplayID?
    /// The level of every other display a rail is on that answers DisplayServices. A display
    /// that does not answer is not here, and its rail's slider drives the driven display.
    @Published private(set) var panelLevels: [CGDirectDisplayID: Double] = [:]

    static let pollInterval: TimeInterval = 0.5
    static let writeSettle: TimeInterval = 1.0

    /// The poll's interval at a given energy multiplier. Pure, so it is tested.
    ///
    /// It ran twice a second whatever the policy said — on battery, in Low Power Mode, and
    /// under a lock with the panel left open — while every other poller in the rail backed off.
    static func scaledPollInterval(multiplier: Double) -> TimeInterval {
        pollInterval * max(1, multiplier)
    }

    /// The first reading is asked for here and lands a moment later. The app makes this at
    /// launch, well before any rail is drawn, so the answer is in by the time one is.
    private init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
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

    /// Sets the driven display: the built-in panel, or with the lid shut the main display.
    func set(_ value: Double) {
        let clamped = min(1, max(0, value))
        Self.lastLocalWrite = LocalWrite.now()
        pending = (clamped, LocalWrite.now() + Self.writeSettle)
        if level != clamped { level = clamped }
        _ = monitor.setBrightness(Float(clamped))
    }

    /// Sets another display a rail is on (`railTarget`). Written on the queue, as the Display
    /// popover writes the displays it owns (`DisplayControl.setBrightness`): a display on the far
    /// end of a cable answers in its own time, and the slider must not wait for it. Main thread.
    func set(_ value: Double, display: CGDirectDisplayID) {
        let clamped = min(1, max(0, value))
        panelPending[display] = (clamped, LocalWrite.now() + Self.writeSettle)
        if panelLevels[display] != clamped { panelLevels[display] = clamped }
        queue.async { _ = BrightnessMonitor.setBrightness(Float(clamped), of: display) }
    }

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        refresh()
        scheduleTimer()
        energyCancellable = EnergyPolicy.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        energyCancellable = nil
    }

    /// The poll at the policy's current interval, rebuilt only when that has changed: a rebuild
    /// pushes the next reading back by a whole interval.
    private func scheduleTimer() {
        guard viewers > 0 else { return }
        let interval = Self.scaledPollInterval(multiplier: EnergyPolicy.shared.pollingMultiplier)
        if let timer, abs(timer.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - The display a rail is on

    /// A rail on `display`'s island is on screen: that display is read on every pass until the
    /// last rail on it has gone (`unwatch`). Balanced one for one. Main thread.
    func watch(_ display: CGDirectDisplayID) {
        watched[display, default: 0] += 1
        if watched[display] == 1, viewers > 0 { refresh() }
    }

    func unwatch(_ display: CGDirectDisplayID) {
        guard let count = watched[display] else { return }
        guard count <= 1 else {
            watched[display] = count - 1
            return
        }
        watched[display] = nil
        panelPending[display] = nil
        if panelLevels[display] != nil { panelLevels[display] = nil }
    }

    /// The display a panel is on: the screen whose island answers to `panelID`
    /// (`NotchPanel.panelID(for:)`), by the number the window server knows it by — the way
    /// `DisplayControl` puts a name to a display. Nil for a panel on no screen the Mac still
    /// has. Main thread.
    static func display(forPanel panelID: String) -> CGDirectDisplayID? {
        for screen in NSScreen.screens where NotchPanel.panelID(for: screen) == panelID {
            return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        return nil
    }

    /// A display's own name, the one System Settings shows. Main thread.
    static func name(of display: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }?.localizedName
    }

    /// Which display the slider on a panel drives, when it is not the driven one: the panel's
    /// own display, when that answers DisplayServices (`answering`). Nil means the driven
    /// display — for a panel on it, for a display that does not answer, and for a panel whose
    /// display is not known. Pure, so it is tested.
    static func railTarget(panelDisplay: CGDirectDisplayID?, driven: CGDirectDisplayID?,
                           answering: Set<CGDirectDisplayID>) -> CGDirectDisplayID? {
        guard let panelDisplay, panelDisplay != driven, answering.contains(panelDisplay) else { return nil }
        return panelDisplay
    }

    /// What the rail's slider is called, and says in its tooltip. "Brightness" wherever it
    /// drives the display the panel is on; where it cannot — a monitor that does not answer —
    /// it drives the built-in panel, and with more than one display online it says which,
    /// rather than dimming a screen the user is not looking at without a word. Pure.
    static func sliderLabel(drivenName: String?, drivesPanelsOwn: Bool, displaysOnline: Int) -> String {
        guard !drivesPanelsOwn, displaysOnline > 1, let drivenName, !drivenName.isEmpty else { return "Brightness" }
        return "Brightness of \(drivenName)"
    }

    // MARK: - Reading

    /// One pass: the driven display, and every other display a rail is on.
    private struct Reading {
        var driven: CGDirectDisplayID
        var level: Double?
        var others: [CGDirectDisplayID: Double]
    }

    /// Asks the displays, on `queue`. Main thread; returns at once.
    private func refresh() {
        guard pass.start() else { return }
        let others = Array(watched.keys)
        queue.async {
            let driven = BrightnessMonitor.currentDrivenDisplay()
            let level = BrightnessMonitor.brightness(of: driven).map { Double($0) }
            var levels: [CGDirectDisplayID: Double] = [:]
            for id in others where id != driven {
                if let value = BrightnessMonitor.brightness(of: id) { levels[id] = min(1, max(0, Double(value))) }
            }
            let reading = Reading(driven: driven, level: level, others: levels)
            DispatchQueue.main.async { [weak self] in self?.show(reading) }
        }
    }

    /// Where every reading lands, on the main thread.
    private func show(_ reading: Reading) {
        let again = pass.finish()
        take(reading)
        // The screens changed while this reading was out; the answer that counts is the next.
        if again { refresh() }
    }

    private func take(_ reading: Reading) {
        if drivenDisplay != reading.driven { drivenDisplay = reading.driven }
        takeOthers(reading.others)
        // Every reading is also an answer about whether there is anything to read, which is the
        // only thing that keeps `isAvailable` honest between one screen arrangement and the next.
        if isAvailable != (reading.level != nil) { isAvailable = reading.level != nil }
        guard let value = reading.level else { return }
        // A reading that left before the slider moved lands after it: `pending` is what keeps
        // the slider from being pulled back to it.
        if let pending {
            guard LocalWrite.now() >= pending.until || abs(pending.value - value) < 0.02 else { return }
            self.pending = nil
        }
        if abs(level - value) > 0.001 { level = value }
    }

    /// The other displays, under the same holds as the driven one. Only displays still watched
    /// are kept: a pass that left before a rail went away can land after it.
    private func takeOthers(_ readings: [CGDirectDisplayID: Double]) {
        var next: [CGDirectDisplayID: Double] = [:]
        for (id, value) in readings where watched[id] != nil {
            let shown = panelLevels[id]
            if let hold = panelPending[id] {
                guard LocalWrite.now() >= hold.until || abs(hold.value - value) < 0.02 else {
                    next[id] = shown ?? hold.value
                    continue
                }
                panelPending[id] = nil
            }
            next[id] = shown.map { abs($0 - value) > 0.001 ? value : $0 } ?? value
        }
        if next != panelLevels { panelLevels = next }
    }
}
