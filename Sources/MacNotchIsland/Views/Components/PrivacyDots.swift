import SwiftUI

/// The orange (microphone) and green (camera) privacy indicators the iPhone shows inside the island.
///
/// Told apart by colour and by nothing else, so under Differentiate Without Color each dot is
/// drawn as its own glyph instead, in the same colour: a microphone and a camera. Everyone else
/// sees the dots exactly as they were.
struct PrivacyDots: View {
    @EnvironmentObject private var center: ActivityCenter
    @ObservedObject private var display = AccessibilityDisplay.shared

    var body: some View {
        HStack(spacing: display.differentiateWithoutColor ? 3 : 4) {
            if center.micInUse {
                dot(.microphone)
            }
            if center.cameraInUse {
                dot(.camera)
            }
        }
        .animation(IslandMotion.content, value: center.micInUse)
        .animation(IslandMotion.content, value: center.cameraInUse)
    }

    /// What a dot stands for.
    enum Kind {
        case microphone
        case camera

        var color: Color { Color.named(self == .microphone ? "orange" : "green") }

        /// "Microphone in use", "Camera in use".
        var label: String {
            self == .microphone ? IslandAccessibility.microphoneLabel : IslandAccessibility.cameraLabel
        }
    }

    /// The glyph a dot is drawn as, or nil for the plain dot: only under Differentiate Without
    /// Color. Pure, so the rule is tested.
    static func symbol(for kind: Kind, differentiate: Bool) -> String? {
        guard differentiate else { return nil }
        return kind == .microphone ? "mic.fill" : "video.fill"
    }

    @ViewBuilder
    private func dot(_ kind: Kind) -> some View {
        Group {
            if let symbol = Self.symbol(for: kind, differentiate: display.differentiateWithoutColor) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kind.color)
                    .fixedSize()
            } else {
                Circle().fill(kind.color).frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.label)
    }
}
