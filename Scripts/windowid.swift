import CoreGraphics
import Foundation

// Prints the window number of an app's largest on-screen window, so the smoke test can
// photograph that window and nothing else: `screencapture -l` takes a window by number, and
// a picture of the window is a fraction of the size of a picture of the screen it is on.
// The job log the pictures come back through is finite and the island's own gallery is in it.
//
// Owner name and bounds come out of the window list without Screen Recording; only the
// picture itself needs it, which is `screencapture`'s problem and not this one.
let owner = CommandLine.arguments.dropFirst().first ?? "MacNotchIsland"
let minimumHeight = Double(CommandLine.arguments.dropFirst(2).first.flatMap { Double($0) } ?? 100)

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (number: Int, area: Double)?
for window in list {
    guard window[kCGWindowOwnerName as String] as? String == owner,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
          height >= minimumHeight,
          let number = window[kCGWindowNumber as String] as? Int else { continue }
    let area = width * height
    if best == nil || area > best!.area { best = (number, area) }
}
guard let best else { exit(1) }
print(best.number)
