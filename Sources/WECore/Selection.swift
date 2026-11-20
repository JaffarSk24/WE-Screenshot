import CoreGraphics
import Foundation

// Coordinate space ("overlay space") used by the whole selection and drawing
// code: points, origin at the TOP LEFT corner of one display, y grows DOWN.
// The overlay view is flipped, so view coordinates are overlay space.

public enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

public enum SelectionHit: Equatable, Sendable {
    case outside
    case inside
    case handle(SelectionHandle)
}

/// The selection rectangle and the mouse gestures that change it. Pure logic,
/// no AppKit: the overlay view forwards mouse and key events here and redraws.
public struct SelectionModel: Equatable, Sendable {
    private enum Gesture: Equatable, Sendable {
        case create(anchor: CGPoint)
        case move(offset: CGSize, size: CGSize)
        case resize(handle: SelectionHandle, original: CGRect)
    }

    /// The area the selection must stay in: (0, 0, display width, display height).
    public let bounds: CGRect
    /// The current selection, normalised (positive size) and inside bounds;
    /// nil when nothing is selected. During a drag it is updated live.
    public private(set) var rect: CGRect?
    /// True between begin...() and endDrag().
    public private(set) var isDragging: Bool = false

    private var gesture: Gesture?

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// What is under the point. Handles win over the inside; a handle answers
    /// within `tolerance` points around its centre. With no selection: .outside.
    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> SelectionHit {
        guard let rect else { return .outside }
        var best: (handle: SelectionHandle, distance: CGFloat)?
        for handle in SelectionHandle.allCases {
            let center = SelectionModel.center(of: handle, in: rect)
            let distance = max(abs(point.x - center.x), abs(point.y - center.y))
            if distance <= tolerance, best == nil || distance < best!.distance {
                best = (handle, distance)
            }
        }
        if let best { return .handle(best.handle) }
        let inside = point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
        return inside ? .inside : .outside
    }

    private static func center(of handle: SelectionHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Centres of the eight handles of the current selection (empty when none).
    public func handleCenters() -> [SelectionHandle: CGPoint] {
        guard let rect else { return [:] }
        var result: [SelectionHandle: CGPoint] = [:]
        for handle in SelectionHandle.allCases {
            result[handle] = SelectionModel.center(of: handle, in: rect)
        }
        return result
    }

    /// Starts a new selection at the point (clamped to bounds); the old one is dropped.
    public mutating func beginCreate(at point: CGPoint) {
        let start = clamp(point)
        gesture = .create(anchor: start)
        rect = CGRect(origin: start, size: .zero)
        isDragging = true
    }

    /// Starts moving the whole selection; the grab offset is kept during the drag.
    public mutating func beginMove(at point: CGPoint) {
        guard let rect else { return }
        gesture = .move(offset: CGSize(width: point.x - rect.minX, height: point.y - rect.minY), size: rect.size)
        isDragging = true
    }

    /// Starts resizing by a handle. Dragging past the opposite edge flips the
    /// rectangle (the handle follows the mouse) instead of stopping.
    public mutating func beginResize(_ handle: SelectionHandle, at point: CGPoint) {
        guard let rect else { return }
        gesture = .resize(handle: handle, original: rect)
        isDragging = true
    }

    /// Continues the gesture started by one of the begin...() calls. The
    /// selection never leaves bounds: a move stops at the edges keeping its
    /// size, create and resize clamp the dragged corner.
    public mutating func drag(to point: CGPoint) {
        guard let gesture else { return }
        switch gesture {
        case .create(let anchor):
            let p = clamp(point)
            rect = SelectionModel.normalised(anchor, p)
        case .move(let offset, let size):
            let x = min(max(point.x - offset.width, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
            let y = min(max(point.y - offset.height, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
            rect = CGRect(origin: CGPoint(x: x, y: y), size: size)
        case .resize(let handle, let original):
            let p = clamp(point)
            var left = original.minX, right = original.maxX
            var top = original.minY, bottom = original.maxY
            switch handle {
            case .topLeft, .left, .bottomLeft: left = p.x; right = original.maxX
            case .topRight, .right, .bottomRight: left = original.minX; right = p.x
            case .top, .bottom: break
            }
            switch handle {
            case .topLeft, .top, .topRight: top = p.y; bottom = original.maxY
            case .bottomLeft, .bottom, .bottomRight: top = original.minY; bottom = p.y
            case .left, .right: break
            }
            rect = SelectionModel.normalised(CGPoint(x: left, y: top), CGPoint(x: right, y: bottom))
        }
    }

    private static func normalised(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Ends the gesture. A created selection smaller than 2 x 2 points (a plain
    /// click) is removed: rect becomes nil. Coordinates are rounded to whole points.
    public mutating func endDrag() {
        defer {
            gesture = nil
            isDragging = false
        }
        guard let gesture, let current = rect else { return }
        if case .create = gesture, current.width < 2 || current.height < 2 {
            rect = nil
            return
        }
        let w = min(max(1, current.width.rounded()), bounds.width)
        let h = min(max(1, current.height.rounded()), bounds.height)
        let x = min(max(current.minX.rounded(), bounds.minX), bounds.maxX - w)
        let y = min(max(current.minY.rounded(), bounds.minY), bounds.maxY - h)
        rect = CGRect(x: x, y: y, width: w, height: h)
    }

    /// Moves the selection by whole points, stopping at the bounds (arrow keys).
    public mutating func nudge(dx: CGFloat, dy: CGFloat) {
        guard let current = rect else { return }
        let x = min(max(current.minX + dx, bounds.minX), max(bounds.minX, bounds.maxX - current.width))
        let y = min(max(current.minY + dy, bounds.minY), max(bounds.minY, bounds.maxY - current.height))
        rect = CGRect(x: x, y: y, width: current.width, height: current.height)
    }

    /// Grows or shrinks the selection from its bottom right corner (Shift+arrows);
    /// never smaller than 1 x 1, never outside bounds.
    public mutating func resize(dw: CGFloat, dh: CGFloat) {
        guard let current = rect else { return }
        let w = min(max(1, current.width + dw), max(1, bounds.maxX - current.minX))
        let h = min(max(1, current.height + dh), max(1, bounds.maxY - current.minY))
        rect = CGRect(x: current.minX, y: current.minY, width: w, height: h)
    }

    /// Selects the whole display.
    public mutating func selectAll() {
        rect = bounds
        gesture = nil
        isDragging = false
    }

    public mutating func clear() {
        rect = nil
        gesture = nil
        isDragging = false
    }
}

public enum ScreenGeometry {
    /// The crop rectangle, in pixels of the display snapshot (origin top left),
    /// for a selection given in overlay space. The result has whole pixel
    /// coordinates, is at least 1 x 1 and lies inside (0, 0, imageWidth, imageHeight).
    public static func pixelRect(selection: CGRect, scale: CGFloat, imageWidth: Int, imageHeight: Int) -> CGRect {
        func lower(_ v: CGFloat) -> CGFloat {
            abs(v - v.rounded()) < 0.01 ? v.rounded() : v.rounded(.down)
        }
        func upper(_ v: CGFloat) -> CGFloat {
            abs(v - v.rounded()) < 0.01 ? v.rounded() : v.rounded(.up)
        }
        let maxW = CGFloat(max(1, imageWidth))
        let maxH = CGFloat(max(1, imageHeight))
        let x0 = min(max(lower(selection.minX * scale), 0), maxW - 1)
        let y0 = min(max(lower(selection.minY * scale), 0), maxH - 1)
        let x1 = min(max(upper(selection.maxX * scale), x0 + 1), maxW)
        let y1 = min(max(upper(selection.maxY * scale), y0 + 1), maxH)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Converts a global AppKit point (origin bottom left of the primary
    /// display, y up) to overlay space of the display with this AppKit frame.
    public static func overlayPoint(fromGlobal point: CGPoint, displayFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - displayFrame.minX, y: displayFrame.maxY - point.y)
    }

    /// The text of the size badge: pixel size of the selection, like "1280x720".
    public static func sizeLabel(selection: CGRect, scale: CGFloat) -> String {
        let w = Int((selection.width * scale).rounded())
        let h = Int((selection.height * scale).rounded())
        return "\(w)x\(h)"
    }

    /// Where to put a panel of `size` next to the selection so that it stays
    /// inside bounds (overlay space). `preferred` lists placements to try in order.
    public static func panelOrigin(size: CGSize, selection: CGRect, bounds: CGRect,
                                   preferred: [PanelPlacement], gap: CGFloat) -> CGPoint {
        func candidate(_ placement: PanelPlacement) -> CGPoint {
            switch placement {
            case .rightOutside:
                let y = min(selection.minY, bounds.maxY - size.height)
                return CGPoint(x: selection.maxX + gap, y: y)
            case .leftOutside:
                let y = min(selection.minY, bounds.maxY - size.height)
                return CGPoint(x: selection.minX - gap - size.width, y: y)
            case .belowOutside:
                let x = max(selection.maxX - size.width, bounds.minX)
                return CGPoint(x: x, y: selection.maxY + gap)
            case .aboveOutside:
                let x = max(selection.maxX - size.width, bounds.minX)
                return CGPoint(x: x, y: selection.minY - gap - size.height)
            case .rightInside:
                return CGPoint(x: selection.maxX - gap - size.width, y: selection.minY + gap)
            case .bottomInside:
                return CGPoint(x: selection.maxX - gap - size.width, y: selection.maxY - gap - size.height)
            }
        }
        func fits(_ origin: CGPoint) -> Bool {
            let eps: CGFloat = 0.001
            return origin.x >= bounds.minX - eps && origin.y >= bounds.minY - eps
                && origin.x + size.width <= bounds.maxX + eps && origin.y + size.height <= bounds.maxY + eps
        }
        func clamped(_ origin: CGPoint) -> CGPoint {
            CGPoint(x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                    y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
        }
        for placement in preferred {
            let origin = candidate(placement)
            if fits(origin) { return origin }
        }
        return clamped(candidate(preferred.last ?? .bottomInside))
    }
}

/// Where a toolbar sits relative to the selection.
public enum PanelPlacement: Sendable {
    /// Outside the right edge, top aligned.
    case rightOutside
    /// Outside the left edge, top aligned.
    case leftOutside
    /// Below the bottom edge, right aligned.
    case belowOutside
    /// Above the top edge, right aligned.
    case aboveOutside
    /// Inside the selection, at its right edge, top aligned.
    case rightInside
    /// Inside the selection, at its bottom edge, right aligned.
    case bottomInside
}
