import XCTest
import ImageIO
import WECore
import WEAnnotate

final class ComposerTests: XCTestCase {
    private func near(_ p: Pixel, _ r: Int, _ g: Int, _ b: Int) -> Bool {
        abs(p.r - r) < 4 && abs(p.g - g) < 4 && abs(p.b - b) < 4
    }

    func testComposeSizeAndCornerColours() throws {
        // Selection crosses all four quadrants: points (80,30)...(120,70), pixels (160,60)...(240,140).
        let image = try ImageComposer.compose(snapshot: snapshot(), selection: CGRect(x: 80, y: 30, width: 40, height: 40),
                                              annotations: [])
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 80)
        let g = PixelGrid(image)
        XCTAssertTrue(near(g.pixel(2, 2), 255, 0, 0))
        XCTAssertTrue(near(g.pixel(77, 2), 0, 255, 0))
        XCTAssertTrue(near(g.pixel(2, 77), 0, 0, 255))
        XCTAssertTrue(near(g.pixel(77, 77), 255, 255, 0))
    }

    func testNoAlpha() throws {
        let image = try ImageComposer.compose(snapshot: snapshot(), selection: CGRect(x: 0, y: 0, width: 50, height: 50),
                                              annotations: [])
        let info = image.alphaInfo
        XCTAssertTrue(info == .noneSkipLast || info == .noneSkipFirst || info == .none, "\(info)")
        XCTAssertEqual(PixelGrid(image).pixel(10, 10).a, 255)
    }

    func testAnnotationLandsInTheRightPlace() throws {
        // Horizontal line at y = 50 pt, x from 100 to 140 pt, 4 pt wide.
        // Selection starts at (90, 40): in the result the line is at y = 20 px (rows 16...23),
        // x from 20 to 100 px.
        let line = Annotation(shape: .line(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 140, y: 50)),
                              color: RGBAColor(red: 1, green: 0, blue: 1), lineWidth: 4)
        let image = try ImageComposer.compose(snapshot: snapshot(), selection: CGRect(x: 90, y: 40, width: 60, height: 40),
                                              annotations: [line])
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
        let g = PixelGrid(image)
        XCTAssertTrue(near(g.pixel(60, 20), 255, 0, 255))
        XCTAssertTrue(near(g.pixel(60, 17), 255, 0, 255))
        XCTAssertTrue(near(g.pixel(60, 22), 255, 0, 255))
        XCTAssertFalse(near(g.pixel(60, 12), 255, 0, 255))
        XCTAssertFalse(near(g.pixel(60, 28), 255, 0, 255))
        XCTAssertFalse(near(g.pixel(8, 20), 255, 0, 255), "left of the line start")
        XCTAssertTrue(near(g.pixel(60, 5), 0, 255, 0), "background above the line")
        XCTAssertTrue(near(g.pixel(60, 50), 255, 255, 0), "background below the line")
    }

    func testSelectionPartlyOutsideIsClamped() throws {
        let image = try ImageComposer.compose(snapshot: snapshot(), selection: CGRect(x: 150, y: 50, width: 100, height: 100),
                                              annotations: [])
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 100)
        XCTAssertTrue(near(PixelGrid(image).pixel(5, 5), 255, 255, 0))
    }

    func testEmptySelectionThrows() {
        for rect in [CGRect.zero, CGRect(x: 10, y: 10, width: 0, height: 20), CGRect(x: CGFloat.nan, y: 0, width: 5, height: 5),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 5)] {
            XCTAssertThrowsError(try ImageComposer.compose(snapshot: snapshot(), selection: rect, annotations: [])) {
                XCTAssertEqual($0 as? ImageComposerError, .emptySelection)
            }
        }
    }

    func testFractionalSelectionRoundsOutward() throws {
        let image = try ImageComposer.compose(snapshot: snapshot(scale: 2),
                                              selection: CGRect(x: 10.2, y: 10.2, width: 10, height: 10), annotations: [])
        // 20.4 down = 20, 40.4 up = 41 (x1 = 20.4 * 2 -> 41)
        XCTAssertEqual(image.width, 21)
        XCTAssertEqual(image.height, 21)
    }

    func testDownscaledSizes() throws {
        let image = try ImageComposer.compose(snapshot: snapshot(), selection: CGRect(x: 0, y: 0, width: 100, height: 50),
                                              annotations: [])
        XCTAssertEqual(image.width, 200)
        let small = try ImageComposer.downscaled(image, fromScale: 2)
        XCTAssertEqual(small.width, 100)
        XCTAssertEqual(small.height, 50)
        let same = try ImageComposer.downscaled(image, fromScale: 1)
        XCTAssertEqual(same.width, 200)
        let odd = try ImageComposer.downscaled(image, fromScale: 3)
        XCTAssertEqual(odd.width, 67)
        let tiny = try ImageComposer.compose(snapshot: snapshot(), selection: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                             annotations: [])
        let one = try ImageComposer.downscaled(tiny, fromScale: 2)
        XCTAssertEqual(one.width, 1)
        XCTAssertEqual(one.height, 1)
    }
}

final class EncoderTests: XCTestCase {
    private func sampleImage() throws -> CGImage {
        // Noisy enough that JPEG quality changes the size.
        let w = 160, h = 160
        let ctx = makeContext(width: w, height: h)
        var seed: UInt32 = 12345
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1664525 &+ 1013904223
                let v = CGFloat(seed >> 24) / 255
                ctx.setFillColor(CGColor(srgbRed: v, green: CGFloat(x) / CGFloat(w), blue: CGFloat(y) / CGFloat(h), alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    func testPNG() throws {
        let image = try sampleImage()
        let data = try ImageEncoder.data(for: image, format: .png, scale: 2, jpegQuality: 0.8)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual((props?[kCGImagePropertyDPIWidth] as? Double) ?? 0, 144, accuracy: 0.5)
        XCTAssertEqual((props?[kCGImagePropertyDPIHeight] as? Double) ?? 0, 144, accuracy: 0.5)
    }

    func testJPEGQuality() throws {
        let image = try sampleImage()
        let high = try ImageEncoder.data(for: image, format: .jpeg, scale: 1, jpegQuality: 0.95)
        let low = try ImageEncoder.data(for: image, format: .jpeg, scale: 1, jpegQuality: 0.2)
        XCTAssertEqual(Array(high.prefix(2)), [0xFF, 0xD8])
        XCTAssertLessThan(low.count, high.count)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(low as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
    }
}
