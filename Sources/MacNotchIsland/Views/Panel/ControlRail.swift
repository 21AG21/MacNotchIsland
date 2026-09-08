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
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var center: ActivityCenter
    @State private var brightness: Double = BrightnessControl.shared.current() ?? 0.5

    var body: some View {
        // Budget at 632 pt with everything showing: two sliders (208 and 168), four to five
        // 30 pt buttons, 12 pt gaps, and a spacer that soaks up the rest.
        HStack(spacing: 12) {
            volume
            if BrightnessControl.shared.isAvailable { brightnessControl }
            Spacer(minLength: 8)
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
        .onAppear { outputs.viewerAppeared() }
        .onDisappear { outputs.viewerDisappeared() }
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
            IslandSlider(value: outputs.isMuted ? 0 : Double(outputs.volume ?? 0)) { outputs.setVolume(Float($0)) }
                .frame(width: 176)
                .opacity(outputs.volume == nil ? 0.3 : 1)
                .disabled(outputs.volume == nil)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(((outputs.volume ?? 0) * 100).rounded())) percent")
        }
    }

    private var brightnessControl: some View {
        HStack(spacing: 8) {
            Image(systemName: brightness < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            IslandSlider(value: brightness) { value in
                brightness = value
                BrightnessControl.shared.set(value)
            }
            .frame(width: 136)
            .accessibilityLabel("Brightness")
            .accessibilityValue("\(Int((brightness * 100).rounded())) percent")
        }
        .onAppear { if let level = BrightnessControl.shared.current() { brightness = level } }
    }

    // MARK: - Buttons

    private func railButton(symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(active ? 0.9 : 0.10))
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
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
/// calls the brightness HUD watches. Nothing here is a listener; every read is fresh.
final class BrightnessControl {
    static let shared = BrightnessControl()
    private let monitor = BrightnessMonitor()

    var isAvailable: Bool { monitor.currentBrightness() != nil }
    func current() -> Double? { monitor.currentBrightness().map { Double($0) } }
    func set(_ value: Double) { _ = monitor.setBrightness(Float(min(1, max(0, value)))) }
}
