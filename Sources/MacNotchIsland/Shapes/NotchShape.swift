import SwiftUI

/// Apple-style *continuous* corner geometry — the "squircle" corner UIKit spells
/// `.continuous` and Figma calls "corner smoothing".
///
/// A circular corner jumps from zero curvature on the straight edge to `1 / r` the instant the
/// arc begins, and the eye reads that discontinuity as a seam. A continuous corner instead
/// leaves the straight edge early — `reach * r` before the corner vertex — and ramps the
/// curvature up to `1 / r` and back down again, so the corner has no seam at either end.
enum SmoothCorner {
    /// How far a continuous corner of radius `r` reaches along each of its two edges.
    /// A circular corner reaches exactly `r`; Apple's continuous corner reaches `1.528665 * r`,
    /// and that extra length is what the curvature ramp is spent on.
    static let reach: CGFloat = 1.528665

    /// The corner as ten control points: a start point followed by three cubic
    /// `(control1, control2, end)` triples, normalised so the corner reaches exactly 1 along each
    /// edge. The vertex sits at the origin with its two edges running along +x and +y, so the
    /// curve starts at `(1, 0)` and finishes at `(0, 1)`.
    ///
    /// Derived from the standard smooth-corner construction (the one Figma's corner smoothing
    /// uses) at the smoothing that produces Apple's `1.528665` reach: the middle cubic is the arc
    /// of the circle of radius `r` centred at `(r, r)` that the corner osculates — within
    /// 3e-6 * r of it — and the outer two ease the curvature from 0 at the straight edge up to
    /// `1 / r` where the arc starts. Every join is tangent-continuous and the whole corner is
    /// symmetric about the diagonal, both of which `NotchShapeTests` pins down.
    static let unit: [CGPoint] = [
        CGPoint(x: 1.000000000, y: 0.000000000),
        CGPoint(x: 0.677580883, y: 0.000000000),
        CGPoint(x: 0.516371325, y: 0.000000000),
        CGPoint(x: 0.390285378, y: 0.055584046),
        CGPoint(x: 0.240850768, y: 0.121461177),
        CGPoint(x: 0.121461177, y: 0.240850768),
        CGPoint(x: 0.055584046, y: 0.390285378),
        CGPoint(x: 0.000000000, y: 0.516371325),
        CGPoint(x: 0.000000000, y: 0.677580883),
        CGPoint(x: 0.000000000, y: 1.000000000),
    ]

    /// How far the corner for `radius` may reach along each of its edges: the ideal
    /// `reach * radius`, clamped to half of the edge it runs along and half of the edge it turns
    /// on to, so two corners sharing an edge can never overrun each other.
    static func span(radius: CGFloat, along: CGFloat, across: CGFloat) -> CGFloat {
        guard radius > 0, along > 0, across > 0 else { return 0 }
        return min(radius * reach, along / 2, across / 2)
    }

    /// The ten control points of a corner at `vertex` that starts `span` away along `entry` and
    /// finishes `span` away along `exit`. `entry` and `exit` are unit vectors pointing from the
    /// vertex out along the two edges the corner joins, in the order the path travels them.
    static func points(vertex: CGPoint, entry: CGVector, exit: CGVector, span: CGFloat) -> [CGPoint] {
        unit.map { u in
            CGPoint(x: vertex.x + span * (u.x * entry.dx + u.y * exit.dx),
                    y: vertex.y + span * (u.x * entry.dy + u.y * exit.dy))
        }
    }
}

private extension Path {
    /// Appends a smooth corner (10 points from `SmoothCorner.points`), joining it to the current
    /// point with a straight edge.
    mutating func addSmoothCorner(_ points: [CGPoint]) {
        guard points.count == 10 else { return }
        addLine(to: points[0])
        addCurve(to: points[3], control1: points[1], control2: points[2])
        addCurve(to: points[6], control1: points[4], control2: points[5])
        addCurve(to: points[9], control1: points[7], control2: points[8])
    }
}

/// The island outline. The top corners curve *outward* so the black blends into the screen
/// edge exactly like the physical notch; the bottom corners are rounded with Apple's continuous
/// curvature rather than plain circular arcs. The rect passed in includes the outward "ears":
/// the visible body spans `rect.minX + topRadius ... rect.maxX - topRadius`.
///
/// On a screen with no notch there is nothing for those ears to blend into, so `floating` swaps
/// the outline for the iPhone's free-floating pill: the whole rect, continuous corners of
/// `bottomRadius` on all four of them.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Whether to draw the free-floating pill instead of the notch outline. A property of the
    /// screen, not of the presentation, so it never changes mid-animation and stays out of
    /// `animatableData`.
    var floating: Bool = false
    /// When set, decides the capsule-vs-continuous-corner branch from the layout's target
    /// state; the animated `bottomRadius` overshoots on the open spring and would flip it mid-flight.
    var isPill: Bool? = nil
    /// Leaves the notch outline open across the top, so a stroke of it draws the three edges
    /// the fused island really has. The closing edge runs along the top of the screen, where
    /// the island's black is continuous with the bezel; a line there is a seam, not an edge.
    /// Filling is unaffected — an open path fills as though closed — and the floating pill,
    /// whose top edge is real, ignores this.
    var openTop: Bool = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    /// True when the bottom corners are semicircles, i.e. the body is a capsule. Those keep true
    /// circular arcs: a continuous corner of radius `height / 2` would have to be squeezed to half
    /// the height and would dent the sides of the pill, and the compact island has to read as a
    /// perfect capsule.
    static func hasCapsuleBottom(height: CGFloat, bottomRadius: CGFloat) -> Bool {
        height > 0 && bottomRadius >= height / 2 - 0.0001
    }

    func path(in rect: CGRect) -> Path {
        if floating { return floatingPath(in: rect) }
        let t = max(0, min(topRadius, rect.height / 2, rect.width / 2))
        let leftX = rect.minX + t
        let rightX = rect.maxX - t
        let bodyWidth = max(0, rightX - leftX)
        let b = max(0, min(bottomRadius, bodyWidth / 2, rect.height - t, rect.height / 2))
        let capsule = isPill ?? NotchShape.hasCapsuleBottom(height: rect.height, bottomRadius: b)
        let span = capsule ? b : SmoothCorner.span(radius: b, along: bodyWidth, across: rect.height)

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top-left ear: leaves the screen edge horizontally and arrives on the body edge
        // vertically, using the same continuous profile as the bottom corners (reach `t`).
        if t > 0 {
            p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: leftX, y: rect.minY),
                                                  entry: CGVector(dx: -1, dy: 0),
                                                  exit: CGVector(dx: 0, dy: 1),
                                                  span: t))
        }
        p.addLine(to: CGPoint(x: leftX, y: rect.maxY - span))
        if span > 0 {
            if capsule {
                p.addArc(tangent1End: CGPoint(x: leftX, y: rect.maxY),
                         tangent2End: CGPoint(x: leftX + span, y: rect.maxY), radius: span)
            } else {
                p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: leftX, y: rect.maxY),
                                                      entry: CGVector(dx: 0, dy: -1),
                                                      exit: CGVector(dx: 1, dy: 0),
                                                      span: span))
            }
        }
        p.addLine(to: CGPoint(x: rightX - span, y: rect.maxY))
        if span > 0 {
            if capsule {
                p.addArc(tangent1End: CGPoint(x: rightX, y: rect.maxY),
                         tangent2End: CGPoint(x: rightX, y: rect.maxY - span), radius: span)
            } else {
                p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rightX, y: rect.maxY),
                                                      entry: CGVector(dx: -1, dy: 0),
                                                      exit: CGVector(dx: 0, dy: -1),
                                                      span: span))
            }
        }
        p.addLine(to: CGPoint(x: rightX, y: rect.minY + t))
        if t > 0 {
            p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rightX, y: rect.minY),
                                                  entry: CGVector(dx: 0, dy: 1),
                                                  exit: CGVector(dx: 1, dy: 0),
                                                  span: t))
        }
        if !openTop { p.closeSubpath() }
        return p
    }

    /// The floating pill: the whole rect with a continuous corner of `bottomRadius` on each of
    /// its four corners, all turning inward. Every corner uses the same span, so the outline is
    /// symmetric about both axes however hard the radius has to be clamped.
    private func floatingPath(in rect: CGRect) -> Path {
        var p = Path()
        let r = max(0, min(bottomRadius, rect.width / 2, rect.height / 2))
        let span = SmoothCorner.span(radius: r, along: rect.height, across: rect.width)
        guard span > 0 else {
            p.addRect(rect)
            return p
        }
        // Down the left edge, along the bottom, up the right edge, back along the top: each
        // `addSmoothCorner` draws the straight edge that leads into its corner.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + span))
        p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rect.minX, y: rect.maxY),
                                              entry: CGVector(dx: 0, dy: -1),
                                              exit: CGVector(dx: 1, dy: 0),
                                              span: span))
        p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rect.maxX, y: rect.maxY),
                                              entry: CGVector(dx: -1, dy: 0),
                                              exit: CGVector(dx: 0, dy: -1),
                                              span: span))
        p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rect.maxX, y: rect.minY),
                                              entry: CGVector(dx: 0, dy: 1),
                                              exit: CGVector(dx: -1, dy: 0),
                                              span: span))
        p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rect.minX, y: rect.minY),
                                              entry: CGVector(dx: 1, dy: 0),
                                              exit: CGVector(dx: 0, dy: 1),
                                              span: span))
        p.closeSubpath()
        return p
    }
}
