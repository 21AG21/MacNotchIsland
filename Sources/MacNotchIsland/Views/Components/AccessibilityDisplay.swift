import AppKit
import Combine
import SwiftUI

/// The three settings under Accessibility › Display that the island draws differently for:
/// Increase Contrast, Differentiate Without Color and Reduce Motion.
///
/// Read once, kept current on the workspace's notification, and published, so that a view which
/// draws by one of them is drawn again the moment it changes. Reduce Motion used to be held in a
/// plain variable that nothing announced: a title went on scrolling, and a timer's digits went on
/// rolling, after the switch was turned on, until something unrelated happened to redraw them.
/// This is the one place the island reads the three from. `IslandMotion.reduceMotion` is this
/// object's answer, and `EnergyPolicy` passes a change of it on to what follows the policy.
///
/// Main thread only: the notification is heard on the main queue, and that is the only place a
/// value here is ever written.
final class AccessibilityDisplay: ObservableObject {
    static let shared = AccessibilityDisplay()

    /// The three settings at one moment. A struct, so a reading can be compared and handed in.
    struct Options: Equatable {
        var increaseContrast = false
        var differentiateWithoutColor = false
        var reduceMotion = false

        /// What the system says now.
        static var system: Options {
            let workspace = NSWorkspace.shared
            return Options(increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                           differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
                           reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
        }
    }

    @Published private(set) var increaseContrast: Bool
    @Published private(set) var differentiateWithoutColor: Bool
    @Published private(set) var reduceMotion: Bool

    private var observer: NSObjectProtocol?

    /// The shared one: what the system says, and every change after it.
    private convenience init() {
        self.init(options: .system)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.apply(.system)
        }
    }

    /// One that holds `options` and hears nothing from the system, so a test can hand it
    /// readings of its own without touching the Mac's settings or the shared answer.
    init(options: Options) {
        increaseContrast = options.increaseContrast
        differentiateWithoutColor = options.differentiateWithoutColor
        reduceMotion = options.reduceMotion
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Takes a new reading, and publishes only what changed in it. The notification comes for
    /// every display option, Reduce Transparency and Invert Colours among them, and each
    /// publish here redraws every view that follows this object.
    func apply(_ options: Options) {
        if options.increaseContrast != increaseContrast { increaseContrast = options.increaseContrast }
        if options.differentiateWithoutColor != differentiateWithoutColor {
            differentiateWithoutColor = options.differentiateWithoutColor
        }
        if options.reduceMotion != reduceMotion { reduceMotion = options.reduceMotion }
    }
}

// MARK: - Increase Contrast

/// How strongly the island's quiet text is drawn.
///
/// Secondary lines are white at a fraction of full strength — a caption at 0.4, a time at 0.45,
/// an artist at 0.55 — which on black is a grey that the eye reads as less important. Under
/// Increase Contrast that grey is what the user has asked not to be given, so nothing is drawn
/// fainter than `floor` while it is on. Everything already stronger is left alone, and with the
/// setting off every figure is exactly what it was.
enum IslandContrast {
    /// The least a line of text is drawn at while Increase Contrast is on.
    static let floor: Double = 0.6

    /// `normal`, or `floor` if that is more, while contrast is increased. The setting is handed
    /// in so both halves can be tested; left out, it is the system's.
    static func alpha(_ normal: Double, increased: Bool = AccessibilityDisplay.shared.increaseContrast) -> Double {
        increased ? max(normal, floor) : normal
    }
}

/// White at a quiet strength, raised under Increase Contrast. A modifier rather than a colour so
/// that it watches the setting itself: a change reaches every line drawn this way, without each
/// view around one having to watch for it too.
private struct QuietWhite: ViewModifier {
    let opacity: Double
    @ObservedObject private var display = AccessibilityDisplay.shared

    func body(content: Content) -> some View {
        content.foregroundStyle(Color.white.opacity(IslandContrast.alpha(opacity, increased: display.increaseContrast)))
    }
}

extension View {
    /// `.foregroundStyle(.white.opacity(opacity))`, drawn no fainter than `IslandContrast.floor`
    /// while Increase Contrast is on.
    func quietWhite(_ opacity: Double) -> some View {
        modifier(QuietWhite(opacity: opacity))
    }
}

// MARK: - Differentiate Without Color

/// The marks that stand beside a colour for anyone who has asked not to be told things by
/// colour alone. Each is drawn only while Differentiate Without Color is on, so the island looks
/// exactly as it always has to everybody else. Pure, so the rules are tested.
enum IslandMarks {
    /// Whether a stopwatch carries a pause glyph beside it: stopped, where orange against grey
    /// was the only difference between running and not.
    static func pause(running: Bool, differentiate: Bool) -> Bool {
        differentiate && !running
    }

    /// Whether a battery reading carries a warning mark beside it: low, where red was the only
    /// thing that said so.
    static func warning(low: Bool, differentiate: Bool) -> Bool {
        differentiate && low
    }
}
