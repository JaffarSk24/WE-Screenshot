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

    func testTextIsUprightInComposedImage() throws {
        // Scale 2, selection inside the blue quadrant. White "L" at (20, 55) pt: stem on the left, foot along the bottom.
        let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        let a = Annotation(shape: .text("L", origin: CGPoint(x: 20, y: 55), fontSize: 30), color: white, lineWidth: 0)
        let image = try ImageComposer.compose(snapshot: snapshot(), selection: CGRect(x: 10, y: 50, width: 80, height: 50),
                                              annotations: [a])
        let g = PixelGrid(image)
        var rows: [Int] = []
        for y in 0..<g.height {
            var n = 0
            for x in 0..<g.width where g.pixel(x, y).r > 200 { n += 1 }
            rows.append(n)
        }
        guard let first = rows.firstIndex(where: { $0 > 0 }), let last = rows.lastIndex(where: { $0 > 0 }) else {
            return XCTFail("no text ink")
        }
        // Upright: the foot is a wide run of ink in the bottom rows, the top rows hold only the stem.
        XCTAssertGreaterThan(rows[last - 2], rows[first + 2] * 2, "text looks upside down")
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

    /// A dark horizontal ramp as a 16 bit image in the given space (value written in that space).
    private func rampImage(space: CGColorSpace, bitsPerComponent: Int = 16, columns: Int = 64) -> CGImage {
        var data = [UInt16](repeating: 0, count: columns * 4)
        for x in 0..<columns {
            let v = UInt16(Double(x) / Double(columns - 1) * 0.02 * 65535)
            data[x * 4] = v; data[x * 4 + 1] = v; data[x * 4 + 2] = v; data[x * 4 + 3] = 65535
        }
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        let provider = CGDataProvider(data: bytes as CFData)!
        return CGImage(width: columns, height: 1, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerComponent * 4,
                       bytesPerRow: columns * 8, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func distinctLevels(_ image: CGImage) -> Int {
        let g = PixelGrid(image)
        return Set((0..<g.width).map { g.pixel($0, 0).g }).count
    }

    func testLinear16BitSnapshotKeepsDarkLevels() throws {
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let src = rampImage(space: linear)
        let info = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 1), scale: 1)
        let composed = try ImageComposer.compose(snapshot: DisplaySnapshot(display: info, image: src),
                                                 selection: CGRect(x: 0, y: 0, width: 64, height: 1), annotations: [])
        let name = composed.colorSpace?.name as String?
        XCTAssertNotEqual(name, CGColorSpace.linearSRGB as String, "must not compose into an 8 bit linear space")
        XCTAssertGreaterThan(distinctLevels(composed), 20, "dark ramp must not band")
        let scaled = try ImageComposer.downscaled(src, fromScale: 2)
        XCTAssertNotEqual(scaled.colorSpace?.name as String?, CGColorSpace.linearSRGB as String)
    }

    func testHighBitDepthGammaSnapshotFallsBackToGammaSpace() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let src = rampImage(space: p3)
        let info = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 1), scale: 1)
        let composed = try ImageComposer.compose(snapshot: DisplaySnapshot(display: info, image: src),
                                                 selection: CGRect(x: 0, y: 0, width: 64, height: 1), annotations: [])
        XCTAssertEqual(composed.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
    }

    func testEightBitSRGBSnapshotKeepsItsSpace() throws {
        let composed = try ImageComposer.compose(snapshot: snapshot(), selection: CGRect(x: 0, y: 0, width: 20, height: 20),
                                                 annotations: [])
        XCTAssertEqual(composed.colorSpace?.name as String?, CGColorSpace.sRGB as String)
    }
}
