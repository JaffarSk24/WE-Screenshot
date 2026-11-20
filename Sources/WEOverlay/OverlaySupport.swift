import AppKit
import CoreText
import WEAnnotate
import WECore

// Small pieces shared by the overlay: brand colours, key mapping, cursors,
// panel placement and the text metrics that keep the editor and the renderer
// in agreement.

enum OverlayStyle {
    static let panelBackground = NSColor(srgbRed: 0x37 / 255, green: 0x41 / 255, blue: 0x61 / 255, alpha: 0.97)
    static let panelBorder = NSColor(srgbRed: 0x45 / 255, green: 0x50 / 255, blue: 0x73 / 255, alpha: 1)
    static let accent = NSColor(srgbRed: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255, alpha: 1)
    static let darkBlue = CGColor(srgbRed: 0x37 / 255, green: 0x41 / 255, blue: 0x61 / 255, alpha: 1)
    static let dimColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
    static let badgeBackground = NSColor(srgbRed: 0.08, green: 0.10, blue: 0.16, alpha: 0.88)

    static let handleSize: CGFloat = 7
    static let handleTolerance: CGFloat = 6
    static let panelGap: CGFloat = 8
}

/// What a key press means to the overlay when no text is being edited.
enum KeyCommand: Equatable {
    case cancel
    case action(ScreenshotAction)
    case undo
    case selectAll
    case nudge(dx: CGFloat, dy: CGFloat)
    case resize(dw: CGFloat, dh: CGFloat)

    // ANSI positions, used when the layout does not produce a Latin letter
    // (for example a Cyrillic layout), so the shortcuts still work.
    private static let ansiLetters: [UInt16: String] = [0: "a", 1: "s", 2: "d", 6: "z", 7: "x", 8: "c", 9: "v", 35: "p"]

    /// The Latin letter of a shortcut key: the typed character when it is a
    /// Latin letter, otherwise the letter at that ANSI position. Shared with
    /// the text editor so both resolve shortcuts the same way.
    static func shortcutLetter(keyCode: UInt16, characters: String?) -> String {
        let letter = characters?.lowercased() ?? ""
        let isLatin = letter.count == 1 && letter.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 122 }
        return isLatin ? letter : (ansiLetters[keyCode] ?? "")
    }

    static func from(event: NSEvent) -> KeyCommand? {
        guard event.type == .keyDown else { return nil }
        return from(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                    modifiers: event.modifierFlags)
    }

    static func from(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> KeyCommand? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        switch keyCode {
        case 53:
            return .cancel
        case 123, 124, 125, 126:
            guard !flags.contains(.command), !flags.contains(.control) else { return nil }
            let step: CGFloat = flags.contains(.option) ? 10 : 1
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch keyCode {
            case 123: dx = -step
            case 124: dx = step
            case 125: dy = step
            default: dy = -step
            }
            return flags.contains(.shift) ? .resize(dw: dx, dh: dy) : .nudge(dx: dx, dy: dy)
        default:
            break
        }
        guard flags == [.command] else { return nil }
        switch shortcutLetter(keyCode: keyCode, characters: characters) {
        case "x": return .cancel
        case "c": return .action(.copy)
        case "s": return .action(.quickSave)
        case "d": return .action(.upload)
        case "p": return .action(.print)
        case "z": return .undo
        case "a": return .selectAll
        default: return nil
        }
    }
}

enum CursorKind: Equatable {
    case arrow, crosshair, openHand, closedHand, iBeam
    case resize(SelectionHandle)

    var name: String {
        switch self {
        case .arrow: return "arrow"
        case .crosshair: return "crosshair"
        case .openHand: return "openHand"
        case .closedHand: return "closedHand"
        case .iBeam: return "iBeam"
        case .resize(let handle): return "resize-\(handle)"
        }
    }

    @MainActor
    var cursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .crosshair: return .crosshair
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case .iBeam: return .iBeam
        case .resize(let handle):
            switch handle {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .topLeft, .bottomRight: return DiagonalCursors.fallingDiagonal
            case .topRight, .bottomLeft: return DiagonalCursors.risingDiagonal
            }
        }
    }
}

/// The system has no public diagonal resize cursors before macOS 15, so the
/// two are drawn here: a double arrow with a dark outline.
@MainActor
enum DiagonalCursors {
    /// From top left to bottom right.
    static let fallingDiagonal = make(rising: false)
    /// From bottom left to top right.
    static let risingDiagonal = make(rising: true)

    private static func make(rising: Bool) -> NSCursor {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let a = rising ? CGPoint(x: 3, y: 15) : CGPoint(x: 3, y: 3)
            let b = rising ? CGPoint(x: 15, y: 3) : CGPoint(x: 15, y: 15)
            func arrowPath() -> NSBezierPath {
                let path = NSBezierPath()
                path.move(to: a)
                path.line(to: b)
                for (tip, other) in [(a, b), (b, a)] {
                    let dx = other.x - tip.x, dy = other.y - tip.y
                    let length = hypot(dx, dy)
                    let ux = dx / length, uy = dy / length
                    let base = CGPoint(x: tip.x + ux * 5, y: tip.y + uy * 5)
                    path.move(to: CGPoint(x: base.x - uy * 4, y: base.y + ux * 4))
                    path.line(to: tip)
                    path.line(to: CGPoint(x: base.x + uy * 4, y: base.y - ux * 4))
                }
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                return path
            }
            let outline = arrowPath()
            outline.lineWidth = 4
            NSColor.white.setStroke()
            outline.stroke()
            let line = arrowPath()
            line.lineWidth = 1.6
            NSColor.black.setStroke()
            line.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }
}

enum OverlayLayout {
    /// Frames of the tools panel and the actions panel for a selection, in
    /// overlay space. The two never overlap: when the preferred places
    /// collide (small selections, selections filling the display) the actions
    /// panel moves next to the tools panel.
    static func panelFrames(toolsSize: CGSize, actionsSize: CGSize, selection: CGRect,
                            bounds: CGRect) -> (tools: CGRect, actions: CGRect) {
        let gap = OverlayStyle.panelGap
        let toolsOrigin = ScreenGeometry.panelOrigin(size: toolsSize, selection: selection, bounds: bounds,
                                                     preferred: [.rightOutside, .leftOutside, .rightInside],
                                                     gap: gap)
        let actionsOrigin = ScreenGeometry.panelOrigin(size: actionsSize, selection: selection, bounds: bounds,
                                                       preferred: [.belowOutside, .aboveOutside, .bottomInside],
                                                       gap: gap)
        let tools = CGRect(origin: toolsOrigin, size: toolsSize)
        let actions = CGRect(origin: actionsOrigin, size: actionsSize)
        if !tooClose(tools, actions, gap: gap) { return (tools, actions) }

        let candidates = [
            CGPoint(x: tools.minX - gap - actionsSize.width, y: actions.minY),
            CGPoint(x: tools.minX - gap - actionsSize.width, y: tools.maxY - actionsSize.height),
            CGPoint(x: tools.maxX - actionsSize.width, y: tools.maxY + gap),
            CGPoint(x: tools.maxX - actionsSize.width, y: tools.minY - gap - actionsSize.height),
            CGPoint(x: tools.maxX + gap, y: actions.minY),
        ]
        for origin in candidates {
            let frame = CGRect(origin: origin, size: actionsSize)
            if fits(frame, in: bounds) && !tooClose(tools, frame, gap: gap) { return (tools, frame) }
        }
        return (tools, actions)
    }

    private static func tooClose(_ a: CGRect, _ b: CGRect, gap: CGFloat) -> Bool {
        a.insetBy(dx: -gap / 2 + 0.01, dy: -gap / 2 + 0.01).intersects(b.insetBy(dx: -gap / 2 + 0.01, dy: -gap / 2 + 0.01))
    }

    private static func fits(_ frame: CGRect, in bounds: CGRect) -> Bool {
        frame.minX >= bounds.minX - 0.001 && frame.minY >= bounds.minY - 0.001
            && frame.maxX <= bounds.maxX + 0.001 && frame.maxY <= bounds.maxY + 0.001
    }

    /// The size badge sits just above the top left corner, or inside the
    /// selection when there is no room above.
    static func badgeFrame(size: CGSize, selection: CGRect, bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: selection.minX, y: selection.minY - 4 - size.height)
        if origin.y < bounds.minY { origin = CGPoint(x: selection.minX + 4, y: selection.minY + 4) }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }

    /// The area that differs between two consecutive states of a drawing in
    /// progress. A freehand stroke only changes at its end: adding a point
    /// turns the last straight piece into a curve that starts half a segment
    /// before the previous point, so the last three points cover it. Redrawing
    /// the whole stroke's bounds instead gets slower with every point.
    static func changedBounds(from previous: Annotation?, to annotation: Annotation) -> CGRect {
        let old = previous.map(paintBounds(of:)) ?? .null
        switch (previous?.shape, annotation.shape) {
        case (.pencil(let before)?, .pencil(let after)), (.marker(let before)?, .marker(let after)):
            guard !before.isEmpty, after.count >= before.count, let first = after.suffix(3).first else { break }
            var rect = CGRect(origin: first, size: .zero)
            for p in after.suffix(2) { rect = rect.union(CGRect(origin: p, size: .zero)) }
            let extra = annotation.lineWidth / 2 + 2
            return rect.insetBy(dx: -extra, dy: -extra)
        default:
            break
        }
        return old.union(paintBounds(of: annotation))
    }

    /// The area an annotation can paint, for partial redraws of the preview.
    static func paintBounds(of annotation: Annotation) -> CGRect {
        let points: [CGPoint]
        var extra = annotation.lineWidth / 2 + 2
        switch annotation.shape {
        case .pencil(let p), .marker(let p): points = p
        case .line(let a, let b): points = [a, b]
        case .arrow(let a, let b):
            points = [a, b]
            extra += max(12, 4.5 * annotation.lineWidth)
        case .rectangle(let r): points = [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
        case .text(let string, let origin, let size):
            return CGRect(origin: origin, size: AnnotationRenderer.textSize(string, fontSize: size)).insetBy(dx: -2, dy: -2)
        }
        guard let first = points.first else { return .null }
        var rect = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { rect = rect.union(CGRect(origin: p, size: .zero)) }
        return rect.insetBy(dx: -extra, dy: -extra)
    }
}

/// The font of the text tool, resolved the same way as AnnotationRenderer.
enum TextMetrics {
    static var fontSize: CGFloat { AnnotationStyle.textFontSize }

    static var font: NSFont {
        if let font = NSFont(name: AnnotationStyle.textFontName, size: fontSize) { return font }
        return NSFont.boldSystemFont(ofSize: fontSize)
    }

    /// Line height as AnnotationRenderer computes it (ascent + descent + leading).
    static var lineHeight: CGFloat {
        let ct = font as CTFont
        return CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)
    }
}

extension RGBAColor {
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? NSColor.red
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent),
                  blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

/// Lets plain closures receive target-action messages and notifications.
@MainActor
final class SelectorTarget: NSObject {
    private let handler: @MainActor (Any?) -> Void

    init(_ handler: @escaping @MainActor (Any?) -> Void) {
        self.handler = handler
    }

    @objc func fire(_ sender: Any?) {
        handler(sender)
    }
}
