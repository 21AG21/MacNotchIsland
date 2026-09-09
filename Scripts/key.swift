import CoreGraphics
import Foundation

// Posts one key press to whatever has the keyboard. The smoke test can click, but a click
// cannot press Return on a default button or Escape at an open panel — and Escape closing the
// panel is a path the app registers a global hot key for and that nothing has ever tested.
//
//   key 53   Escape        key 36   Return
let code = CGKeyCode(CommandLine.arguments.dropFirst().first.flatMap { UInt16($0) } ?? 53)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
usleep(40_000)
CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
usleep(150_000)
