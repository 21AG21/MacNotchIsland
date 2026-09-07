import SwiftUI

/// The island outline. The top corners curve *outward* so the black blends into the screen
/// edge exactly like the physical notch; the bottom corners are conventional rounded corners.
/// The rect passed in includes the outward "ears": the visible body spans
/// `rect.minX + topRadius ... rect.maxX - topRadius`.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.height / 2)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        if b > 0 {
            p.addArc(tangent1End: CGPoint(x: rect.minX + t, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.minX + t + b, y: rect.maxY), radius: b)
        }
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        if b > 0 {
            p.addArc(tangent1End: CGPoint(x: rect.maxX - t, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.maxX - t, y: rect.maxY - b), radius: b)
        }
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
