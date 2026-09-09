import CoreGraphics
import Foundation

// Prints the window number of a process's largest on-screen window, so the smoke test can
// photograph that window and nothing else: `screencapture -l` takes a window by number, and a
// picture of the window is a fraction of the size of a picture of the screen it is on. The
// job log the pictures come back through is finite and the island's own gallery is in it.
//
// Matched by process id, not by owner name. A window's owner name is one of the things macOS
// withholds from a process without Screen Recording, and this is a bare binary compiled by the
// test with no permissions of its own — asking for the name got an empty answer every time and
// photographed nothing. The test launched the app; it knows the pid.
//
//   windowid <pid> [minimum height]
guard let pid = CommandLine.arguments.dropFirst().first.flatMap({ Int($0) }) else { exit(2) }
let minimumHeight = CommandLine.arguments.dropFirst(2).first.flatMap { Double($0) } ?? 100

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (number: Int, area: Double)?
for window in list {
    guard window[kCGWindowOwnerPID as String] as? Int == pid,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
          height >= minimumHeight,
          let number = window[kCGWindowNumber as String] as? Int else { continue }
    let area = width * height
    if best == nil || area > best!.area { best = (number, area) }
}
guard let best else { exit(1) }
print(best.number)
