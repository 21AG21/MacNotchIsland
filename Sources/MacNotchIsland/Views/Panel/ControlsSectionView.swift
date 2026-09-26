import AppKit
import SwiftUI

/// Control Centre's three lists, in the island: the networks this Mac can see, the devices it
/// is paired with, and where the sound goes and comes from — each with its own switch above it.
///
/// The rail under every section already carries the toggles — Wi-Fi on, Bluetooth on, the
/// volume, the brightness, the Display popover. What it cannot carry, in thirty-point discs, is a
/// *list*: the café's network, the headphones in the drawer, the microphone that is not the
/// one you meant. Those are the three things that still sent people to the menu bar, and they
/// are here.
///
/// Above them, when there are any, the rail's overflow: the controls somebody switched on that
/// the rail had no room for, in the same discs and the same order, so a control is never simply
/// gone because the rail was full. Nor because this section's switch is off: while there is
/// overflow the section stays in the panel (`HomeSection.isShown`). See `RailPlan`.
struct ControlsSectionView: View {
    /// The panel's mirror, for the mirror's disc when it is one of the overflow.
    var showingMirror: Binding<Bool> = .constant(false)
    @ObservedObject private var toggles = SystemToggles.shared
    @ObservedObject private var wifi = WiFiScanner.shared
    @ObservedObject private var sound = AudioOutputs.shared
    // Watched for what they decide about the rail's overflow, as the rail watches them.
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var brightness = BrightnessControl.shared
    @ObservedObject private var keyboard = KeyboardLight.shared
    @ObservedObject private var airPods = AirPodsControl.shared
    @State private var devices: [BluetoothMonitor.Paired] = []
    /// The address of the AirPods row that is open on its listening modes, if one is.
    @State private var expandedAirPods: String?
    /// The route picker on the Sound column's last row, so the whole row can open it.
    @State private var routePicker = AirPlayRouteHandle()
    /// The paired list's four-second look, made once for the life of the view. It was built in
    /// `onReceive` in the body — the mistake `HomePanelPane` warns against — so every pass of a
    /// body that redraws for Wi-Fi, sound, the rail and the AirPods alike was a new timer, and
    /// the four seconds started over each time; on a busy panel the list hardly refreshed.
    /// Held in `@State` rather than a `let`, which the panel's own redraws would build anew.
    @State private var devicesTicker = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    /// Three columns with a gutter between them, filling the section's width.
    static let gutter: CGFloat = 18
    static let columns = 3
    static var columnWidth: CGFloat {
        ((IslandLayout.panelContentWidth - gutter * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
    }
    static let rowHeight: CGFloat = 26
    /// Between the overflow row and the columns under it: the gap under a section's header.
    static let overflowGap: CGFloat = SectionMetrics.gapBelowHeader
    /// The tick's column at the head of every row, and the gap after it.
    static let tickWidth: CGFloat = 12
    static let rowSpacing: CGFloat = 6

    // MARK: The AirPods row, open

    /// Between the AirPods' row and its pills.
    static let modesGap: CGFloat = 2
    /// The pills start under the name, not under the tick.
    static var modesIndent: CGFloat { tickWidth + rowSpacing }
    /// What the pills share: the column after the indent, and after the disconnect button that
    /// ends their line — the row's own click opens it rather than disconnecting.
    static var modesWidth: CGFloat { columnWidth - modesIndent - rowSpacing - IslandHit.minimum }
    /// The row and its line of pills: two rows' worth of the column, so the rows under it keep
    /// to the same grid.
    static var expandedRowHeight: CGFloat { rowHeight + modesGap + ListeningModeMetrics.height }

    var body: some View {
        // Asked the way the rail asks it, on the one section that is never the shelf, so the two
        // agree on which controls are where.
        let overflow = RailPlan.current(prefs: prefs, showingShelf: false,
                                        showingMirror: showingMirror.wrappedValue).spill
        return VStack(alignment: .leading, spacing: Self.overflowGap) {
            if !overflow.isEmpty {
                HStack(spacing: RailMetrics.gap) {
                    ForEach(overflow, id: \.self) { control in
                        RailControlView(control: control, showingMirror: showingMirror)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: RailMetrics.button)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("More controls")
            }
            lists
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The three columns.
    private var lists: some View {
        HStack(alignment: .top, spacing: Self.gutter) {
            column(title: "Wi-Fi",
                   symbol: toggles.wifiOn ? "wifi" : "wifi.slash",
                   lit: toggles.wifiOn,
                   note: toggles.hasWiFi ? (toggles.wifiOn ? nil : "Off") : "Not on this Mac",
                   trailing: {
                       if toggles.hasWiFi {
                           HeaderSwitch(subject: "Wi-Fi", isOn: toggles.wifiOn) { toggles.toggleWiFi() }
                       }
                   }) {
                wifiList
            }
            column(title: "Bluetooth",
                   symbol: "dot.radiowaves.left.and.right",
                   lit: toggles.bluetoothOn,
                   note: toggles.hasBluetooth ? (toggles.bluetoothOn ? nil : "Off") : "Not on this Mac",
                   trailing: {
                       if toggles.hasBluetooth {
                           HeaderSwitch(subject: "Bluetooth", isOn: toggles.bluetoothOn) { toggles.toggleBluetooth() }
                       }
                   }) {
                bluetoothList
            }
            column(title: "Sound",
                   symbol: sound.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                   lit: !sound.isMuted,
                   // Never a note in place of the list: the AirPlay row at its foot is always
                   // there, even on a Mac CoreAudio shows no devices for. See `soundList`.
                   note: nil,
                   trailing: {
                       if sound.hasMute {
                           // Control Centre has no mute at all — you drag the slider to nothing
                           // and drag it back afterwards, guessing where it was.
                           HeaderSwitch(subject: "Sound", isOn: !sound.isMuted, offTitle: "Muted") { sound.setMuted(!sound.isMuted) }
                       }
                   }) {
                soundList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            toggles.viewerAppeared()
            wifi.viewerAppeared()
            sound.viewerAppeared()
            airPods.viewerAppeared()
            devices = pairedDevices
        }
        .onDisappear {
            toggles.viewerDisappeared()
            wifi.viewerDisappeared()
            sound.viewerDisappeared()
            airPods.viewerDisappeared()
        }
        // The radio answers in its own time; the list catches up when it does.
        .onReceive(devicesTicker) { _ in
            devices = pairedDevices
        }
    }

    /// The paired list, read only once the tour is done. Reading it is a Bluetooth question,
    /// and before the tour that question is held back with the monitor's
    /// (`ServiceHub.wantsBluetooth`), so arriving here early does not put it on screen.
    private var pairedDevices: [BluetoothMonitor.Paired] {
        prefs.hasSeenWelcome ? BluetoothMonitor.paired() : []
    }

    // MARK: - A column

    @ViewBuilder
    private func column<Trailing: View, Content: View>(title: String, symbol: String, lit: Bool,
                                                       note: String?,
                                                       @ViewBuilder trailing: () -> Trailing,
                                                       @ViewBuilder content: () -> Content) -> some View {
        // The same gap under the column's header line as under every section's header, so the
        // first network sits where the first event, window or file does in the others.
        VStack(alignment: .leading, spacing: SectionMetrics.gapBelowHeader) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(lit ? 0.9 : 0.4))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 8)
                trailing()
            }
            .frame(height: SectionMetrics.headerHeight)
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                content()
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.columnWidth, alignment: .topLeading)
    }

    // MARK: - The networks

    @ViewBuilder
    private var wifiList: some View {
        if wifi.networks.isEmpty, wifi.needsLocation {
            // macOS keeps the names of the networks around from an app Location has refused,
            // so the list is empty on a Mac sitting on a perfectly good network, and "Nothing
            // in range" would be a wrong answer. The same offer Today makes for its weather.
            VStack(alignment: .leading, spacing: 6) {
                Text("Network names need Location")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.35))
                PillButton(title: "Allow Location", tint: .white.opacity(0.85)) {
                    SystemSettingsPane.location.open()
                }
                .environment(\.islandCompactControls, true)
                .accessibilityLabel(Text("Wi-Fi network names need your location. Open Location Services."))
            }
        } else if wifi.networks.isEmpty, wifi.locationUnasked {
            // Never asked: the question is this pill's to put, not the section's for having
            // been arrived on. See `WiFiScanner.locationUnasked`.
            VStack(alignment: .leading, spacing: 6) {
                Text("Network names need Location")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.35))
                PillButton(title: "Show names", tint: .white.opacity(0.85)) {
                    wifi.askForLocation()
                }
                .environment(\.islandCompactControls, true)
                .accessibilityLabel(Text("Wi-Fi network names need your location. Ask for Location."))
            }
        } else if wifi.networks.isEmpty {
            Text(wifi.isScanning ? "Looking…" : "Nothing in range")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.35))
        } else {
            IslandScrollStrip(axis: .vertical) {
                VStack(spacing: 0) {
                    ForEach(wifi.networks) { network in
                        row(title: network.ssid,
                            trailing: { WiFiBars(bars: network.bars) },
                            lock: network.isSecure && !network.isKnown,
                            isOn: network.isCurrent) {
                            wifi.join(network)
                        }
                    }
                }
            }
        }
    }

    // MARK: - The devices

    /// The list, or what the gallery was handed: `onAppear` never runs when the view is being
    /// drawn into an image rather than onto a screen, so the state it fills stays empty.
    private var shownDevices: [BluetoothMonitor.Paired] {
        devices.isEmpty && RenderMode.isGallery ? BluetoothMonitor.paired() : devices
    }

    @ViewBuilder
    private var bluetoothList: some View {
        let devices = shownDevices
        if devices.isEmpty {
            Text("Nothing paired")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.35))
        } else {
            IslandScrollStrip(axis: .vertical) {
                VStack(spacing: 0) {
                    ForEach(devices) { device in
                        // The connected pair the listening modes belong to opens on a click, the
                        // way its entry in Control Centre does; every other row still connects
                        // or disconnects.
                        let hasModes = device.isConnected && airPods.drives(name: device.name, address: device.address)
                        let open = hasModes && expandedAirPods == device.address
                        VStack(alignment: .leading, spacing: Self.modesGap) {
                            row(title: device.name,
                                trailing: {
                                    HStack(spacing: 5) {
                                        if let battery = device.battery {
                                            Text("\(battery)%")
                                                .font(.system(size: 10).monospacedDigit())
                                                .foregroundStyle(Self.batteryTint(battery))
                                        }
                                        Image(systemName: device.symbol)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.45))
                                        if hasModes {
                                            Image(systemName: open ? "chevron.up" : "chevron.down")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.white.opacity(0.35))
                                        }
                                    }
                                },
                                lock: false,
                                isOn: device.isConnected,
                                detail: device.battery.map { "\($0) percent" }) {
                                if hasModes {
                                    withAnimation(IslandMotion.content) {
                                        expandedAirPods = open ? nil : device.address
                                    }
                                } else {
                                    toggleConnection(device)
                                }
                            }
                            .accessibilityHint(hasModes ? (open ? "Hides noise control" : "Shows noise control") : "")
                            if open {
                                listeningModes(for: device)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggleConnection(_ device: BluetoothMonitor.Paired) {
        BluetoothMonitor.setConnected(!device.isConnected, address: device.address)
        // The radio takes a moment; ask again once it has had one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.devices = BluetoothMonitor.paired()
        }
    }

    /// The open AirPods row's second line: the listening modes as equal pills, and at its end the
    /// disconnect the row's own click gave up to open it.
    private func listeningModes(for device: BluetoothMonitor.Paired) -> some View {
        HStack(spacing: Self.rowSpacing) {
            ListeningModePicker(control: airPods,
                                pillWidth: ListeningModeMetrics.pillWidth(count: airPods.modes.count, in: Self.modesWidth))
            Button(action: {
                expandedAirPods = nil
                toggleConnection(device)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: IslandHit.minimum, height: ListeningModeMetrics.height)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(IslandButtonStyle())
            .help("Disconnect \(device.name)")
            .accessibilityLabel("Disconnect \(device.name)")
        }
        .padding(.leading, Self.modesIndent)
        .frame(height: ListeningModeMetrics.height)
    }

    /// Quiet grey for a level nobody needs to act on, and a warm red for the one that wants
    /// catching — the keyboard that will die mid-sentence this afternoon. Red from the level
    /// the AirPods card turns red at, see `BluetoothState.isLow`.
    static func batteryTint(_ percent: Int) -> Color {
        BluetoothState.isLow(percent) ? Color(red: 1, green: 0.42, blue: 0.4) : Color.white.opacity(0.45)
    }

    // MARK: - Where the sound goes, and comes from

    private var soundEntries: [SoundList.Entry] {
        SoundList.entries(outputs: sound.devices, current: sound.current,
                          inputs: sound.inputs, currentInput: sound.currentInput,
                          airPlay: sound.airPlay, airPlayCurrent: sound.airPlayCurrent)
    }

    @ViewBuilder
    private var soundList: some View {
        let entries = soundEntries
        IslandScrollStrip(axis: .vertical) {
            VStack(spacing: 0) {
                if entries.isEmpty {
                    Text("No devices")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Self.rowHeight)
                }
                ForEach(entries) { entry in
                    switch entry {
                    case .heading(let title):
                        Text(title)
                            .font(.system(size: 9.5, weight: .semibold))
                            .kerning(0.4)
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 15)
                            // Air above every heading but the first.
                            .padding(.top, entry.id == entries.first?.id ? 0 : 5)
                    case .device(let device, let isCurrent, let isInput):
                        row(title: device.shortName,
                            trailing: {
                                Image(systemName: isInput ? "mic.fill" : device.symbol)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                            },
                            lock: false,
                            isOn: isCurrent) {
                            if isInput { sound.selectInput(device) } else { sound.select(device) }
                        }
                    case .airPlay(let target, let isCurrent):
                        row(title: target.name,
                            trailing: {
                                Image(systemName: "airplayaudio")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                            },
                            lock: false,
                            isOn: isCurrent) {
                            sound.selectAirPlay(target)
                        }
                    }
                }
                airPlayPickerRow
            }
        }
    }

    /// The last row, always: the system's own AirPlay picker, one click from every receiver
    /// Control Centre knows about — whatever the list above made of the AirPlay device.
    private var airPlayPickerRow: some View {
        row(title: "AirPlay…",
            trailing: {
                if RenderMode.isGallery {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                } else {
                    AirPlayRoutePicker(handle: routePicker)
                        .frame(width: Self.pickerGlyph, height: Self.pickerGlyph)
                }
            },
            lock: false,
            isOn: false) {
            routePicker.open()
        }
    }

    /// The route picker's glyph: the same box the row's other glyphs sit in, a little larger,
    /// because AVKit draws its own glyph with air around it.
    static let pickerGlyph: CGFloat = 20

    // MARK: - One row of any list

    /// `detail` is what a row has to say beyond its name and its tick — a battery level, so
    /// far. Wi-Fi and Sound rows have nothing of the sort and leave it out.
    private func row<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing,
                                     lock: Bool, isOn: Bool, detail: String? = nil,
                                     action: @escaping () -> Void) -> some View {
        var label = isOn ? "\(title), on" : title
        if let detail { label += ", \(detail)" }
        return Button(action: action) {
            HStack(spacing: Self.rowSpacing) {
                // A tick where the joined network and the connected device are, which is how
                // every list of things on the Mac marks the ones that are on.
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: Self.tickWidth)
                    .opacity(isOn ? 1 : 0)
                Text(title)
                    .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isOn ? 1 : 0.75))
                    .lineLimit(1)
                if lock {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Spacer(minLength: 6)
                trailing()
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel(label)
    }
}

/// A column's switch: a pill on the header line that says what state the thing is in, lit
/// when it is on, and flips it on a click. `PillButton` at its compact size, but as wide as
/// the longer of its two words whichever it is showing.
///
/// Read out as a switch: named for its column, with its state as the value. It said only the
/// word on it, so VoiceOver heard "On", "Off" or "Muted" with nothing to say what was on, and
/// no sign that pressing it would flip it.
///
/// The pills were only as wide as the word on them, and they sit against the column's right
/// edge, so their left edge moved with the state: "Muted" is half as wide again as "On", and a
/// second click where the first had landed fell short of the pill and did nothing. The two
/// words are laid out on top of each other, the one not showing hidden, so the capsule and
/// the click it takes keep one size.
private struct HeaderSwitch: View {
    /// What it switches — the column's title.
    let subject: String
    let isOn: Bool
    var onTitle = "On"
    var offTitle = "Off"
    let action: () -> Void

    var body: some View {
        let tint = isOn ? Color.accentColor : Color.white.opacity(0.7)
        // Drawn at the header line's 22 pt and taking its click in 24, as `PillButton` does.
        let reach = IslandHit.outset(drawn: SectionMetrics.headerHeight)
        return Button(action: action) {
            ZStack {
                Text(onTitle).opacity(isOn ? 1 : 0)
                Text(offTitle).opacity(isOn ? 0 : 1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isOn ? PillButton.ink(on: tint) : tint)
            .padding(.horizontal, 9)
            .frame(height: SectionMetrics.headerHeight)
            .background(Capsule().fill(isOn ? tint : tint.opacity(0.18)))
            .padding(.vertical, reach)
            .contentShape(Capsule())
            .padding(.vertical, -reach)
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel(subject)
        .accessibilityValue(isOn ? onTitle : offTitle)
        .accessibilityAddTraits(.isToggle)
    }
}

/// Four bars, filled to the strength — the shape everybody already reads as signal.
struct WiFiBars: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { step in
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(Color.white.opacity(step <= bars ? 0.8 : 0.18))
                    .frame(width: 2, height: 3 + CGFloat(step) * 2)
            }
        }
        .frame(height: 11, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
