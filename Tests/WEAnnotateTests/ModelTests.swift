import XCTest
import WECore
import WEAnnotate

final class ModelTests: XCTestCase {
    private func sample(_ x: CGFloat) -> Annotation {
        Annotation(shape: .line(from: .zero, to: CGPoint(x: x, y: 0)), color: .red, lineWidth: 3)
    }

    func testStackAddUndoClear() {
        var stack = AnnotationStack()
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.undo())
        stack.add(sample(1))
        stack.add(sample(2))
        XCTAssertTrue(stack.canUndo)
        XCTAssertEqual(stack.items.count, 2)
        XCTAssertTrue(stack.undo())
        XCTAssertEqual(stack.items, [sample(1)])
        stack.add(sample(3))
        stack.clear()
        XCTAssertTrue(stack.items.isEmpty)
        XCTAssertFalse(stack.canUndo)
    }

    func testClickGivesNil() {
        for tool in Tool.allCases where tool != .text {
            var g = AnnotationGesture(tool: tool, color: .red, start: CGPoint(x: 10, y: 10))
            XCTAssertNil(g.finish(), "\(tool)")
            g.update(to: CGPoint(x: 11, y: 11), clip: CGRect(x: 0, y: 0, width: 100, height: 100))
            XCTAssertNil(g.finish(), "\(tool) after a tiny move")
        }
    }

    func testPointsAreClampedToClip() {
        let clip = CGRect(x: 10, y: 10, width: 50, height: 40)
        var g = AnnotationGesture(tool: .line, color: .red, start: CGPoint(x: 20, y: 20))
        g.update(to: CGPoint(x: 500, y: -300), clip: clip)
        guard case .line(let from, let to)? = g.finish()?.shape else { return XCTFail("no line") }
        XCTAssertEqual(from, CGPoint(x: 20, y: 20))
        XCTAssertEqual(to, CGPoint(x: 60, y: 10))
    }

    func testRectangleIsNormalised() {
        var g = AnnotationGesture(tool: .rectangle, color: .red, start: CGPoint(x: 50, y: 60))
        g.update(to: CGPoint(x: 20, y: 10), clip: CGRect(x: 0, y: 0, width: 100, height: 100))
        guard case .rectangle(let r)? = g.finish()?.shape else { return XCTFail("no rect") }
        XCTAssertEqual(r, CGRect(x: 20, y: 10, width: 30, height: 50))
    }

    func testMarkerColourAndWidth() {
        var g = AnnotationGesture(tool: .marker, color: RGBAColor(red: 1, green: 1, blue: 0), start: .zero)
        g.update(to: CGPoint(x: 30, y: 0), clip: CGRect(x: 0, y: 0, width: 100, height: 100))
        let a = g.finish()
        XCTAssertEqual(a?.color.alpha, AnnotationStyle.markerAlpha)
        XCTAssertEqual(a?.color.green, 1)
        XCTAssertEqual(a?.lineWidth, AnnotationStyle.markerWidth)
    }

    func testToolWidths() {
        var g = AnnotationGesture(tool: .arrow, color: .red, start: .zero)
        g.update(to: CGPoint(x: 30, y: 0), clip: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(g.finish()?.lineWidth, AnnotationStyle.lineWidth)
        XCTAssertNotNil(g.preview)
    }

    func testFreehandPointThinning() {
        let clip = CGRect(x: 0, y: 0, width: 100, height: 100)
        var g = AnnotationGesture(tool: .pencil, color: .red, start: .zero)
        g.update(to: CGPoint(x: 0.2, y: 0), clip: clip)
        g.update(to: CGPoint(x: 0.4, y: 0.1), clip: clip)
        g.update(to: CGPoint(x: 5, y: 0), clip: clip)
        g.update(to: CGPoint(x: 5.1, y: 0.1), clip: clip)
        guard case .pencil(let pts)? = g.finish()?.shape else { return XCTFail("no pencil") }
        XCTAssertEqual(pts, [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0)])
    }

    func testFreehandSmallBoxIsNil() {
        let clip = CGRect(x: 0, y: 0, width: 100, height: 100)
        var g = AnnotationGesture(tool: .pencil, color: .red, start: .zero)
        g.update(to: CGPoint(x: 1, y: 1), clip: clip)
        g.update(to: CGPoint(x: 0, y: 1.2), clip: clip)
        XCTAssertNil(g.finish())
    }
}
