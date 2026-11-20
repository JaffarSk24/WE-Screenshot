import AppKit
import QuartzCore
import WEAnnotate
import WECore

/// The content of one overlay window: the frozen picture of one display, the
/// dimming, the selection chrome, the drawings and the panels. It is flipped,
/// so view coordinates are overlay space. Events are turned into plain points
/// and passed to the session, which owns the logic.
///
/// Subviews from bottom to top: backdrop (snapshot and dimming layers), the
/// committed drawings, the live drawing, the selection border and handles,
/// the size badge, the text editor, the two panels.
@MainActor
final class OverlayView: NSView {
    let index: Int
    let snapshot: DisplaySnapshot
    weak var session: OverlaySession?
    var selection: SelectionModel

    private let backdrop: BackdropView
    private let committed = AnnotationsView()
    private let preview = AnnotationsView()
    private let chrome: ChromeView
    private let badge = BadgeView(frame: .zero)
    let toolsPanel: PanelView
    let actionsPanel: PanelView
    private var trackingArea: NSTrackingArea?

    init(index: Int, snapshot: DisplaySnapshot, session: OverlaySession) {
        self.index = index
        self.snapshot = snapshot
        self.session = session
        let size = snapshot.display.frame.size
        let bounds = CGRect(origin: .zero, size: size)
        selection = SelectionModel(bounds: bounds)
        backdrop = BackdropView(frame: bounds, image: snapshot.image, scale: snapshot.display.scale)
        chrome = ChromeView(frame: bounds, scale: snapshot.display.scale)
        let press: (ToolbarItem) -> Void = { [weak session] item in session?.press(item) }
        toolsPanel = PanelView(items: ToolbarItem.toolsPanel, axis: .vertical, onPress: press)
        actionsPanel = PanelView(items: ToolbarItem.actionsPanel, axis: .horizontal, onPress: press)
        super.init(frame: bounds)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        committed.frame = bounds
        committed.isHidden = true
        preview.isHidden = true
        for view in [backdrop, committed, preview, chrome, badge, toolsPanel, actionsPanel] as [NSView] {
            addSubview(view)
        }
        badge.isHidden = true
        toolsPanel.isHidden = true
        actionsPanel.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: State to screen

    /// Brings every layer and subview in line with the selection and the session.
    func refresh() {
        guard let session else { return }
        let rect = selection.rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.setHole(rect)
        chrome.setSelection(rect)
        CATransaction.commit()

        if let rect, rect.width > 0 || rect.height > 0 {
            let text = ScreenGeometry.sizeLabel(selection: rect, scale: snapshot.display.scale)
            badge.text = text
            badge.frame = OverlayLayout.badgeFrame(size: badge.fittingSize(for: text), selection: rect,
                                                   bounds: selection.bounds)
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }

        let items = session.activeIndex == index ? session.annotations.items : []
        if committed.annotations != items {
            committed.annotations = items
            committed.isHidden = items.isEmpty
            committed.needsDisplay = true
        }

        let showPanels = rect != nil && session.dragKind != .selection
        if showPanels, let rect {
            let frames = OverlayLayout.panelFrames(toolsSize: toolsPanel.frame.size,
                                                   actionsSize: actionsPanel.frame.size,
                                                   selection: rect, bounds: selection.bounds)
            toolsPanel.frame = frames.tools
            actionsPanel.frame = frames.actions
        }
        toolsPanel.isHidden = !showPanels
        actionsPanel.isHidden = !showPanels
        toolsPanel.update(tool: session.tool, color: session.color, canUndo: session.annotations.canUndo)
    }

    /// Shows the drawing in progress. Only the area it touches is redrawn.
    func showPreview(_ annotation: Annotation?) {
        let previous = preview.annotations.first
        guard let annotation, let rect = selection.rect else {
            preview.annotations = []
            preview.isHidden = true
            return
        }
        if preview.isHidden {
            // The live layer only covers the selection (plus room for strokes
            // and arrow heads), not the whole 5K display.
            let area = rect.insetBy(dx: -24, dy: -24).intersection(selection.bounds)
            preview.frame = area
            preview.offset = area.origin
            preview.isHidden = false
            preview.annotations = [annotation]
            preview.needsDisplay = true
            return
        }
        preview.annotations = [annotation]
        let dirty = OverlayLayout.changedBounds(from: previous, to: annotation)
        invalidatedPreviewArea += dirty.isNull ? 0 : dirty.width * dirty.height
        preview.setNeedsDisplay(dirty.offsetBy(dx: -preview.offset.x, dy: -preview.offset.y))
    }

    /// Total area marked dirty by live drawing updates, for the harness.
    var invalidatedPreviewArea: CGFloat = 0

    func installEditor(_ editor: NSView) {
        addSubview(editor, positioned: .below, relativeTo: toolsPanel)
    }

    func panelsContain(_ point: CGPoint) -> Bool {
        (!toolsPanel.isHidden && toolsPanel.frame.contains(point))
            || (!actionsPanel.isHidden && actionsPanel.frame.contains(point))
    }

    func button(_ item: ToolbarItem) -> PanelButton? {
        toolsPanel.buttons[item] ?? actionsPanel.buttons[item]
    }

    // MARK: Events

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        session?.mouseDown(display: index, at: p)
        updateCursor(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        session?.mouseDragged(to: point(event))
    }

    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        session?.mouseUp(at: p)
        updateCursor(at: p)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: point(event))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: point(event))
    }

    override func rightMouseDown(with event: NSEvent) {}

    func updateCursor(at p: CGPoint) {
        guard let session else { return }
        session.mouseIndex = index
        // The text editor sets its own I-beam over itself.
        if let editor = session.editor, editor.superview === self, editor.frame.contains(p) { return }
        session.cursor(display: index, at: p).cursor.set()
    }

    func updateCursorFromMouse() {
        guard let window else { return }
        updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func keyDown(with event: NSEvent) {
        if let session, let command = KeyCommand.from(event: event), session.perform(command) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While a text is edited the shortcuts belong to the editor.
        guard let session, session.editor == nil else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), let command = KeyCommand.from(event: event),
           session.perform(command) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = session?.perform(.cancel)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? snapshot.display.scale
        backdrop.setContentsScale(scale)
        chrome.setContentsScale(scale)
    }
}

/// The frozen picture and the dimming with the selection cut out. Both are
/// plain layers: moving the selection only changes the dimming path, the
/// snapshot bitmap is never redrawn.
@MainActor
final class BackdropView: NSView {
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()

    init(frame: CGRect, image: CGImage, scale: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let bounds = CGRect(origin: .zero, size: frame.size)
        imageLayer.frame = bounds
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.actions = OverlayLayers.noActions
        dimLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = OverlayStyle.dimColor
        dimLayer.actions = OverlayLayers.noActions
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(dimLayer)
        setContentsScale(scale)
        setHole(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setContentsScale(_ scale: CGFloat) {
        imageLayer.contentsScale = scale
        dimLayer.contentsScale = scale
    }

    func setHole(_ hole: CGRect?) {
        let path = CGMutablePath()
        path.addRect(dimLayer.bounds)
        if let hole, hole.width > 0, hole.height > 0 { path.addRect(hole) }
        dimLayer.path = path
    }
}

/// Selection border and the eight handles, as shape layers.
@MainActor
final class ChromeView: NSView {
    private let outline = CAShapeLayer()
    private let line = CAShapeLayer()
    private let handles = CAShapeLayer()

    init(frame: CGRect, scale: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let bounds = CGRect(origin: .zero, size: frame.size)
        for shape in [outline, line, handles] {
            shape.frame = bounds
            shape.actions = OverlayLayers.noActions
            layer?.addSublayer(shape)
        }
        outline.fillColor = nil
        outline.strokeColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)
        outline.lineWidth = 3
        line.fillColor = nil
        line.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        line.lineWidth = 1
        handles.fillColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        handles.strokeColor = OverlayStyle.darkBlue
        handles.lineWidth = 1
        setContentsScale(scale)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setContentsScale(_ scale: CGFloat) {
        for shape in [outline, line, handles] { shape.contentsScale = scale }
    }

    func setSelection(_ rect: CGRect?) {
        guard let rect, rect.width > 0 || rect.height > 0 else {
            outline.path = nil
            line.path = nil
            handles.path = nil
            return
        }
        // The border runs just outside the selection, so it never covers
        // pixels that end up in the screenshot.
        let border = CGPath(rect: rect.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        outline.path = border
        line.path = border
        let path = CGMutablePath()
        let size = OverlayStyle.handleSize
        let centers = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
        ]
        // Handles on a display edge are pushed inside, so they stay fully visible.
        let area = handles.bounds
        for center in centers {
            let x = min(max((center.x - size / 2).rounded(), area.minX), area.maxX - size)
            let y = min(max((center.y - size / 2).rounded(), area.minY), area.maxY - size)
            path.addRect(CGRect(x: x, y: y, width: size, height: size).insetBy(dx: 0.5, dy: 0.5))
        }
        handles.path = path
    }
}

/// Draws annotations through AnnotationRenderer. `offset` is the overlay
/// space point at the view's top left corner.
@MainActor
final class AnnotationsView: NSView {
    var annotations: [Annotation] = []
    var offset: CGPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !annotations.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: -offset.x, y: -offset.y)
        AnnotationRenderer.draw(annotations, in: ctx)
        ctx.restoreGState()
    }
}

enum OverlayLayers {
    /// Assigned to every hand made layer so that nothing animates implicitly.
    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(),
        "contents": NSNull(), "hidden": NSNull(), "opacity": NSNull(), "contentsScale": NSNull(),
        "fillColor": NSNull(), "strokeColor": NSNull(),
    ]
}
