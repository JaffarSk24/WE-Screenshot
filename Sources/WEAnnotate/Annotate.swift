import CoreGraphics
import Foundation
import WECore

// CONTRACT STUB. The public declarations are fixed; the bodies are placeholders.
//
// All coordinates are in overlay space (see WECore/Selection.swift): points,
// origin at the top left corner of the display, y grows down.

/// The drawing tools of the toolbar.
public enum Tool: String, CaseIterable, Sendable {
    case pencil, line, arrow, rectangle, marker, text
}

/// One finished drawing on top of the screenshot.
public struct Annotation: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        /// Freehand line through the points.
        case pencil(points: [CGPoint])
        case line(from: CGPoint, to: CGPoint)
        /// A line with a filled arrow head at `to`.
        case arrow(from: CGPoint, to: CGPoint)
        /// Outline only, not filled.
        case rectangle(CGRect)
        /// Freehand highlighter: a wide, half transparent stroke.
        case marker(points: [CGPoint])
        /// `origin` is the top left corner of the first line of text.
        case text(String, origin: CGPoint, fontSize: CGFloat)
    }

    public var shape: Shape
    public var color: RGBAColor
    /// Stroke width in points (ignored for text; the marker uses its own width).
    public var lineWidth: CGFloat

    public init(shape: Shape, color: RGBAColor, lineWidth: CGFloat) {
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }
}

/// Fixed look of the tools.
public enum AnnotationStyle {
    public static let lineWidth: CGFloat = 3
    public static let markerWidth: CGFloat = 16
    public static let markerAlpha: Double = 0.4
    public static let textFontSize: CGFloat = 18
    public static let textFontName = "Helvetica-Bold"
}

/// The finished annotations with undo.
public struct AnnotationStack: Equatable, Sendable {
    public private(set) var items: [Annotation] = []

    public init() {}

    public var canUndo: Bool { fatalError("stub") }

    public mutating func add(_ annotation: Annotation) {
        fatalError("stub")
    }

    /// Removes the last annotation; false when there was nothing to undo.
    @discardableResult
    public mutating func undo() -> Bool {
        fatalError("stub")
    }

    public mutating func clear() {
        fatalError("stub")
    }
}

/// Builds one annotation from a mouse gesture: begin on mouse down, update on
/// every drag, finish on mouse up. Not used for text.
public struct AnnotationGesture: Equatable, Sendable {
    public let tool: Tool
    public let color: RGBAColor

    /// `tool` must not be .text.
    public init(tool: Tool, color: RGBAColor, start: CGPoint) {
        fatalError("stub")
    }

    /// `clip` is the selection: points outside are clamped to it, so nothing
    /// is drawn beyond the screenshot.
    public mutating func update(to point: CGPoint, clip: CGRect) {
        fatalError("stub")
    }

    /// The annotation as it looks right now, for the live preview.
    public var preview: Annotation? { fatalError("stub") }

    /// The finished annotation; nil when the mouse did not really move (a
    /// click), so that stray clicks leave no dots.
    public func finish() -> Annotation? {
        fatalError("stub")
    }
}

public enum AnnotationRenderer {
    /// Draws the annotations into a context whose user space IS overlay space:
    /// origin top left, y down, one unit is one point (a flipped NSView's
    /// context, or a bitmap context prepared by ImageComposer). Text must come
    /// out upright in such a flipped context.
    public static func draw(_ annotations: [Annotation], in context: CGContext) {
        fatalError("stub")
    }

    /// The size a text annotation takes, for placing the caret and the editor.
    public static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        fatalError("stub")
    }
}

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
        fatalError("stub")
    }

    /// The image resampled to one pixel per point (high quality interpolation),
    /// for the "save Retina screenshots at half size" setting. With scale <= 1
    /// the image is returned as it is.
    public static func downscaled(_ image: CGImage, fromScale scale: CGFloat) throws -> CGImage {
        fatalError("stub")
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
        fatalError("stub")
    }
}
