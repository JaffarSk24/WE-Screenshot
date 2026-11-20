import CoreGraphics
import Foundation

// CONTRACT STUB. The public declarations are fixed; the bodies are placeholders.
//
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
    /// The area the selection must stay in: (0, 0, display width, display height).
    public let bounds: CGRect
    /// The current selection, normalised (positive size) and inside bounds;
    /// nil when nothing is selected. During a drag it is updated live.
    public private(set) var rect: CGRect?
    /// True between begin...() and endDrag().
    public private(set) var isDragging: Bool = false

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    /// What is under the point. Handles win over the inside; a handle answers
    /// within `tolerance` points around its centre. With no selection: .outside.
    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> SelectionHit {
        fatalError("stub")
    }

    /// Centres of the eight handles of the current selection (empty when none).
    public func handleCenters() -> [SelectionHandle: CGPoint] {
        fatalError("stub")
    }

    /// Starts a new selection at the point (clamped to bounds); the old one is dropped.
    public mutating func beginCreate(at point: CGPoint) {
        fatalError("stub")
    }

    /// Starts moving the whole selection; the grab offset is kept during the drag.
    public mutating func beginMove(at point: CGPoint) {
        fatalError("stub")
    }

    /// Starts resizing by a handle. Dragging past the opposite edge flips the
    /// rectangle (the handle follows the mouse) instead of stopping.
    public mutating func beginResize(_ handle: SelectionHandle, at point: CGPoint) {
        fatalError("stub")
    }

    /// Continues the gesture started by one of the begin...() calls. The
    /// selection never leaves bounds: a move stops at the edges keeping its
    /// size, create and resize clamp the dragged corner.
    public mutating func drag(to point: CGPoint) {
        fatalError("stub")
    }

    /// Ends the gesture. A created selection smaller than 2 x 2 points (a plain
    /// click) is removed: rect becomes nil. Coordinates are rounded to whole points.
    public mutating func endDrag() {
        fatalError("stub")
    }

    /// Moves the selection by whole points, stopping at the bounds (arrow keys).
    public mutating func nudge(dx: CGFloat, dy: CGFloat) {
        fatalError("stub")
    }

    /// Grows or shrinks the selection from its bottom right corner (Shift+arrows);
    /// never smaller than 1 x 1, never outside bounds.
    public mutating func resize(dw: CGFloat, dh: CGFloat) {
        fatalError("stub")
    }

    /// Selects the whole display.
    public mutating func selectAll() {
        fatalError("stub")
    }

    public mutating func clear() {
        fatalError("stub")
    }
}

public enum ScreenGeometry {
    /// The crop rectangle, in pixels of the display snapshot (origin top left),
    /// for a selection given in overlay space. The result has whole pixel
    /// coordinates, is at least 1 x 1 and lies inside (0, 0, imageWidth, imageHeight).
    public static func pixelRect(selection: CGRect, scale: CGFloat, imageWidth: Int, imageHeight: Int) -> CGRect {
        fatalError("stub")
    }

    /// Converts a global AppKit point (origin bottom left of the primary
    /// display, y up) to overlay space of the display with this AppKit frame.
    public static func overlayPoint(fromGlobal point: CGPoint, displayFrame: CGRect) -> CGPoint {
        fatalError("stub")
    }

    /// The text of the size badge: pixel size of the selection, like "1280x720".
    public static func sizeLabel(selection: CGRect, scale: CGFloat) -> String {
        fatalError("stub")
    }

    /// Where to put a panel of `size` next to the selection so that it stays
    /// inside bounds (overlay space). `preferred` lists placements to try in order.
    public static func panelOrigin(size: CGSize, selection: CGRect, bounds: CGRect,
                                   preferred: [PanelPlacement], gap: CGFloat) -> CGPoint {
        fatalError("stub")
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
