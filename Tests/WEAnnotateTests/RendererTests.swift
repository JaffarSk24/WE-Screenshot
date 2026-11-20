import XCTest
import CoreText
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
        // An unshrunk head (13.5 pt) would reach back to x = 42.5 behind the start point.
        XCTAssertTrue(g.isWhite(47, 50), "head must not stick out behind the start")
        XCTAssertTrue(g.isWhite(46, 53), "head base must not be wider than the arrow is long")
        XCTAssertTrue(g.isWhite(48, 56))
        XCTAssertTrue(g.isWhite(48, 44))
    }

    func testTranslucentArrowDoesNotDarkenWhereShaftMeetsHead() {
        let color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        let a = Annotation(shape: .arrow(from: CGPoint(x: 10, y: 50.5), to: CGPoint(x: 80, y: 50.5)),
                           color: color, lineWidth: 3)
        let g = render([a])
        // Head spans x 66.5...80, the shaft ends 0.7 * 13.5 = 9.45 inside it. Column 68 has
        // rows 49...51 over the shaft and rows 46...48 over the head only.
        let headOnly = g.pixel(68, 47)
        let overShaft = g.pixel(68, 50)
        XCTAssertTrue(headOnly.g > 100 && headOnly.g < 160, "blended, got \(headOnly)")
        XCTAssertTrue(abs(headOnly.g - overShaft.g) <= 3, "overlap must not darken: \(overShaft) vs \(headOnly)")
        let shaftOnly = g.pixel(40, 50)
        XCTAssertTrue(abs(headOnly.g - shaftOnly.g) <= 3, "shaft must blend like the head: \(shaftOnly) vs \(headOnly)")
    }

    func testRendererLeavesTextMatrixAlone() {
        let ctx = makeContext(width: 100, height: 100)
        ctx.textMatrix = .identity
        let a = Annotation(shape: .text("Hi", origin: CGPoint(x: 10, y: 10), fontSize: 20), color: .red, lineWidth: 0)
        AnnotationRenderer.draw([a], in: ctx)
        XCTAssertEqual(ctx.textMatrix, .identity)
        let custom = CGAffineTransform(a: 2, b: 0, c: 0, d: 3, tx: 5, ty: 7)
        ctx.textMatrix = custom
        AnnotationRenderer.draw([a], in: ctx)
        XCTAssertEqual(ctx.textMatrix, custom)
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
        let font = CTFontCreateWithName(AnnotationStyle.textFontName as CFString, 40, nil)
        let baseline = Int((origin.y + CTFontGetAscent(font)).rounded())
        let capHeight = Int(CTFontGetCapHeight(font).rounded())
        var above = 0, belowBaseline = 0, nearCapTop = 0, nearBaseline = 0
        for y in 0..<120 {
            for x in 0..<120 where !g.isWhite(x, y) {
                if y < Int(origin.y) { above += 1 }
                if y > baseline + 1 { belowBaseline += 1 }
                if y >= baseline - capHeight && y <= baseline - capHeight + 3 { nearCapTop += 1 }
                if y >= baseline - 3 && y <= baseline { nearBaseline += 1 }
            }
        }
        XCTAssertEqual(above, 0)
        // Upright: the ink sits between baseline - capHeight and the baseline, with the foot
        // of the L (wide) at the baseline and only the stem at the top. Mirrored glyphs hang
        // below the baseline instead.
        XCTAssertLessThan(belowBaseline, 5, "ink below the baseline means the text is upside down")
        XCTAssertGreaterThan(nearBaseline, 40, "the foot of the L lies on the baseline")
        XCTAssertGreaterThan(nearBaseline, nearCapTop, "the foot is wider than the stem")
    }

    func testTextSizeMultiLine() {
        let one = AnnotationRenderer.textSize("Hello", fontSize: 18)
        let two = AnnotationRenderer.textSize("Hello\nHi", fontSize: 18)
        XCTAssertEqual(two.width, one.width)
        XCTAssertEqual(two.height, one.height * 2)
        XCTAssertEqual(AnnotationRenderer.textSize("", fontSize: 18).width, 0)
    }

    func testMultiLineTextDrawsSecondLineBelow() {
        let origin = CGPoint(x: 10, y: 10)
        let a = Annotation(shape: .text("T\nT", origin: origin, fontSize: 20), color: .red, lineWidth: 0)
        let g = render([a], width: 80, height: 100)
        let font = CTFontCreateWithName(AnnotationStyle.textFontName as CFString, 20, nil)
        let ascent = CTFontGetAscent(font)
        let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        // Each upright T sits between baseline - capHeight and its baseline; the second line is one line height lower.
        func ink(_ from: CGFloat, _ to: CGFloat) -> Int {
            var n = 0
            for y in Int(from.rounded())..<Int(to.rounded()) {
                for x in 0..<80 where !g.isWhite(x, y) { n += 1 }
            }
            return n
        }
        let cap = CTFontGetCapHeight(font)
        let base1 = origin.y + ascent, base2 = base1 + lineHeight
        XCTAssertGreaterThan(ink(base1 - cap + 1, base1 - 1), 20, "first line")
        XCTAssertGreaterThan(ink(base2 - cap + 1, base2 - 1), 20, "second line")
        XCTAssertEqual(ink(base1 + 2, base2 - cap - 1), 0, "gap between the lines")
        XCTAssertEqual(ink(base2 + 2, 100), 0, "nothing below the second baseline")
    }
}
