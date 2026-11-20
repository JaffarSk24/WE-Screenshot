import CoreGraphics
import Foundation
import ImageIO
import WECore

public enum ImageComposerError: Error, Equatable {
    case emptySelection
    case cannotCreateContext
    case cannotCrop
}

public enum ImageComposer {
    /// The final screenshot: the selection cropped out of the display snapshot
    /// at full pixel resolution, with the annotations drawn over it.
    /// `selection` is in overlay space; the result is
    /// ScreenGeometry.pixelRect(selection...) in size and has no alpha channel.
    public static func compose(snapshot: DisplaySnapshot, selection: CGRect,
                               annotations: [Annotation]) throws -> CGImage {
        guard selection.origin.x.isFinite, selection.origin.y.isFinite,
              selection.width.isFinite, selection.height.isFinite,
              selection.width > 0, selection.height > 0 else {
            throw ImageComposerError.emptySelection
        }
        let scale = snapshot.display.scale > 0 ? snapshot.display.scale : 1
        let image = snapshot.image
        let crop = ScreenGeometry.pixelRect(selection: selection, scale: scale, imageWidth: image.width, imageHeight: image.height)
        guard let cropped = image.cropping(to: crop) else { throw ImageComposerError.cannotCrop }
        let width = Int(crop.width), height = Int(crop.height)
        guard let ctx = makeContext(width: width, height: height, like: image) else {
            throw ImageComposerError.cannotCreateContext
        }
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        // User space becomes overlay space: y down, scaled, selection origin at the pixel (0, 0).
        ctx.translateBy(x: -crop.minX, y: CGFloat(height) + crop.minY)
        ctx.scaleBy(x: scale, y: -scale)
        AnnotationRenderer.draw(annotations, in: ctx)
        guard let result = ctx.makeImage() else { throw ImageComposerError.cannotCreateContext }
        return result
    }

    /// The image resampled to one pixel per point (high quality interpolation),
    /// for the "save Retina screenshots at half size" setting. With scale <= 1
    /// the image is returned as it is.
    public static func downscaled(_ image: CGImage, fromScale scale: CGFloat) throws -> CGImage {
        guard scale > 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) / scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) / scale).rounded()))
        guard let ctx = makeContext(width: width, height: height, like: image) else {
            throw ImageComposerError.cannotCreateContext
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = ctx.makeImage() else { throw ImageComposerError.cannotCreateContext }
        return result
    }

    // MARK: Helpers

    /// An opaque 8 bit RGB bitmap context in the colour space of `image` when that
    /// is fine at 8 bits per component, else sRGB (Display P3 for wide gamut sources).
    /// Linear and extended range spaces, and sources deeper than 8 bits, would band
    /// or clip in an 8 bit bitmap, so they go to a gamma encoded space.
    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput,
           image.bitsPerComponent <= 8, !isLinearOrExtended(space),
           let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: space, bitmapInfo: info) {
            return ctx
        }
        let fallbackName = image.colorSpace.map(isWideGamut) == true ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        guard let fallback = CGColorSpace(name: fallbackName) ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: fallback, bitmapInfo: info)
    }

    private static func spaceName(_ space: CGColorSpace) -> String {
        (space.name as String?) ?? ""
    }

    private static func isLinearOrExtended(_ space: CGColorSpace) -> Bool {
        let name = spaceName(space).lowercased()
        return name.contains("linear") || name.contains("extended") || name.contains("hdr") || name.contains("pq")
            || name.contains("hlg")
    }

    private static func isWideGamut(_ space: CGColorSpace) -> Bool {
        let name = spaceName(space).lowercased()
        return name.contains("p3") || name.contains("2020") || name.contains("adobe")
    }
}

public enum ImageEncoderError: Error, Equatable {
    case cannotEncode
}

public enum ImageEncoder {
    /// Encodes the image. `scale` is the display's pixels per point: it is
    /// written as the resolution (72 * scale DPI), so a Retina screenshot opens
    /// at its on-screen size, like the system screenshots. JPEG uses `quality`.
    public static func data(for image: CGImage, format: ImageFormat, scale: CGFloat,
                            jpegQuality: Double) throws -> Data {
        let type = format == .png ? "public.png" : "public.jpeg"
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
            throw ImageEncoderError.cannotEncode
        }
        let dpi = 72 * Double(max(scale, 1))
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(jpegQuality, 0), 1)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageEncoderError.cannotEncode }
        return output as Data
    }
}
