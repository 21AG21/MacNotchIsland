import Combine
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac and its display awake while switched on: a power-management assertion,
/// the same thing `caffeinate -d` holds. It ends with the process, so a crash or a quit can
/// never leave the Mac unable to sleep.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isOn = false
    private var assertion: IOPMAssertionID = 0

    private init() {}

    /// How a press ended. The rail's button lights from `isOn` and from nothing else, so an
    /// assertion macOS turns down used to leave the press with no light, no words and no
    /// reason — the same nothing as a button that was never pressed at all. A refusal is one
    /// of the endings, so it is said aloud like the other two.
    enum Outcome: Equatable {
        case on
        case off
        case refused
    }

    func toggle() { set(!isOn) }

    @discardableResult
    func set(_ on: Bool) -> Outcome {
        guard on != isOn else { return isOn ? .on : .off }
        if on {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Notch Island: Keep Awake" as CFString, &id)
            guard result == kIOReturnSuccess else {
                // The number is for whoever reads the log afterwards; the person standing at
                // the Mac gets the sentence instead.
                IslandLog.island.error("Keep Awake assertion failed: \(result, privacy: .public)")
                announce(.refused)
                return .refused
            }
            assertion = id
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        isOn = on
        announce(on ? .on : .off)
        return on ? .on : .off
    }

    /// What the pill shows for each ending, decided apart from the showing so the words a
    /// refusal is given can be read back without a Mac that refuses. An `IOReturn` is not
    /// something anybody can do anything about, and the whole point of saying a refusal is
    /// that it reaches the person who pressed the button.
    static func announcement(for outcome: Outcome) -> CustomActivity {
        switch outcome {
        case .on, .off:
            let on = outcome == .on
            return CustomActivity(title: "Keep Awake", subtitle: on ? "On" : "Off", symbol: "cup.and.saucer.fill",
                                  tint: "white", trailingText: on ? "On" : "Off")
        case .refused:
            return CustomActivity(title: "Keep Awake didn't turn on",
                                  subtitle: "macOS would not hold the Mac awake. Try again in a moment.",
                                  symbol: "exclamationmark.triangle.fill", tint: "orange")
        }
    }

    /// The pill says what just happened, the way it does for Low Power Mode.
    private func announce(_ outcome: Outcome) {
        let custom = Self.announcement(for: outcome)
        guard outcome == .refused else {
            ActivityCenter.shared.showAlert(IslandActivity(id: "keepawake", kind: .custom, content: .custom(custom), priority: 85),
                                            duration: 1.4, haptic: false)
            return
        }
        // A word can go past in a moment because the eye was already on the button. A
        // sentence nobody was expecting cannot, and this one is the only account of the
        // press there will ever be, so it is given the room and the time to be read.
        ActivityCenter.shared.showAlert(IslandActivity(id: "keepawake", kind: .custom, content: .custom(custom),
                                                       priority: 85, presentation: .expanded),
                                        duration: 4)
    }
}
