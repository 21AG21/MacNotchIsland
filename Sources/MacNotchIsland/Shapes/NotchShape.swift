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

    /// Apple's smoothing in the units the construction below works in: a corner reaches
    /// `1 + smoothing` radii along each edge, so this is `reach - 1`. Zero is a plain
    /// circular arc.
    static let fullSmoothing: CGFloat = reach - 1

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
    /// symmetric about the diagonal, both of which `NotchShapeTests` pins down. `profile`
    /// reproduces these ten points at `fullSmoothing` to a billionth.
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

    /// The corner at any smoothing from a circular arc (0) up to Apple's (`fullSmoothing`), as
    /// the same ten points `unit` is made of, normalised to reach 1 along each edge.
    ///
    /// This is the construction `unit` was derived from, run for any smoothing: the arc in the
    /// middle spans `90° * (1 - smoothing)` of the circle of radius `1 / (1 + smoothing)`, and
    /// the two cubics either side of it take the curvature down to nothing at the straight edge
    /// over the rest of the reach. At zero the outer cubics have no length and the arc is the
    /// whole quarter circle; at Apple's figure it is `unit`. In between it is what Apple's own
    /// corners become when they run out of room — see `fit`.
    static func profile(smoothing raw: CGFloat) -> [CGPoint] {
        let s = max(0, min(raw, fullSmoothing))
        let r = 1 / (1 + s)
        let arc = (CGFloat.pi / 2) * (1 - s)
        // The arc's chord is symmetric about the diagonal, so this is its projection on each edge.
        let arcSection = sin(arc / 2) * r * 2.squareRoot()
        let alpha = (CGFloat.pi / 2 - arc) / 2
        let handle = r * tan(alpha / 2)
        let beta = (CGFloat.pi / 4) * s
        let c = handle * cos(beta)
        let d = c * tan(beta)
        let b = (1 - arcSection - c - d) / 3
        let a = 2 * b
        let p3 = CGPoint(x: 1 - a - b - c, y: d)
        // The arc from p3 to its mirror, as one cubic: the handles run along the tangents.
        let phi = atan2(p3.y - r, p3.x - r)
        let k = (4 / 3) * tan(arc / 4) * r
        let p4 = CGPoint(x: p3.x + k * sin(phi), y: p3.y - k * cos(phi))
        return [
            CGPoint(x: 1, y: 0), CGPoint(x: 1 - a, y: 0), CGPoint(x: 1 - a - b, y: 0), p3,
            p4, CGPoint(x: p4.y, y: p4.x), CGPoint(x: p3.y, y: p3.x),
            CGPoint(x: 0, y: 1 - a - b), CGPoint(x: 0, y: 1 - a), CGPoint(x: 0, y: 1),
        ]
    }

    /// How far the corner for `radius` may reach along each of its edges: the ideal
    /// `reach * radius`, clamped to half of the edge it runs along and half of the edge it turns
    /// on to, so two corners sharing an edge can never overrun each other.
    static func span(radius: CGFloat, along: CGFloat, across: CGFloat) -> CGFloat {
        guard radius > 0, along > 0, across > 0 else { return 0 }
        return min(radius * reach, along / 2, across / 2)
    }

    /// The span a corner of `radius` gets, and how much smoothing fits in it.
    ///
    /// A corner with room for its whole reach gets Apple's profile. One with less room used
    /// to get that same profile scaled down to fit, which is a corner of a *smaller* radius
    /// than the one asked for: the compact pill, whose 16 pt ends have exactly 16 pt of room,
    /// came out as a squeezed squircle of radius 10 with a dent where the semicircle should
    /// be — so the pill was drawn as a special case, and the island jumped between the two
    /// families on the first frame of every morph. Apple's continuous corners give up their
    /// smoothing instead as the room runs out, until at exactly one radius of room they are
    /// the circle; so do these, and one rule draws every frame between the pill and the panel.
    static func fit(radius: CGFloat, along: CGFloat, across: CGFloat) -> (span: CGFloat, smoothing: CGFloat) {
        let span = self.span(radius: radius, along: along, across: across)
        guard span > 0 else { return (0, 0) }
        return (span, max(0, min(fullSmoothing, span / radius - 1)))
    }

    /// The ten control points of a corner at `vertex` that starts `span` away along `entry` and
    /// finishes `span` away along `exit`. `entry` and `exit` are unit vectors pointing from the
    /// vertex out along the two edges the corner joins, in the order the path travels them.
    static func points(vertex: CGPoint, entry: CGVector, exit: CGVector, span: CGFloat,
                       smoothing: CGFloat = fullSmoothing) -> [CGPoint] {
        let base = smoothing >= fullSmoothing ? unit : profile(smoothing: smoothing)
        return base.map { u in
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
/// curvature, or as much of it as the height leaves room for — a compact pill's are the
/// semicircles of a capsule, by the same rule (`SmoothCorner.fit`). The rect passed in includes
/// the outward "ears": the visible body spans `rect.minX + topRadius ... rect.maxX - topRadius`.
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

    func path(in rect: CGRect) -> Path {
        if floating { return floatingPath(in: rect) }
        let t = max(0, min(topRadius, rect.height / 2, rect.width / 2))
        let leftX = rect.minX + t
        let rightX = rect.maxX - t
        let bodyWidth = max(0, rightX - leftX)
        let b = max(0, min(bottomRadius, bodyWidth / 2, rect.height - t, rect.height / 2))
        let corner = SmoothCorner.fit(radius: b, along: bodyWidth, across: rect.height)
        let span = corner.span

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
            p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: leftX, y: rect.maxY),
                                                  entry: CGVector(dx: 0, dy: -1),
                                                  exit: CGVector(dx: 1, dy: 0),
                                                  span: span, smoothing: corner.smoothing))
        }
        p.addLine(to: CGPoint(x: rightX - span, y: rect.maxY))
        if span > 0 {
            p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rightX, y: rect.maxY),
                                                  entry: CGVector(dx: -1, dy: 0),
                                                  exit: CGVector(dx: 0, dy: -1),
                                                  span: span, smoothing: corner.smoothing))
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
        let corner = SmoothCorner.fit(radius: r, along: rect.height, across: rect.width)
        let span = corner.span
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
                                              span: span, smoothing: corner.smoothing))
        p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rect.maxX, y: rect.maxY),
                                              entry: CGVector(dx: -1, dy: 0),
                                              exit: CGVector(dx: 0, dy: -1),
                                              span: span, smoothing: corner.smoothing))
        p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rect.maxX, y: rect.minY),
                                              entry: CGVector(dx: 0, dy: 1),
                                              exit: CGVector(dx: -1, dy: 0),
                                              span: span, smoothing: corner.smoothing))
        p.addSmoothCorner(SmoothCorner.points(vertex: CGPoint(x: rect.minX, y: rect.minY),
                                              entry: CGVector(dx: 1, dy: 0),
                                              exit: CGVector(dx: 0, dy: 1),
                                              span: span, smoothing: corner.smoothing))
        p.closeSubpath()
        return p
    }
}
