import AppKit
import SwiftUI

/// Small shared pieces every Settings pane is built from. The panes themselves use stock
/// SwiftUI controls inside a grouped `Form`, so the only things worth sharing are the sidebar
/// icon, the labelled slider row (a slider is useless without its value) and value formatting.

// MARK: - Sidebar icon

/// A System Settings sidebar glyph: a 22-point rounded square in neutral grey with a white
/// symbol on top. Monochrome by design — panes are never colour-coded here.
struct SettingsSidebarIcon: View {
    private let systemName: String

    init(_ systemName: String) {
        self.systemName = systemName
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .systemGray))
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Slider row

/// A form row with a label on the left and a slider plus its current value on the right.
struct SettingsSlider: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let unit: String
    private let zeroLabel: String?

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
         unit: String, zeroLabel: String? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.unit = unit
        self.zeroLabel = zeroLabel
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .frame(minWidth: 130, idealWidth: 170, maxWidth: 200)
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(Text(valueText))
                Text(valueText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .trailing)
            }
        }
    }

    private var valueText: String {
        if value == 0, let zeroLabel { return zeroLabel }
        return SettingsFormat.value(value, unit: unit)
    }
}

// MARK: - Formatting

enum SettingsFormat {
    /// Seconds get two decimals; everything else rounds to whole units.
    static func value(_ value: Double, unit: String) -> String {
        if unit == "s" { return String(format: "%.2f s", value) }
        let rounded = Int(value.rounded())
        return unit.isEmpty ? "\(rounded)" : "\(rounded) \(unit)"
    }

    /// The option a menu should show for a stored value that was set by an older build (or by
    /// hand in defaults) and does not land exactly on one of the offered choices.
    static func nearest(_ value: Double, in options: [Double]) -> Double {
        options.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}

// MARK: - System Settings deep links

/// The System Settings panes Notch Island sends people to when it needs permission.
enum SystemSettingsPane: String {
    case accessibility = "Privacy_Accessibility"
    case camera = "Privacy_Camera"
    case microphone = "Privacy_Microphone"
    case location = "Privacy_LocationServices"
    case calendars = "Privacy_Calendars"
    case reminders = "Privacy_Reminders"
    case automation = "Privacy_Automation"
    case screenRecording = "Privacy_ScreenCapture"

    var url: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" + rawValue)
    }

    /// Opens the pane in System Settings. macOS opens the Privacy & Security root if it no
    /// longer recognises the anchor, so a stale link is never a dead end.
    func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
