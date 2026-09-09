import AppKit
import SwiftUI

/// Control Centre's two lists, in the island: the networks this Mac can see and the devices it
/// is paired with, each with its own switch above it.
///
/// The rail under every section already carries the toggles — Wi-Fi on, Bluetooth on, the
/// volume, the brightness, light and dark. What it cannot carry, in thirty-point discs, is a
/// *list*: the café's network, the headphones in the drawer. Those are the two things that
/// still sent people to the menu bar, and they are here.
struct ControlsSectionView: View {
    @ObservedObject private var toggles = SystemToggles.shared
    @ObservedObject private var wifi = WiFiScanner.shared
    @State private var devices: [BluetoothMonitor.Paired] = []

    /// Two columns with a gutter between them, filling the section's width.
    static let gutter: CGFloat = 20
    static var columnWidth: CGFloat { ((IslandLayout.panelContentWidth - gutter) / 2).rounded(.down) }
    static let rowHeight: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: Self.gutter) {
            column(title: "Wi-Fi",
                   symbol: toggles.wifiOn ? "wifi" : "wifi.slash",
                   isOn: toggles.wifiOn,
                   available: toggles.hasWiFi,
                   toggle: { toggles.toggleWiFi() }) {
                wifiList
            }
            column(title: "Bluetooth",
                   symbol: "dot.radiowaves.left.and.right",
                   isOn: toggles.bluetoothOn,
                   available: toggles.hasBluetooth,
                   toggle: { toggles.toggleBluetooth() }) {
                bluetoothList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            toggles.viewerAppeared()
            wifi.viewerAppeared()
            devices = BluetoothMonitor.paired()
        }
        .onDisappear {
            toggles.viewerDisappeared()
            wifi.viewerDisappeared()
        }
        // The radio answers in its own time; the list catches up when it does.
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            devices = BluetoothMonitor.paired()
        }
    }

    // MARK: - A column

    @ViewBuilder
    private func column<Content: View>(title: String, symbol: String, isOn: Bool, available: Bool,
                                       toggle: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(isOn ? 0.9 : 0.4))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 8)
                if available {
                    PillButton(title: isOn ? "On" : "Off",
                               tint: isOn ? Color.accentColor : .white.opacity(0.7),
                               prominent: isOn, action: toggle)
                        .environment(\.islandCompactControls, true)
                }
            }
            .frame(height: SectionMetrics.headerHeight)
            if available, isOn {
                content()
            } else {
                Text(available ? "Off" : "Not on this Mac")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.35))
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

    @ViewBuilder
    private var bluetoothList: some View {
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
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { devices = BluetoothMonitor.paired() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - One row of either list

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
