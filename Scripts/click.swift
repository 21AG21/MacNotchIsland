import ApplicationServices
import CoreGraphics
import Foundation

// Posts one left click at a point on the main display (top-left origin), the way a trackpad
// would. Usage: click [x|mid] [y]. Used by Scripts/smoke.sh on CI.
let args = CommandLine.arguments
let bounds = CGDisplayBounds(CGMainDisplayID())
// "mid", "mid+120" and "mid-40" are relative to the middle of the display; anything else is
// an absolute x. The island is centred, so its parts are easiest to name from the middle.
func resolveX(_ argument: String?) -> CGFloat {
    guard let argument else { return bounds.midX }
    if argument.hasPrefix("mid") {
        let offset = Double(argument.dropFirst(3)) ?? 0
        return bounds.midX + CGFloat(offset)
    }
    return CGFloat(Double(argument) ?? Double(bounds.midX))
}

let x: CGFloat = resolveX(args.count > 1 ? args[1] : nil)
let y: CGFloat = args.count > 2 ? CGFloat(Double(args[2]) ?? 21) : 21
let point = CGPoint(x: x, y: y)
print("display \(Int(bounds.width))x\(Int(bounds.height)) trusted \(AXIsProcessTrusted()) click at \(Int(point.x)),\(Int(point.y))")

func post(_ type: CGEventType) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
        print("could not make a \(type.rawValue) event"); return
    }
    event.post(tap: .cghidEventTap)
}
CGWarpMouseCursorPosition(point)
post(.mouseMoved)
usleep(250_000)
post(.leftMouseDown)
usleep(90_000)
post(.leftMouseUp)
