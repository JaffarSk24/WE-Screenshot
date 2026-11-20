import XCTest
import WECore
import WEAnnotate

final class RendererTests: XCTestCase {
    func testLine() {
        let a = Annotation(shape: .line(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 90, y: 50)),
                           color: .red, lineWidth: 3)
        let g = render([a])
        XCTAssertTrue(g.isRed(50, 50))
        XCTAssertTrue(g.isWhite(50, 40))
        XCTAssertTrue(g.isWhite(50, 60))
    }

    func testRectangleIsOutlineOnly() {
        let a = Annotation(shape: .rectangle(CGRect(x: 20, y: 20, width: 60, height: 40)), color: .red, lineWidth: 4)
        let g = render([a])
        XCTAssertTrue(g.isRed(50, 20))
        XCTAssertTrue(g.isRed(20, 40))
        XCTAssertTrue(g.isRed(80, 40))
        XCTAssertTrue(g.isRed(50, 60))
        XCTAssertTrue(g.isWhite(50, 40))
        XCTAssertTrue(g.isWhite(50, 10))
    }

    func testArrowHeadAndNoOvershoot() {
        let a = Annotation(shape: .arrow(from: CGPoint(x: 10, y: 50.5), to: CGPoint(x: 80, y: 50.5)),
                           color: .red, lineWidth: 3)
        let g = render([a])
        XCTAssertTrue(g.isRed(40, 50), "shaft")
        XCTAssertTrue(g.isRed(76, 50), "inside the head near the tip")
        XCTAssertTrue(g.isRed(70, 53), "head is wider than the shaft")
        XCTAssertTrue(g.isWhite(40, 53), "shaft is thin")
        for x in 82..<100 {
            for y in 0..<100 { XCTAssertTrue(g.isWhite(x, y), "ink beyond the tip at \(x),\(y)") }
        }
    }

    func testShortArrowShrinksHead() {
        let a = Annotation(shape: .arrow(from: CGPoint(x: 50, y: 50.5), to: CGPoint(x: 56, y: 50.5)),
                           color: .red, lineWidth: 3)
        let g = render([a])
        XCTAssertTrue(g.isRed(54, 50))
        XCTAssertTrue(g.isWhite(60, 50))
        XCTAssertTrue(g.isWhite(40, 50))
    }

    func testMarkerBlendsAndDoesNotDarkenOverlap() {
        let color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.4)
        // A closed loop that crosses itself at (50, 50).
        let pts: [CGPoint] = [CGPoint(x: 20, y: 50), CGPoint(x: 80, y: 50), CGPoint(x: 50, y: 20),
                              CGPoint(x: 50, y: 80)]
        let a = Annotation(shape: .marker(points: pts), color: color, lineWidth: 16)
        let g = render([a])
        let single = g.pixel(30, 50)
        XCTAssertGreaterThan(single.r, 240)
        XCTAssertTrue(single.g > 120 && single.g < 190, "blended, got \(single)")
        let crossing = g.pixel(65, 50)
        XCTAssertTrue(abs(crossing.g - single.g) <= 3, "overlap must not darken: \(crossing) vs \(single)")
    }

    func testTextPositionAndUpright() {
        let origin = CGPoint(x: 20, y: 30)
        let a = Annotation(shape: .text("L", origin: origin, fontSize: 40), color: .red, lineWidth: 0)
        let size = AnnotationRenderer.textSize("L", fontSize: 40)
        XCTAssertGreaterThan(size.width, 10)
        XCTAssertGreaterThan(size.height, 30)
        let g = render([a], width: 120, height: 120)
        var above = 0, inside = 0, upper = 0, lower = 0
        let boxBottom = Int(origin.y + size.height)
        let mid = Int(origin.y + size.height / 2)
        for y in 0..<120 {
            for x in 0..<120 where !g.isWhite(x, y) {
                if y < Int(origin.y) { above += 1 }
                if y >= Int(origin.y), y <= boxBottom, x >= Int(origin.x) - 1, x <= Int(origin.x + size.width) + 1 {
                    inside += 1
                    if y < mid { upper += 1 } else { lower += 1 }
                }
            }
        }
        XCTAssertEqual(above, 0)
        XCTAssertGreaterThan(inside, 50)
        // An upright "L" has its vertical stem over the whole height and the foot at the bottom,
        // so the lower half carries more ink than the upper half; upside down it is the opposite.
        XCTAssertGreaterThan(lower, upper)
    }

    func testTextSizeMultiLine() {
        let one = AnnotationRenderer.textSize("Hello", fontSize: 18)
        let two = AnnotationRenderer.textSize("Hello\nHi", fontSize: 18)
        XCTAssertEqual(two.width, one.width)
        XCTAssertEqual(two.height, one.height * 2)
        XCTAssertEqual(AnnotationRenderer.textSize("", fontSize: 18).width, 0)
    }

    func testMultiLineTextDrawsSecondLineBelow() {
        let a = Annotation(shape: .text("T\nT", origin: CGPoint(x: 10, y: 10), fontSize: 20), color: .red, lineWidth: 0)
        let size = AnnotationRenderer.textSize("T\nT", fontSize: 20)
        let g = render([a], width: 80, height: 100)
        var lowerHalfInk = 0
        for y in Int(10 + size.height / 2 + 2)..<Int(10 + size.height) {
            for x in 0..<80 where !g.isWhite(x, y) { lowerHalfInk += 1 }
        }
        XCTAssertGreaterThan(lowerHalfInk, 10)
    }
}
