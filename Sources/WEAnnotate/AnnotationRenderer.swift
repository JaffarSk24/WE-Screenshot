import CoreGraphics
import CoreText
import Foundation
import WECore

public enum AnnotationRenderer {
    /// Draws the annotations into a context whose user space IS overlay space:
    /// origin top left, y down, one unit is one point (a flipped NSView's
    /// context, or a bitmap context prepared by ImageComposer). Text must come
    /// out upright in such a flipped context.
    public static func draw(_ annotations: [Annotation], in context: CGContext) {
        for annotation in annotations {
            context.saveGState()
            drawOne(annotation, in: context)
            context.restoreGState()
        }
    }

    /// The size a text annotation takes, for placing the caret and the editor.
    public static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let font = makeFont(size: fontSize)
        let lineHeight = lineHeight(of: font)
        var width: CGFloat = 0
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            width = max(width, ctLine(line, font: font, color: nil).width)
        }
        return CGSize(width: ceil(width), height: ceil(lineHeight * CGFloat(lines.count)))
    }

    // MARK: Shapes

    private static func drawOne(_ a: Annotation, in ctx: CGContext) {
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        let color = a.color.cgColor
        switch a.shape {
        case .pencil(let points):
            stroke(path: freehandPath(points), color: color, width: a.lineWidth, cap: .round, join: .round, in: ctx)
        case .marker(let points):
            // One path, one stroke: overlaps within the stroke do not darken.
            stroke(path: freehandPath(points), color: color, width: a.lineWidth, cap: .round, join: .round, in: ctx)
        case .line(let from, let to):
            let path = CGMutablePath()
            path.move(to: from)
            path.addLine(to: to)
            stroke(path: path, color: color, width: a.lineWidth, cap: .round, join: .round, in: ctx)
        case .arrow(let from, let to):
            drawArrow(from: from, to: to, color: color, width: a.lineWidth, in: ctx)
        case .rectangle(let rect):
            let path = CGMutablePath()
            path.addRect(rect)
            stroke(path: path, color: color, width: a.lineWidth, cap: .butt, join: .miter, in: ctx)
        case .text(let string, let origin, let fontSize):
            drawText(string, origin: origin, fontSize: fontSize, color: color, in: ctx)
        }
    }

    private static func stroke(path: CGPath, color: CGColor, width: CGFloat, cap: CGLineCap, join: CGLineJoin,
                               in ctx: CGContext) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.setLineJoin(join)
        ctx.addPath(path)
        ctx.strokePath()
    }

    /// Quadratic curves through the midpoints of consecutive points.
    private static func freehandPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first) // a round cap turns this into a dot
            return path
        }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat, in ctx: CGContext) {
        let dx = to.x - from.x, dy = to.y - from.y
        let distance = hypot(dx, dy)
        guard distance > 0.01 else { return }
        let ux = dx / distance, uy = dy / distance
        // The head shrinks when the arrow is shorter than it.
        let headLength = min(max(12, 4.5 * width), distance)
        let headWidth = headLength * 0.9
        let baseX = to.x - ux * headLength, baseY = to.y - uy * headLength
        // The shaft stops inside the head so its round cap cannot poke out of the tip.
        let shaftEnd = CGPoint(x: to.x - ux * headLength * 0.7, y: to.y - uy * headLength * 0.7)
        // Shaft and head overlap, so a translucent colour is painted once into a
        // transparency layer at full alpha and the layer is composited at the colour alpha.
        let alpha = color.alpha
        let translucent = alpha < 1
        let solid = translucent ? (color.copy(alpha: 1) ?? color) : color
        if translucent {
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if hypot(shaftEnd.x - from.x, shaftEnd.y - from.y) > 0.01 {
            let shaft = CGMutablePath()
            shaft.move(to: from)
            shaft.addLine(to: shaftEnd)
            stroke(path: shaft, color: solid, width: width, cap: .round, join: .round, in: ctx)
        }
        let nx = -uy, ny = ux
        let head = CGMutablePath()
        head.move(to: to)
        head.addLine(to: CGPoint(x: baseX + nx * headWidth / 2, y: baseY + ny * headWidth / 2))
        head.addLine(to: CGPoint(x: baseX - nx * headWidth / 2, y: baseY - ny * headWidth / 2))
        head.closeSubpath()
        ctx.setFillColor(solid)
        ctx.addPath(head)
        ctx.fillPath()
        if translucent { ctx.endTransparencyLayer() }
    }

    // MARK: Text

    private static func makeFont(size: CGFloat) -> CTFont {
        let font = CTFontCreateWithName(AnnotationStyle.textFontName as CFString, size, nil)
        let name = CTFontCopyPostScriptName(font) as String
        if name.caseInsensitiveCompare(AnnotationStyle.textFontName) == .orderedSame { return font }
        return CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? font
    }

    private static func lineHeight(of font: CTFont) -> CGFloat {
        CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    private static func ctLine(_ text: String, font: CTFont, color: CGColor?) -> (line: CTLine, width: CGFloat) {
        var attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font]
        if let color { attributes[.init(kCTForegroundColorAttributeName as String)] = color }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return (line, CGFloat(width))
    }

    private static func drawText(_ text: String, origin: CGPoint, fontSize: CGFloat, color: CGColor,
                                 in ctx: CGContext) {
        let font = makeFont(size: fontSize)
        let ascent = CTFontGetAscent(font)
        let height = lineHeight(of: font)
        // The text matrix (and text position) is not part of the graphics state,
        // so put it back for the caller.
        let savedMatrix = ctx.textMatrix
        defer { ctx.textMatrix = savedMatrix }
        // Flip locally: the context is y down, glyphs are y up.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in text.components(separatedBy: "\n").enumerated() where !line.isEmpty {
            let ct = ctLine(line, font: font, color: color).line
            ctx.textPosition = CGPoint(x: origin.x, y: origin.y + CGFloat(index) * height + ascent)
            CTLineDraw(ct, ctx)
        }
    }
}
