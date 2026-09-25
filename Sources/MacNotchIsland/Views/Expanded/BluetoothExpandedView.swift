import SwiftUI

struct BluetoothExpandedView: View {
    let state: BluetoothState
    let geometry: NotchGeometry
    @Environment(\.insidePanel) private var insidePanel
    @ObservedObject private var airPods = AirPodsControl.shared

    /// The device's disc and the gap after it, which the pills are indented by so that they
    /// start under the name.
    static let discWidth: CGFloat = 44
    static let rowSpacing: CGFloat = 10

    /// One battery the device reports: "L 92%", "Case 64%", or a single unlabelled figure.
    private struct Reading: Identifiable {
        let label: String
        let percent: Int
        var id: String { label }
    }

    var body: some View {
        VStack(spacing: 0) {
            NotchClearance(geometry: geometry, extra: 12)
            // Closer than the other cards' 14, because this row carries up to three readings
            // and a button beside the name: at 14, with 20 between the readings and a 12 pt
            // spacer, "AirPods Pro" had 59 pt of a 400 pt row and needs about 85.
            HStack(spacing: Self.rowSpacing) {
                Image(systemName: state.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: Self.discWidth, height: Self.discWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.isConnected ? "Connected" : "Disconnected")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                // Said once, in the row's sentence, see `hidesItsWords`.
                .accessibilityHidden(Self.hidesItsWords(state))
                Spacer(minLength: 0)
                // One right-aligned line of figures rather than a row of donuts: the label is
                // small and quiet, the number carries the weight.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ForEach(readings) { reading in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if !reading.label.isEmpty {
                                Text(reading.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            Text("\(reading.percent)%")
                                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(valueTint(reading.percent))
                        }
                    }
                }
                .accessibilityHidden(Self.hidesItsWords(state))
                // Reconnecting a pair of AirPods is a trip to System Settings, and the island
                // already knows they are there. Only where the address is known, which is
                // everything the radio itself told us about.
                if Self.offersConnection(state) {
                    CircleActionButton(symbol: state.isConnected ? "xmark" : "link",
                                       tint: state.isConnected ? .white : Color.named("blue"),
                                       label: Self.connectionLabel(for: state)) {
                        BluetoothMonitor.setConnected(!state.isConnected, address: state.address)
                    }
                }
            }
            .islandContentColumn()
            .padding(.bottom, insidePanel || showsModes ? 0 : 16)
            // One sentence for the name and the batteries, and the button left where VoiceOver
            // can reach it, see `readsAsOneElement`.
            .accessibilityElement(children: Self.readsAsOneElement(state) ? .ignore : .contain)
            .accessibilityLabel(Self.accessibilitySummary(for: state))
            // Noise control, under the name it belongs to, the way Control Centre hangs it
            // under a pair of AirPods: the pills, and what the lit one is called.
            if showsModes {
                HStack(spacing: Self.rowSpacing) {
                    ListeningModePicker(control: airPods, pillWidth: ListeningModeMetrics.cardPill)
                    if let current = airPods.current {
                        Text(current.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: ListeningModeMetrics.height)
                .padding(.leading, Self.discWidth + Self.rowSpacing)
                .padding(.top, ActivityContent.cardListeningModes - ListeningModeMetrics.height)
                .islandContentColumn()
                .padding(.bottom, insidePanel ? 0 : 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: insidePanel ? .center : .top)
        .onAppear { airPods.viewerAppeared() }
        .onDisappear { airPods.viewerDisappeared() }
    }

    /// The pills go on the pair the modes belong to, while it is connected. On a card they also
    /// need the room the card was made with — it is only as tall as `offersListeningModes` said
    /// when it went up; in the panel there is always room.
    private var showsModes: Bool {
        state.isConnected && (insidePanel || state.offersListeningModes)
            && airPods.drives(name: state.name, address: state.address)
    }

    /// Whichever batteries the device actually reports, left to right.
    private var readings: [Reading] {
        var out: [Reading] = []
        if let l = state.batteryLeft { out.append(Reading(label: "L", percent: l)) }
        if let r = state.batteryRight { out.append(Reading(label: "R", percent: r)) }
        if let c = state.batteryCase { out.append(Reading(label: "Case", percent: c)) }
        if state.batteryLeft == nil, state.batteryRight == nil, let s = state.batterySingle {
            out.append(Reading(label: "", percent: s))
        }
        return out
    }

    /// Only the emptiest battery goes red, and only once it is genuinely low.
    private func valueTint(_ percent: Int) -> Color {
        let lowest = readings.map({ $0.percent }).min()
        return (BluetoothState.isLow(percent) && percent == lowest) ? Color.named("red") : Color.white
    }

    /// Whether the card can connect or disconnect the device: wherever the radio told us its
    /// address.
    static func offersConnection(_ state: BluetoothState) -> Bool { !state.address.isEmpty }

    /// "Connect Beats", "Disconnect AirPods Pro".
    static func connectionLabel(for state: BluetoothState) -> String {
        state.isConnected ? "Disconnect \(state.name)" : "Connect \(state.name)"
    }

    /// Whether the card's row can be read as one sentence and nothing else. Pure, so the rule
    /// is tested.
    ///
    /// Only while there is no button in it. The row was `.ignore`d whole, which folded the
    /// Connect / Disconnect button into the sentence with everything else: VoiceOver read the
    /// name and the batteries, and had no way to press the one thing on the card that does
    /// anything. With the button there the row is a container, as the Download and Calendar
    /// cards are — the sentence as its label, the button inside it.
    static func readsAsOneElement(_ state: BluetoothState) -> Bool { !offersConnection(state) }

    /// Whether the name, the status and the readings are kept from VoiceOver as well: whenever
    /// the row is a container. A container reads its label and then goes on into what is in
    /// it, so the card was read twice — "AirPods Pro connected, left 92 percent, …", then
    /// "AirPods Pro", "Connected", "L", "92%" one by one — before the button. With the words
    /// hidden it is one sentence and the button. Where the row is one element nothing inside
    /// it is read anyway. Pure, so the rule is tested.
    static func hidesItsWords(_ state: BluetoothState) -> Bool { !readsAsOneElement(state) }

    /// "AirPods Pro connected, left 92 percent, right 88 percent, case 64 percent", built from
    /// whichever batteries the device actually reports.
    static func accessibilitySummary(for state: BluetoothState) -> String {
        var parts = [state.isConnected ? "\(state.name) connected" : "\(state.name) disconnected"]
        if let l = state.batteryLeft { parts.append("left \(l) percent") }
        if let r = state.batteryRight { parts.append("right \(r) percent") }
        if let c = state.batteryCase { parts.append("case \(c) percent") }
        if state.batteryLeft == nil, state.batteryRight == nil, let s = state.batterySingle {
            parts.append("\(s) percent battery")
        }
        return parts.joined(separator: ", ")
    }
}

extension BluetoothState {
    /// The level a device's battery turns red at, on the AirPods card and in the Controls
    /// list alike. It was 20 on the card and 10 in the list, so the same pair of AirPods at
    /// 15% was red in one and grey in the other. 20 is where the Mac's own battery warns, and
    /// where a phone's goes red.
    static let lowBattery = 20

    /// Whether `percent` is low enough to be drawn in red. Pure, so the one threshold is tested.
    static func isLow(_ percent: Int) -> Bool { percent <= lowBattery }
}
