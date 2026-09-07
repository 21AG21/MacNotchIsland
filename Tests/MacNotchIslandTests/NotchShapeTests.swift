import XCTest
import SwiftUI
@testable import MacNotchIsland

/// Geometry checks for the island outline and for the continuous ("squircle") corner it is
/// built from. Everything here is pure maths — no view, no screen.
final class NotchShapeTests: XCTestCase {

    /// Shapes the app actually asks for, plus a few degenerate ones.
    private struct Case {
        let name: String
        let size: CGSize
        let top: CGFloat
        let bottom: CGFloat
    }

    private let cases: [Case] = [
        Case(name: "compact capsule", size: CGSize(width: 300, height: 32), top: 8, bottom: 16),
        Case(name: "idle", size: CGSize(width: 212, height: 32), top: 6, bottom: 10),
        Case(name: "expanded", size: CGSize(width: 300, height: 120), top: 20, bottom: 30),
        Case(name: "home", size: CGSize(width: 580, height: 182), top: 20, bottom: 30),
        Case(name: "radii larger than the body", size: CGSize(width: 60, height: 40), top: 20, bottom: 20),
        Case(name: "no radii", size: CGSize(width: 120, height: 40), top: 0, bottom: 0),
        Case(name: "tall", size: CGSize(width: 100, height: 300), top: 12, bottom: 24),
    ]

    private func length(_ dx: CGFloat, _ dy: CGFloat) -> CGFloat { (dx * dx + dy * dy).squareRoot() }

    private func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let s = 1 - t
        return CGPoint(x: s * s * s * p0.x + 3 * s * s * t * p1.x + 3 * s * t * t * p2.x + t * t * t * p3.x,
                       y: s * s * s * p0.y + 3 * s * s * t * p1.y + 3 * s * t * t * p2.y + t * t * t * p3.y)
    }

    // MARK: - the corner primitive

    func testUnitCornerIsNormalisedAndSymmetricAboutItsDiagonal() {
        let u = SmoothCorner.unit
        XCTAssertEqual(u.count, 10, "a start point plus three cubic (c1, c2, end) triples")
        XCTAssertEqual(u[0].x, 1, accuracy: 1e-9)
        XCTAssertEqual(u[0].y, 0, accuracy: 1e-9)
        XCTAssertEqual(u[9].x, 0, accuracy: 1e-9)
        XCTAssertEqual(u[9].y, 1, accuracy: 1e-9)
        for p in u {
            XCTAssertTrue(p.x >= -1e-9 && p.x <= 1 + 1e-9, "\(p) escapes the corner box")
            XCTAssertTrue(p.y >= -1e-9 && p.y <= 1 + 1e-9, "\(p) escapes the corner box")
        }
        for i in 0..<u.count {
            XCTAssertEqual(u[i].x, u[u.count - 1 - i].y, accuracy: 1e-9, "mirror about the diagonal")
            XCTAssertEqual(u[i].y, u[u.count - 1 - i].x, accuracy: 1e-9, "mirror about the diagonal")
        }
        for i in 0..<(u.count - 1) {
            XCTAssertLessThanOrEqual(u[i + 1].x, u[i].x + 1e-9, "the corner never doubles back")
            XCTAssertGreaterThanOrEqual(u[i + 1].y, u[i].y - 1e-9, "the corner never doubles back")
        }
    }

    func testUnitCornerLeavesTheStraightEdgesFlat() {
        let u = SmoothCorner.unit
        // Both control points of the first cubic sit on the edge itself, so the curve starts with
        // zero curvature instead of jumping straight to 1/r the way a circular arc does. That, and
        // the extra reach it buys, is the whole difference between continuous and circular corners.
        XCTAssertEqual(u[1].y, 0, accuracy: 1e-12)
        XCTAssertEqual(u[2].y, 0, accuracy: 1e-12)
        XCTAssertEqual(u[7].x, 0, accuracy: 1e-12)
        XCTAssertEqual(u[8].x, 0, accuracy: 1e-12)
        XCTAssertEqual(SmoothCorner.reach, 1.528665, accuracy: 1e-9, "Apple's continuous-corner reach")
    }

    func testUnitCornerHasNoKinksAtItsJoins() {
        let u = SmoothCorner.unit
        for join in [3, 6] {
            let incoming = CGPoint(x: u[join].x - u[join - 1].x, y: u[join].y - u[join - 1].y)
            let outgoing = CGPoint(x: u[join + 1].x - u[join].x, y: u[join + 1].y - u[join].y)
            let scale = length(incoming.x, incoming.y) * length(outgoing.x, outgoing.y)
            XCTAssertGreaterThan(scale, 0)
            let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
            XCTAssertEqual(cross / scale, 0, accuracy: 1e-6, "tangent breaks at join \(join)")
        }
    }

    func testMiddleCubicRidesTheCircleTheCornerIsNamedFor() {
        let u = SmoothCorner.unit
        // In these normalised units the corner's radius is 1 / reach and its circle is centred on
        // the diagonal at (r, r) — the same circle a plain rounded corner of that radius uses.
        let r = 1 / SmoothCorner.reach
        for step in 0...20 {
            let p = cubic(u[3], u[4], u[5], u[6], CGFloat(step) / 20)
            XCTAssertEqual(length(p.x - r, p.y - r), r, accuracy: 1e-4, "middle cubic drifts off the circle")
        }
    }

    func testSpanIsTheReachClampedToHalfOfEachEdge() {
        XCTAssertEqual(SmoothCorner.span(radius: 30, along: 260, across: 120),
                       30 * SmoothCorner.reach, accuracy: 1e-6, "nothing to clamp against")
        XCTAssertEqual(SmoothCorner.span(radius: 30, along: 40, across: 120), 20, accuracy: 1e-9,
                       "half the edge the corner runs along")
        XCTAssertEqual(SmoothCorner.span(radius: 30, along: 260, across: 50), 25, accuracy: 1e-9,
                       "half the edge the corner turns on to")
        XCTAssertEqual(SmoothCorner.span(radius: 0, along: 100, across: 100), 0)
        XCTAssertEqual(SmoothCorner.span(radius: -5, along: 100, across: 100), 0)
        XCTAssertEqual(SmoothCorner.span(radius: 10, along: 0, across: 100), 0)
    }

    func testPlacedCornerStartsAndEndsOnItsTwoEdges() {
        let points = SmoothCorner.points(vertex: CGPoint(x: 100, y: 50),
                                         entry: CGVector(dx: 0, dy: -1),
                                         exit: CGVector(dx: 1, dy: 0),
                                         span: 20)
        XCTAssertEqual(points.count, 10)
        XCTAssertEqual(points[0].x, 100, accuracy: 1e-9)
        XCTAssertEqual(points[0].y, 30, accuracy: 1e-9)
        XCTAssertEqual(points[9].x, 120, accuracy: 1e-9)
        XCTAssertEqual(points[9].y, 50, accuracy: 1e-9)
        for p in points {
            XCTAssertTrue(p.x >= 100 - 1e-9 && p.x <= 120 + 1e-9, "\(p) escapes the corner box")
            XCTAssertTrue(p.y >= 30 - 1e-9 && p.y <= 50 + 1e-9, "\(p) escapes the corner box")
        }
    }

    func testCapsuleBottomIsDetectedOnlyForSemicircularEnds() {
        XCTAssertTrue(NotchShape.hasCapsuleBottom(height: 32, bottomRadius: 16))
        XCTAssertTrue(NotchShape.hasCapsuleBottom(height: 32, bottomRadius: 24))
        XCTAssertFalse(NotchShape.hasCapsuleBottom(height: 32, bottomRadius: 10))
        XCTAssertFalse(NotchShape.hasCapsuleBottom(height: 120, bottomRadius: 30))
        XCTAssertFalse(NotchShape.hasCapsuleBottom(height: 0, bottomRadius: 0))
    }

    // MARK: - the outline

    func testBoundingBoxIsExactlyTheRect() {
        var checks: [(name: String, rect: CGRect, top: CGFloat, bottom: CGFloat)] = []
        for c in cases {
            checks.append((c.name, CGRect(origin: .zero, size: c.size), c.top, c.bottom))
        }
        checks.append(("offset expanded", CGRect(x: 12, y: -8, width: 300, height: 120), 20, 30))
        checks.append(("fractional idle", CGRect(x: -5.5, y: 3.25, width: 212, height: 32), 6, 10))
        for check in checks {
            let bounds = NotchShape(topRadius: check.top, bottomRadius: check.bottom)
                .path(in: check.rect).boundingRect
            XCTAssertEqual(bounds.minX, check.rect.minX, accuracy: 0.01, check.name)
            XCTAssertEqual(bounds.maxX, check.rect.maxX, accuracy: 0.01, check.name)
            XCTAssertEqual(bounds.minY, check.rect.minY, accuracy: 0.01, check.name)
            XCTAssertEqual(bounds.maxY, check.rect.maxY, accuracy: 0.01, check.name)
        }
    }

    func testOutlineIsMirrorSymmetric() {
        for c in cases {
            let rect = CGRect(origin: .zero, size: c.size)
            let path = NotchShape(topRadius: c.top, bottomRadius: c.bottom).path(in: rect)
            // Deliberately off-grid so no sample lands exactly on an edge, where `contains` is
            // free to answer either way.
            var x: CGFloat = 2.35
            while x < c.size.width - 1 {
                var y: CGFloat = 1.1
                while y < c.size.height - 1 {
                    XCTAssertEqual(path.contains(CGPoint(x: x, y: y)),
                                   path.contains(CGPoint(x: c.size.width - x, y: y)),
                                   "\(c.name): (\(x), \(y)) and its mirror disagree")
                    y += 3.7
                }
                x += 7.1
            }
        }
    }

    func testCompactPillStaysATrueCapsule() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 32)
        let path = NotchShape(topRadius: 8, bottomRadius: 16).path(in: rect)
        XCTAssertTrue(path.contains(CGPoint(x: 8 + 16, y: 16)), "centre of the left semicircular end")
        XCTAssertTrue(path.contains(CGPoint(x: 300 - 8 - 16, y: 16)), "centre of the right end")
        XCTAssertFalse(path.contains(CGPoint(x: 8 + 1, y: 31)), "the end's bounding-box corner is empty")
        // 45° round the end: a smoothed corner would bulge past this, a semicircle does not.
        XCTAssertFalse(path.contains(CGPoint(x: 11.89, y: 28.11)), "the end is a circle, not a squircle")
        XCTAssertTrue(path.contains(CGPoint(x: 13, y: 27)), "just inside that same circle")
    }

    func testExpandedBottomCornersAreContinuous() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        let path = NotchShape(topRadius: 20, bottomRadius: 30).path(in: rect)
        XCTAssertFalse(path.contains(CGPoint(x: 22, y: 118)), "the corner cuts the bounding-box corner away")
        XCTAssertFalse(path.contains(CGPoint(x: 278, y: 118)), "and the same on the right")
        XCTAssertTrue(path.contains(CGPoint(x: 150, y: 118)), "2pt inset at the middle of the bottom edge")
        XCTAssertTrue(path.contains(CGPoint(x: 150, y: 60)), "the middle of the body")
        // The continuous corner peels off the side well before a circular arc of the same radius
        // would: that one only starts at y = 90, so it would still cover this point.
        XCTAssertFalse(path.contains(CGPoint(x: 20.5, y: 95)), "corner leaves the edge early")
    }

    func testEarsFlareOutToTheScreenEdge() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        let path = NotchShape(topRadius: 20, bottomRadius: 30).path(in: rect)
        XCTAssertTrue(path.contains(CGPoint(x: 150, y: 0.5)), "the top edge spans the whole rect")
        XCTAssertTrue(path.contains(CGPoint(x: 25, y: 5)), "just inside the body edge")
        XCTAssertFalse(path.contains(CGPoint(x: 10, y: 6)), "the ear leaves the space below it empty")
        XCTAssertFalse(path.contains(CGPoint(x: 19, y: 15)), "and stays empty down to the body edge")
    }

    func testAnimatableDataRoundTripsTheRadii() {
        var shape = NotchShape(topRadius: 8, bottomRadius: 16)
        shape.animatableData = AnimatablePair<CGFloat, CGFloat>(20, 30)
        XCTAssertEqual(shape.topRadius, 20)
        XCTAssertEqual(shape.bottomRadius, 30)
        XCTAssertEqual(shape.animatableData.first, 20)
        XCTAssertEqual(shape.animatableData.second, 30)
    }

    // MARK: - the floating pill (screens with no notch)

    /// The idle pill on an external display: 120 x 30, rounded on every corner.
    private var floatingIdleRect: CGRect { CGRect(x: 0, y: 0, width: 120, height: 30) }

    func testFloatingPillFillsItsRectAndCutsAllFourCorners() {
        let rect = floatingIdleRect
        let path = NotchShape(topRadius: 15, bottomRadius: 15, floating: true).path(in: rect)
        let bounds = path.boundingRect
        XCTAssertEqual(bounds.minX, rect.minX, accuracy: 0.01, "no ears: the shape is exactly its rect")
        XCTAssertEqual(bounds.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, rect.minY, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, rect.maxY, accuracy: 0.01)
        // Every corner of the bounding box is cut away — the top two as well, which is what
        // separates the free-floating pill from the notch outline and its outward ears.
        XCTAssertFalse(path.contains(CGPoint(x: 2, y: 2)), "top-left corner")
        XCTAssertFalse(path.contains(CGPoint(x: rect.width - 2, y: 2)), "top-right corner")
        XCTAssertFalse(path.contains(CGPoint(x: 2, y: rect.height - 2)), "bottom-left corner")
        XCTAssertFalse(path.contains(CGPoint(x: rect.width - 2, y: rect.height - 2)), "bottom-right corner")
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 15)), "the middle of the pill")
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 0.5)), "the top edge is straight between the corners")
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 29.5)), "and so is the bottom edge")
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: 15)), "the corners meet at the middle of each end")
        XCTAssertTrue(path.contains(CGPoint(x: 6, y: 6)), "just inside the top-left corner")
    }

    func testFloatingPillIsSymmetricAboutBothAxes() {
        let rect = floatingIdleRect
        let path = NotchShape(topRadius: 15, bottomRadius: 15, floating: true).path(in: rect)
        var x: CGFloat = 2.35
        while x < rect.width - 1 {
            var y: CGFloat = 1.1
            while y < rect.height - 1 {
                let here = path.contains(CGPoint(x: x, y: y))
                XCTAssertEqual(here, path.contains(CGPoint(x: rect.width - x, y: y)),
                               "(\(x), \(y)) and its left/right mirror disagree")
                XCTAssertEqual(here, path.contains(CGPoint(x: x, y: rect.height - y)),
                               "(\(x), \(y)) and its top/bottom mirror disagree")
                y += 3.7
            }
            x += 7.1
        }
    }

    func testFloatingCornersAllUseTheBottomRadius() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        // `topRadius` is what the ears are cut from, and a floating pill has none: the outline is
        // the same whatever it says.
        let wide = NotchShape(topRadius: 6, bottomRadius: 30, floating: true).path(in: rect)
        let same = NotchShape(topRadius: 30, bottomRadius: 30, floating: true).path(in: rect)
        for point in [CGPoint(x: 22, y: 2), CGPoint(x: 2, y: 22), CGPoint(x: 60, y: 1), CGPoint(x: 150, y: 60)] {
            XCTAssertEqual(wide.contains(point), same.contains(point), "\(point) depends on topRadius")
        }
        XCTAssertFalse(wide.contains(CGPoint(x: 3, y: 3)), "a 30pt corner is cut back well past here")
        XCTAssertTrue(wide.contains(CGPoint(x: 150, y: 1)), "but the top edge itself is straight")
        // A continuous corner leaves the edge early, exactly as the bottom corners do.
        XCTAssertFalse(wide.contains(CGPoint(x: 1, y: 15)), "corner leaves the side early")
        XCTAssertTrue(wide.contains(CGPoint(x: 1, y: 60)), "and the side is straight below it")
    }

    func testFloatingPillWithoutRadiusIsThePlainRect() {
        let rect = floatingIdleRect
        let path = NotchShape(topRadius: 0, bottomRadius: 0, floating: true).path(in: rect)
        XCTAssertEqual(path.boundingRect.width, rect.width, accuracy: 0.01)
        XCTAssertEqual(path.boundingRect.height, rect.height, accuracy: 0.01)
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: 1)), "nothing to round off")
    }

    func testFloatingIsNotAnimated() {
        var shape = NotchShape(topRadius: 15, bottomRadius: 15, floating: true)
        shape.animatableData = AnimatablePair<CGFloat, CGFloat>(20, 30)
        XCTAssertTrue(shape.floating, "floating is a property of the screen, not of the animation")
        XCTAssertFalse(NotchShape(topRadius: 8, bottomRadius: 16).floating, "notched screens are the default")
    }
}
