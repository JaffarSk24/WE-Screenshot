import CoreGraphics
import Foundation
import ImageIO
import WECore
import WEAnnotate

struct Pixel: Equatable {
    var r: Int, g: Int, b: Int, a: Int
}

/// Raw RGBA pixels of an image, row 0 on top.
struct PixelGrid {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init(_ image: CGImage) {
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        data = buffer
    }

    func pixel(_ x: Int, _ y: Int) -> Pixel {
        let i = (y * width + x) * 4
        return Pixel(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]), a: Int(data[i + 3]))
    }

    func isWhite(_ x: Int, _ y: Int) -> Bool {
        let p = pixel(x, y)
        return p.r > 250 && p.g > 250 && p.b > 250
    }

    func isRed(_ x: Int, _ y: Int) -> Bool {
        let p = pixel(x, y)
        return p.r > 200 && p.g < 60 && p.b < 60
    }
}

func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Draws annotations over white in a flipped (y down) context of the given size and returns the pixels.
func render(_ annotations: [Annotation], width: Int = 100, height: Int = 100) -> PixelGrid {
    let ctx = makeContext(width: width, height: height)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    AnnotationRenderer.draw(annotations, in: ctx)
    return PixelGrid(ctx.makeImage()!)
}

/// Four quadrants: top left red, top right green, bottom left blue, bottom right yellow.
func quadrantImage(width: Int, height: Int) -> CGImage {
    let ctx = makeContext(width: width, height: height)
    let hw = CGFloat(width) / 2, hh = CGFloat(height) / 2
    // CGContext is y up: the "top" quadrants are at the larger y.
    let colors: [(CGRect, (CGFloat, CGFloat, CGFloat))] = [
        (CGRect(x: 0, y: hh, width: hw, height: hh), (1, 0, 0)),
        (CGRect(x: hw, y: hh, width: hw, height: hh), (0, 1, 0)),
        (CGRect(x: 0, y: 0, width: hw, height: hh), (0, 0, 1)),
        (CGRect(x: hw, y: 0, width: hw, height: hh), (1, 1, 0)),
    ]
    for (rect, c) in colors {
        ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fill(rect)
    }
    return ctx.makeImage()!
}

func snapshot(width: Int = 200, height: Int = 100, scale: CGFloat = 2) -> DisplaySnapshot {
    let info = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: width, height: height), scale: scale)
    return DisplaySnapshot(display: info,
                           image: quadrantImage(width: Int(CGFloat(width) * scale), height: Int(CGFloat(height) * scale)))
}
