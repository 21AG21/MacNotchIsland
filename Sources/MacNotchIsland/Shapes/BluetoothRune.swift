import SwiftUI

/// The Bluetooth rune, drawn rather than named: there is no SF Symbol for it.
///
/// One stroke, the way the mark is built — the vertical stem with a triangle above and below,
/// each drawn from the far corner through the centre. Stroke it; it has no inside.
struct BluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        let x = { (fraction: CGFloat) in rect.minX + rect.width * fraction }
        let y = { (fraction: CGFloat) in rect.minY + rect.height * fraction }
        var path = Path()
        path.move(to: CGPoint(x: x(0), y: y(0.7)))
        path.addLine(to: CGPoint(x: x(1), y: y(0.3)))
        path.addLine(to: CGPoint(x: x(0.5), y: y(0)))
        path.addLine(to: CGPoint(x: x(0.5), y: y(1)))
        path.addLine(to: CGPoint(x: x(1), y: y(0.7)))
        path.addLine(to: CGPoint(x: x(0), y: y(0.3)))
        return path
    }
}
