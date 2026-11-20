import XCTest
@testable import WECore

final class SelectionTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func model(_ rect: CGRect? = nil) -> SelectionModel {
        var m = SelectionModel(bounds: bounds)
        if let rect {
            m.beginCreate(at: rect.origin)
            m.drag(to: CGPoint(x: rect.maxX, y: rect.maxY))
            m.endDrag()
        }
        return m
    }

    private func create(from a: CGPoint, to b: CGPoint) -> CGRect? {
        var m = SelectionModel(bounds: bounds)
        m.beginCreate(at: a)
        m.drag(to: b)
        m.endDrag()
        return m.rect
    }

    func testCreateInEveryDirection() {
        let expected = CGRect(x: 100, y: 100, width: 50, height: 40)
        XCTAssertEqual(create(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 150, y: 140)), expected)
        XCTAssertEqual(create(from: CGPoint(x: 150, y: 100), to: CGPoint(x: 100, y: 140)), expected)
        XCTAssertEqual(create(from: CGPoint(x: 100, y: 140), to: CGPoint(x: 150, y: 100)), expected)
        XCTAssertEqual(create(from: CGPoint(x: 150, y: 140), to: CGPoint(x: 100, y: 100)), expected)
    }

    func testClickLeavesNoSelection() {
        XCTAssertNil(create(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10)))
        XCTAssertNil(create(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11)))
        var m = model(CGRect(x: 10, y: 10, width: 100, height: 100))
        m.beginCreate(at: CGPoint(x: 500, y: 500))
        m.endDrag()
        XCTAssertNil(m.rect)
        XCTAssertFalse(m.isDragging)
    }

    func testDragWithoutGestureDoesNothing() {
        var m = model(CGRect(x: 10, y: 10, width: 100, height: 100))
        m.drag(to: CGPoint(x: 300, y: 300))
        XCTAssertEqual(m.rect, CGRect(x: 10, y: 10, width: 100, height: 100))
    }

    func testCreateClampsAtAllFourBounds() {
        XCTAssertEqual(create(from: CGPoint(x: 500, y: 400), to: CGPoint(x: -50, y: -50)),
                       CGRect(x: 0, y: 0, width: 500, height: 400))
        XCTAssertEqual(create(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 5000, y: 5000)),
                       CGRect(x: 500, y: 400, width: 500, height: 400))
        XCTAssertEqual(create(from: CGPoint(x: -20, y: -20), to: CGPoint(x: 100, y: 100)),
                       CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testMoveKeepsSizeAndClamps() {
        var m = model(CGRect(x: 100, y: 100, width: 200, height: 100))
        m.beginMove(at: CGPoint(x: 150, y: 120))
        m.drag(to: CGPoint(x: 250, y: 220))
        XCTAssertEqual(m.rect, CGRect(x: 200, y: 200, width: 200, height: 100))
        m.drag(to: CGPoint(x: -500, y: -500))
        XCTAssertEqual(m.rect, CGRect(x: 0, y: 0, width: 200, height: 100))
        m.drag(to: CGPoint(x: 5000, y: 5000))
        XCTAssertEqual(m.rect, CGRect(x: 800, y: 700, width: 200, height: 100))
        m.endDrag()
        XCTAssertEqual(m.rect, CGRect(x: 800, y: 700, width: 200, height: 100))
    }

    func testMoveOfTinySelectionIsNeverRemoved() {
        var m = model(CGRect(x: 100, y: 100, width: 10, height: 10))
        m.beginMove(at: CGPoint(x: 105, y: 105))
        m.drag(to: CGPoint(x: 105, y: 105))
        m.endDrag()
        XCTAssertNotNil(m.rect)
    }

    func testResizeClampsAtAllFourBounds() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 200)
        var m = model(base)
        m.beginResize(.bottomRight, at: CGPoint(x: 300, y: 300))
        m.drag(to: CGPoint(x: 5000, y: 5000))
        XCTAssertEqual(m.rect, CGRect(x: 100, y: 100, width: 900, height: 700))
        m.endDrag()
        m = model(base)
        m.beginResize(.topLeft, at: CGPoint(x: 100, y: 100))
        m.drag(to: CGPoint(x: -5000, y: -5000))
        XCTAssertEqual(m.rect, CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    func testEightHandles() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 200)
        let cases: [(SelectionHandle, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: 150, y: 120), CGRect(x: 150, y: 120, width: 150, height: 180)),
            (.top, CGPoint(x: 999, y: 120), CGRect(x: 100, y: 120, width: 200, height: 180)),
            (.topRight, CGPoint(x: 350, y: 120), CGRect(x: 100, y: 120, width: 250, height: 180)),
            (.right, CGPoint(x: 350, y: 999), CGRect(x: 100, y: 100, width: 250, height: 200)),
            (.bottomRight, CGPoint(x: 350, y: 380), CGRect(x: 100, y: 100, width: 250, height: 280)),
            (.bottom, CGPoint(x: 0, y: 380), CGRect(x: 100, y: 100, width: 200, height: 280)),
            (.bottomLeft, CGPoint(x: 50, y: 380), CGRect(x: 50, y: 100, width: 250, height: 280)),
            (.left, CGPoint(x: 50, y: 0), CGRect(x: 50, y: 100, width: 250, height: 200)),
        ]
        for (handle, point, expected) in cases {
            var m = model(base)
            m.beginResize(handle, at: m.handleCenters()[handle]!)
            m.drag(to: point)
            XCTAssertEqual(m.rect, expected, "\(handle)")
            m.endDrag()
            XCTAssertEqual(m.rect, expected, "\(handle) after end")
        }
    }

    func testResizeFlipsPastOppositeEdge() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 200)
        var m = model(base)
        m.beginResize(.right, at: CGPoint(x: 300, y: 200))
        m.drag(to: CGPoint(x: 40, y: 200))
        XCTAssertEqual(m.rect, CGRect(x: 40, y: 100, width: 60, height: 200))
        m.drag(to: CGPoint(x: 400, y: 200))
        XCTAssertEqual(m.rect, CGRect(x: 100, y: 100, width: 300, height: 200))
        m.endDrag()

        m = model(base)
        m.beginResize(.topLeft, at: CGPoint(x: 100, y: 100))
        m.drag(to: CGPoint(x: 400, y: 500))
        XCTAssertEqual(m.rect, CGRect(x: 300, y: 300, width: 100, height: 200))
    }

    func testEndDragRoundsToWholePoints() {
        var m = SelectionModel(bounds: bounds)
        m.beginCreate(at: CGPoint(x: 10.4, y: 20.6))
        m.drag(to: CGPoint(x: 110.2, y: 90.9))
        m.endDrag()
        let r = m.rect!
        XCTAssertEqual(r.minX, r.minX.rounded())
        XCTAssertEqual(r.minY, r.minY.rounded())
        XCTAssertEqual(r.width, r.width.rounded())
        XCTAssertEqual(r.height, r.height.rounded())
        XCTAssertTrue(bounds.contains(r))
    }

    func testRoundingStaysInsideBounds() {
        var m = SelectionModel(bounds: bounds)
        m.beginCreate(at: CGPoint(x: 900.4, y: 700.4))
        m.drag(to: CGPoint(x: 1000, y: 800))
        m.endDrag()
        XCTAssertTrue(bounds.contains(m.rect!))
    }

    func testHitTestPriorityAndTolerance() {
        let m = model(CGRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertEqual(m.hitTest(CGPoint(x: 100, y: 100), tolerance: 6), .handle(.topLeft))
        XCTAssertEqual(m.hitTest(CGPoint(x: 105, y: 94), tolerance: 6), .handle(.topLeft))
        XCTAssertEqual(m.hitTest(CGPoint(x: 107, y: 100), tolerance: 6), .inside)
        XCTAssertEqual(m.hitTest(CGPoint(x: 200, y: 100), tolerance: 6), .handle(.top))
        XCTAssertEqual(m.hitTest(CGPoint(x: 300, y: 200), tolerance: 6), .handle(.right))
        XCTAssertEqual(m.hitTest(CGPoint(x: 200, y: 200), tolerance: 6), .inside)
        XCTAssertEqual(m.hitTest(CGPoint(x: 150, y: 100), tolerance: 6), .inside)
        XCTAssertEqual(m.hitTest(CGPoint(x: 99, y: 150), tolerance: 6), .outside)
        XCTAssertEqual(m.hitTest(CGPoint(x: 10, y: 10), tolerance: 6), .outside)
        XCTAssertEqual(SelectionModel(bounds: bounds).hitTest(CGPoint(x: 1, y: 1), tolerance: 6), .outside)
    }

    func testHitTestOnTinySelectionPrefersNearestHandle() {
        let m = model(CGRect(x: 100, y: 100, width: 4, height: 4))
        XCTAssertEqual(m.hitTest(CGPoint(x: 104, y: 104), tolerance: 6), .handle(.bottomRight))
        XCTAssertEqual(m.hitTest(CGPoint(x: 100, y: 100), tolerance: 6), .handle(.topLeft))
    }

    func testHandleCenters() {
        XCTAssertTrue(SelectionModel(bounds: bounds).handleCenters().isEmpty)
        let c = model(CGRect(x: 100, y: 100, width: 200, height: 100)).handleCenters()
        XCTAssertEqual(c.count, 8)
        XCTAssertEqual(c[.topLeft], CGPoint(x: 100, y: 100))
        XCTAssertEqual(c[.right], CGPoint(x: 300, y: 150))
        XCTAssertEqual(c[.bottom], CGPoint(x: 200, y: 200))
    }

    func testNudge() {
        var m = SelectionModel(bounds: bounds)
        m.nudge(dx: 5, dy: 5)
        XCTAssertNil(m.rect)
        m = model(CGRect(x: 10, y: 10, width: 100, height: 100))
        m.nudge(dx: -50, dy: -50)
        XCTAssertEqual(m.rect, CGRect(x: 0, y: 0, width: 100, height: 100))
        m.nudge(dx: 3, dy: 1)
        XCTAssertEqual(m.rect, CGRect(x: 3, y: 1, width: 100, height: 100))
        m.nudge(dx: 5000, dy: 5000)
        XCTAssertEqual(m.rect, CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    func testResizeLimits() {
        var m = SelectionModel(bounds: bounds)
        m.resize(dw: 5, dh: 5)
        XCTAssertNil(m.rect)
        m = model(CGRect(x: 900, y: 700, width: 50, height: 50))
        m.resize(dw: 500, dh: 500)
        XCTAssertEqual(m.rect, CGRect(x: 900, y: 700, width: 100, height: 100))
        m.resize(dw: -5000, dh: -5000)
        XCTAssertEqual(m.rect, CGRect(x: 900, y: 700, width: 1, height: 1))
        m.resize(dw: 10, dh: 0)
        XCTAssertEqual(m.rect, CGRect(x: 900, y: 700, width: 11, height: 1))
    }

    func testSelectAllAndClear() {
        var m = SelectionModel(bounds: bounds)
        m.selectAll()
        XCTAssertEqual(m.rect, bounds)
        m.clear()
        XCTAssertNil(m.rect)
        XCTAssertFalse(m.isDragging)
    }

    func testIsDraggingFlag() {
        var m = SelectionModel(bounds: bounds)
        m.beginCreate(at: CGPoint(x: 1, y: 1))
        XCTAssertTrue(m.isDragging)
        m.drag(to: CGPoint(x: 50, y: 50))
        m.endDrag()
        XCTAssertFalse(m.isDragging)
    }
}

final class ScreenGeometryTests: XCTestCase {
    func testPixelRectScale1And2() {
        XCTAssertEqual(ScreenGeometry.pixelRect(selection: CGRect(x: 10, y: 20, width: 100, height: 50), scale: 1,
                                                imageWidth: 1000, imageHeight: 800),
                       CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(ScreenGeometry.pixelRect(selection: CGRect(x: 10, y: 20, width: 100, height: 50), scale: 2,
                                                imageWidth: 2000, imageHeight: 1600),
                       CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    func testPixelRectFractionalInput() {
        let r = ScreenGeometry.pixelRect(selection: CGRect(x: 10.3, y: 20.7, width: 10.2, height: 10.2), scale: 1,
                                         imageWidth: 100, imageHeight: 100)
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 11, height: 11))
        let tiny = ScreenGeometry.pixelRect(selection: CGRect(x: 10.001, y: 10.999, width: 20, height: 20), scale: 1,
                                            imageWidth: 100, imageHeight: 100)
        XCTAssertEqual(tiny, CGRect(x: 10, y: 11, width: 20, height: 20))
    }

    func testPixelRectAtImageEdges() {
        XCTAssertEqual(ScreenGeometry.pixelRect(selection: CGRect(x: 0, y: 0, width: 500, height: 400), scale: 2,
                                                imageWidth: 1000, imageHeight: 800),
                       CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(ScreenGeometry.pixelRect(selection: CGRect(x: 400, y: 300, width: 300, height: 300), scale: 2,
                                                imageWidth: 1000, imageHeight: 800),
                       CGRect(x: 800, y: 600, width: 200, height: 200))
        XCTAssertEqual(ScreenGeometry.pixelRect(selection: CGRect(x: -10, y: -10, width: 30, height: 30), scale: 1,
                                                imageWidth: 100, imageHeight: 100),
                       CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func testPixelRectMinimumOneByOne() {
        XCTAssertEqual(ScreenGeometry.pixelRect(selection: CGRect(x: 5, y: 5, width: 0, height: 0), scale: 1,
                                                imageWidth: 100, imageHeight: 100),
                       CGRect(x: 5, y: 5, width: 1, height: 1))
        XCTAssertEqual(ScreenGeometry.pixelRect(selection: CGRect(x: 100, y: 100, width: 0, height: 0), scale: 1,
                                                imageWidth: 100, imageHeight: 100),
                       CGRect(x: 99, y: 99, width: 1, height: 1))
        XCTAssertEqual(ScreenGeometry.pixelRect(selection: CGRect(x: 500, y: 500, width: 10, height: 10), scale: 1,
                                                imageWidth: 100, imageHeight: 100),
                       CGRect(x: 99, y: 99, width: 1, height: 1))
    }

    func testOverlayPointOnSecondaryDisplayWithNegativeOrigin() {
        let frame = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        XCTAssertEqual(ScreenGeometry.overlayPoint(fromGlobal: CGPoint(x: -1920, y: 1280), displayFrame: frame),
                       CGPoint(x: 0, y: 0))
        XCTAssertEqual(ScreenGeometry.overlayPoint(fromGlobal: CGPoint(x: -1000, y: 700), displayFrame: frame),
                       CGPoint(x: 920, y: 580))
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(ScreenGeometry.overlayPoint(fromGlobal: CGPoint(x: 10, y: 890), displayFrame: primary),
                       CGPoint(x: 10, y: 10))
    }

    func testSizeLabel() {
        XCTAssertEqual(ScreenGeometry.sizeLabel(selection: CGRect(x: 0, y: 0, width: 640, height: 360), scale: 2), "1280x720")
        XCTAssertEqual(ScreenGeometry.sizeLabel(selection: CGRect(x: 0, y: 0, width: 100.4, height: 50.6), scale: 1), "100x51")
    }

    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let panel = CGSize(width: 200, height: 40)
    let order: [PanelPlacement] = [.rightOutside, .leftOutside, .belowOutside, .aboveOutside, .rightInside, .bottomInside]

    func origin(_ selection: CGRect) -> CGPoint {
        ScreenGeometry.panelOrigin(size: panel, selection: selection, bounds: bounds, preferred: order, gap: 8)
    }

    func testPanelInTheMiddle() {
        XCTAssertEqual(origin(CGRect(x: 300, y: 200, width: 200, height: 200)), CGPoint(x: 508, y: 200))
    }

    func testPanelAtRightEdge() {
        // Right side is full, so the left side is used.
        XCTAssertEqual(origin(CGRect(x: 700, y: 200, width: 300, height: 200)), CGPoint(x: 492, y: 200))
        // Neither side fits: below, right aligned.
        XCTAssertEqual(origin(CGRect(x: 100, y: 100, width: 880, height: 200)), CGPoint(x: 780, y: 308))
    }

    func testPanelAtBottomEdge() {
        // Right side, shifted up so that it does not cross the bottom.
        XCTAssertEqual(origin(CGRect(x: 300, y: 780, width: 200, height: 20)), CGPoint(x: 508, y: 760))
        // Wide selection at the bottom: above, right aligned.
        XCTAssertEqual(origin(CGRect(x: 10, y: 600, width: 980, height: 200)), CGPoint(x: 790, y: 552))
    }

    func testBelowShiftsRightAtLeftEdge() {
        let o = ScreenGeometry.panelOrigin(size: panel, selection: CGRect(x: 0, y: 100, width: 100, height: 100),
                                           bounds: bounds, preferred: [.belowOutside], gap: 8)
        XCTAssertEqual(o, CGPoint(x: 0, y: 208))
    }

    func testPanelFillingTheWholeDisplay() {
        XCTAssertEqual(origin(bounds), CGPoint(x: 792, y: 8))
        let o = ScreenGeometry.panelOrigin(size: panel, selection: bounds, bounds: bounds,
                                           preferred: [.bottomInside], gap: 8)
        XCTAssertEqual(o, CGPoint(x: 792, y: 752))
    }

    func testPanelFallbackIsClamped() {
        let o = ScreenGeometry.panelOrigin(size: panel, selection: bounds, bounds: bounds,
                                           preferred: [.rightOutside], gap: 8)
        XCTAssertEqual(o, CGPoint(x: 800, y: 0))
        XCTAssertTrue(bounds.contains(CGRect(origin: o, size: panel)))
    }
}
