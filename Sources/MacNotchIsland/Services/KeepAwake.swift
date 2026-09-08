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

    func toggle() { set(!isOn) }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        if on {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Notch Island: Keep Awake" as CFString, &id)
            guard result == kIOReturnSuccess else {
                IslandLog.island.error("Keep Awake assertion failed: \(result, privacy: .public)")
                return
            }
            assertion = id
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        isOn = on
        announce(on)
    }

    /// The pill says what just happened, the way it does for Low Power Mode.
    private func announce(_ on: Bool) {
        let custom = CustomActivity(title: "Keep Awake", subtitle: on ? "On" : "Off", symbol: "cup.and.saucer.fill",
                                    tint: "white", trailingText: on ? "On" : "Off")
        ActivityCenter.shared.showAlert(IslandActivity(id: "keepawake", kind: .custom, content: .custom(custom), priority: 85),
                                        duration: 1.4, haptic: false)
    }
}
