import AppKit
import SwiftUI

/// Control Centre's three lists, in the island: the networks this Mac can see, the devices it
/// is paired with, and where the sound goes and comes from — each with its own switch above it.
///
/// The rail under every section already carries the toggles — Wi-Fi on, Bluetooth on, the
/// volume, the brightness, light and dark. What it cannot carry, in thirty-point discs, is a
/// *list*: the café's network, the headphones in the drawer, the microphone that is not the
/// one you meant. Those are the three things that still sent people to the menu bar, and they
/// are here.
struct ControlsSectionView: View {
    @ObservedObject private var toggles = SystemToggles.shared
    @ObservedObject private var wifi = WiFiScanner.shared
    @ObservedObject private var sound = AudioOutputs.shared
    @State private var devices: [BluetoothMonitor.Paired] = []

    /// Three columns with a gutter between them, filling the section's width.
    static let gutter: CGFloat = 18
    static let columns = 3
    static var columnWidth: CGFloat {
        ((IslandLayout.panelContentWidth - gutter * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
    }
    static let rowHeight: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: Self.gutter) {
            column(title: "Wi-Fi",
                   symbol: toggles.wifiOn ? "wifi" : "wifi.slash",
                   lit: toggles.wifiOn,
                   note: toggles.hasWiFi ? (toggles.wifiOn ? nil : "Off") : "Not on this Mac",
                   trailing: {
                       if toggles.hasWiFi {
                           PillButton(title: toggles.wifiOn ? "On" : "Off",
                                      tint: toggles.wifiOn ? Color.accentColor : .white.opacity(0.7),
                                      prominent: toggles.wifiOn) { toggles.toggleWiFi() }
                               .environment(\.islandCompactControls, true)
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
                           PillButton(title: toggles.bluetoothOn ? "On" : "Off",
                                      tint: toggles.bluetoothOn ? Color.accentColor : .white.opacity(0.7),
                                      prominent: toggles.bluetoothOn) { toggles.toggleBluetooth() }
                               .environment(\.islandCompactControls, true)
                       }
                   }) {
                bluetoothList
            }
            column(title: "Sound",
                   symbol: sound.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                   lit: !sound.isMuted,
                   note: soundEntries.isEmpty ? "No devices" : nil,
                   trailing: {
                       if sound.hasMute {
                           // Control Centre has no mute at all — you drag the slider to nothing
                           // and drag it back afterwards, guessing where it was.
                           PillButton(title: sound.isMuted ? "Muted" : "On",
                                      tint: sound.isMuted ? .white.opacity(0.7) : Color.accentColor,
                                      prominent: !sound.isMuted) { sound.setMuted(!sound.isMuted) }
                               .environment(\.islandCompactControls, true)
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
            devices = BluetoothMonitor.paired()
        }
        .onDisappear {
            toggles.viewerDisappeared()
            wifi.viewerDisappeared()
            sound.viewerDisappeared()
        }
        // The radio answers in its own time; the list catches up when it does.
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            devices = BluetoothMonitor.paired()
        }
    }

    // MARK: - A column

    @ViewBuilder
    private func column<Trailing: View, Content: View>(title: String, symbol: String, lit: Bool,
                                                       note: String?,
                                                       @ViewBuilder trailing: () -> Trailing,
                                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
        if wifi.networks.isEmpty {
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
                        row(title: device.name,
                            trailing: {
                                Image(systemName: device.symbol)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                            },
                            lock: false,
                            isOn: device.isConnected) {
                            BluetoothMonitor.setConnected(!device.isConnected, address: device.address)
                            // The radio takes a moment; ask again once it has had one.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                self.devices = BluetoothMonitor.paired()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Where the sound goes, and comes from

    private var soundEntries: [SoundList.Entry] {
        SoundList.entries(outputs: sound.devices, current: sound.current,
                          inputs: sound.inputs, currentInput: sound.currentInput)
    }

    @ViewBuilder
    private var soundList: some View {
        IslandScrollStrip(axis: .vertical) {
            VStack(spacing: 0) {
                ForEach(soundEntries) { entry in
                    switch entry {
                    case .heading(let title):
                        Text(title)
                            .font(.system(size: 9.5, weight: .semibold))
                            .kerning(0.4)
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 15)
                            .padding(.top, title == SoundList.input ? 5 : 0)
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
                    }
                }
            }
        }
    }

    // MARK: - One row of any list

    private func row<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing,
                                     lock: Bool, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // A tick where the joined network and the connected device are, which is how
                // every list of things on the Mac marks the ones that are on.
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 12)
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
        .accessibilityLabel(isOn ? "\(title), on" : title)
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
