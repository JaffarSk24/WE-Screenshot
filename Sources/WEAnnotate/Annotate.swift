import CoreGraphics
import Foundation
import WECore

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
