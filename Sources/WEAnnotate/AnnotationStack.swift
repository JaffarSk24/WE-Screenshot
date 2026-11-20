import CoreGraphics
import Foundation
import WECore

/// The finished annotations with undo.
public struct AnnotationStack: Equatable, Sendable {
    public private(set) var items: [Annotation] = []

    public init() {}

    public var canUndo: Bool { !items.isEmpty }

    public mutating func add(_ annotation: Annotation) {
        items.append(annotation)
    }

    /// Removes the last annotation; false when there was nothing to undo.
    @discardableResult
    public mutating func undo() -> Bool {
        guard !items.isEmpty else { return false }
        items.removeLast()
        return true
    }

    public mutating func clear() {
        items.removeAll()
    }
}

/// Builds one annotation from a mouse gesture: begin on mouse down, update on
/// every drag, finish on mouse up. Not used for text.
public struct AnnotationGesture: Equatable, Sendable {
    public let tool: Tool
    public let color: RGBAColor

    private let start: CGPoint
    private var current: CGPoint
    /// Collected points for the freehand tools.
    private var points: [CGPoint]

    /// `tool` must not be .text.
    public init(tool: Tool, color: RGBAColor, start: CGPoint) {
        precondition(tool != .text, "text is not drawn with a gesture")
        self.tool = tool
        self.color = color
        self.start = start
        self.current = start
        self.points = [start]
    }

    /// `clip` is the selection: points outside are clamped to it, so nothing
    /// is drawn beyond the screenshot.
    public mutating func update(to point: CGPoint, clip: CGRect) {
        let p = Self.clamp(point, to: clip)
        current = p
        switch tool {
        case .pencil, .marker:
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 0.5 { return }
            points.append(p)
        default:
            break
        }
    }

    /// The annotation as it looks right now, for the live preview.
    public var preview: Annotation? { build() }

    /// The finished annotation; nil when the mouse did not really move (a
    /// click), so that stray clicks leave no dots.
    public func finish() -> Annotation? {
        switch tool {
        case .pencil, .marker:
            let xs = points.map { $0.x }, ys = points.map { $0.y }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
                  max(maxX - minX, maxY - minY) >= 2 else { return nil }
        default:
            guard hypot(current.x - start.x, current.y - start.y) > 2 else { return nil }
        }
        return build()
    }

    private func build() -> Annotation? {
        switch tool {
        case .pencil:
            return Annotation(shape: .pencil(points: points), color: color, lineWidth: AnnotationStyle.lineWidth)
        case .marker:
            return Annotation(shape: .marker(points: points),
                              color: color.withAlpha(AnnotationStyle.markerAlpha),
                              lineWidth: AnnotationStyle.markerWidth)
        case .line:
            return Annotation(shape: .line(from: start, to: current), color: color,
                              lineWidth: AnnotationStyle.lineWidth)
        case .arrow:
            return Annotation(shape: .arrow(from: start, to: current), color: color,
                              lineWidth: AnnotationStyle.lineWidth)
        case .rectangle:
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            return Annotation(shape: .rectangle(rect), color: color, lineWidth: AnnotationStyle.lineWidth)
        case .text:
            return nil
        }
    }

    private static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }
}
