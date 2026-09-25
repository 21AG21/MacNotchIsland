import AppKit
import SwiftUI

/// The rail's Display popover, laid out the way Control Centre's Display module is: a
/// brightness slider for every display that takes one, then the round switches for Dark Mode,
/// Night Shift and True Tone. It opens from the sun on the rail, which used to be the light and
/// dark switch on its own — Dark Mode is the first switch in here.
///
/// A popover is its own window, drawn by the system in the system's colours, so everything in it
/// is a standard control rather than the island's white-on-black: it looks like the Mac's own
/// module because it is built from the same parts. The services are read as shared objects
/// rather than through the environment, which a popover's separate window does not always
/// carry across.
struct DisplayModuleView: View {
    @ObservedObject private var display = DisplayControl.shared
    @ObservedObject private var builtIn = BrightnessControl.shared
    @ObservedObject private var toggles = SystemToggles.shared
    /// Night Shift's warmth and "until tomorrow", shown under the switches after a right-click
    /// on Night Shift.
    @State private var showingNightShiftOptions = false

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display")
                .font(.system(size: 13, weight: .semibold))
            sliders
            Divider()
            HStack(alignment: .top, spacing: 8) {
                ModuleSwitch(title: "Dark Mode", symbol: "circle.lefthalf.filled", isOn: toggles.darkMode) {
                    toggles.toggleAppearance()
                }
                if display.hasNightShift {
                    ModuleSwitch(title: "Night Shift", symbol: "sun.horizon.fill", isOn: display.nightShiftOn) {
                        display.setNightShift(!display.nightShiftOn)
                    }
                    // A right-click is how Control Centre's own switches say there is more.
                    .overlay {
                        SecondaryClickCatcher {
                            withAnimation(.easeInOut(duration: 0.2)) { showingNightShiftOptions.toggle() }
                        }
                    }
                    .help("Right-click for warmth, and to turn it on until tomorrow")
                    .accessibilityAction(named: "Night Shift options") { showingNightShiftOptions.toggle() }
                }
                if display.hasTrueTone {
                    ModuleSwitch(title: "True Tone", symbol: "rays", isOn: display.trueToneOn,
                                 enabled: display.trueToneAvailable) {
                        display.setTrueTone(!display.trueToneOn)
                    }
                }
                Spacer(minLength: 0)
            }
            if showingNightShiftOptions, display.hasNightShift {
                nightShiftOptions
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .onAppear {
            display.viewerAppeared()
            builtIn.viewerAppeared()
            toggles.viewerAppeared()
        }
        .onDisappear {
            display.viewerDisappeared()
            builtIn.viewerDisappeared()
            toggles.viewerDisappeared()
        }
    }

    // MARK: - Brightness

    @ViewBuilder
    private var sliders: some View {
        if display.screens.isEmpty {
            Text(display.hasRead ? "No display here takes its brightness from this Mac." : "Reading the displays…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            ForEach(display.screens) { screen in
                VStack(alignment: .leading, spacing: 4) {
                    // Named only when there is more than one: a single slider is plainly this
                    // Mac's display, and its name is a label nobody needs.
                    if display.screens.count > 1 {
                        Text(screen.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(value: level(of: screen), in: 0...1)
                            .controlSize(.small)
                            .accessibilityLabel(sliderLabel(screen))
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// "Brightness", and which display's when there is more than one to tell apart.
    private func sliderLabel(_ screen: DisplayControl.Screen) -> String {
        display.screens.count > 1 ? "Brightness, \(screen.name)" : "Brightness"
    }

    /// The built-in panel is `BrightnessControl`'s, the same level the rail's slider shows; every
    /// other display is read and written here.
    private func level(of screen: DisplayControl.Screen) -> Binding<Double> {
        if screen.isBuiltIn {
            return Binding(get: { builtIn.level }, set: { builtIn.set($0) })
        }
        let id = screen.id
        return Binding(get: { display.screens.first(where: { $0.id == id })?.level ?? screen.level },
                       set: { display.setBrightness($0, display: id) })
    }

    // MARK: - Night Shift

    private var nightShiftOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let strength = display.nightShiftStrength {
                Text("Warmth")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("Less")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { strength }, set: { display.setNightShiftStrength($0) }), in: 0...1)
                        .controlSize(.small)
                        .accessibilityLabel("Night Shift warmth")
                    Text("More")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Button(display.nightShiftOn ? "On Until Tomorrow" : "Turn On Until Tomorrow") {
                display.turnOnNightShiftUntilTomorrow()
            }
            .controlSize(.small)
            .disabled(display.nightShiftOn)
        }
    }
}

/// One of the module's round switches: a disc that is filled while the thing is on, and its
/// name under it.
private struct ModuleSwitch: View {
    let title: String
    let symbol: String
    let isOn: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(isOn ? Color.accentColor : Color.primary.opacity(0.1))
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .frame(width: 34, height: 34)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(minWidth: 74)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Catches a right-click (or a Control-click) on the view it is laid over and lets every other
/// click through to what is underneath. SwiftUI has a context menu for a right-click and nothing
/// else, and a menu cannot hold a slider.
struct SecondaryClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        /// Only the click it is for lands here; the window asks this for every other one too,
        /// and nil sends it on to the control underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isSecondary(event) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        override func mouseDown(with event: NSEvent) {
            if Self.isSecondary(event) { action?() } else { super.mouseDown(with: event) }
        }

        private static func isSecondary(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }
    }
}
