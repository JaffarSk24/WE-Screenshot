import AppKit
import WEAnnotate
import WECore

/// The state and the rules of one screenshot session across all displays.
/// It needs no window: the overlay views call it with plain points in
/// overlay space, and the harness does the same off screen.
///
/// Only one display holds a selection at a time, and the annotations belong
/// to that display. The session never closes anything itself: it reports
/// the user's decision through `onFinish`, once.
@MainActor
final class OverlaySession: NSObject {
    enum DragKind { case none, selection, drawing }

    /// What a mouse down outside the selection replaced, to put it back when
    /// it turns out to be a plain click instead of a new selection.
    private struct Stash {
        let index: Int?
        let selection: SelectionModel?
        let annotations: AnnotationStack
    }

    let settings: SettingsStore
    private(set) var views: [OverlayView] = []
    private(set) var tool: Tool?
    private(set) var color: RGBAColor
    private(set) var annotations = AnnotationStack()
    /// The display that holds the selection.
    private(set) var activeIndex: Int?
    private(set) var dragKind: DragKind = .none
    private(set) var isMoving = false
    private var dragIndex = 0
    private var gesture: AnnotationGesture?
    private var stash: Stash?
    private(set) var editor: AnnotationTextView?
    private var editorIndex = 0
    /// The display under the mouse, for Command-A.
    var mouseIndex = 0
    private(set) var isFinished = false

    /// The user picked an action (or nil: cancelled). Called at most once.
    var onFinish: ((ScreenshotAction?) -> Void)?
    var onColorButton: (() -> Void)?
    var beep: () -> Void = { NSSound.beep() }

    init(settings: SettingsStore, snapshots: [DisplaySnapshot]) {
        self.settings = settings
        self.color = settings.drawingColor
        super.init()
        views = snapshots.enumerated().map { OverlayView(index: $0.offset, snapshot: $0.element, session: self) }
        refreshAll()
    }

    var activeRect: CGRect? {
        guard let activeIndex else { return nil }
        return views[activeIndex].selection.rect
    }

    func refreshAll() {
        for view in views { view.refresh() }
    }

    // MARK: Mouse

    func mouseDown(display index: Int, at point: CGPoint) {
        guard !isFinished, views.indices.contains(index), dragKind == .none else { return }
        mouseIndex = index
        // Clicking anywhere outside the editor commits the text being edited.
        if editor != nil { commitText() }
        let view = views[index]
        let hit = activeIndex == index
            ? view.selection.hitTest(point, tolerance: OverlayStyle.handleTolerance)
            : .outside
        dragIndex = index
        switch hit {
        case .handle(let handle):
            view.selection.beginResize(handle, at: point)
            dragKind = .selection
        case .inside:
            if let tool {
                if tool == .text {
                    beginText(display: index, at: point)
                } else {
                    let start = clamp(point, to: view.selection.rect ?? view.selection.bounds)
                    let newGesture = AnnotationGesture(tool: tool, color: color, start: start)
                    gesture = newGesture
                    dragKind = .drawing
                    view.showPreview(newGesture.preview)
                }
            } else {
                view.selection.beginMove(at: point)
                dragKind = .selection
                isMoving = true
            }
        case .outside:
            stash = Stash(index: activeIndex, selection: activeIndex.map { views[$0].selection },
                          annotations: annotations)
            for other in views where other.index != index { other.selection.clear() }
            annotations.clear()
            activeIndex = index
            view.selection.beginCreate(at: point)
            dragKind = .selection
        }
        refreshAll()
    }

    func mouseDragged(to point: CGPoint) {
        guard !isFinished else { return }
        let view = views[dragIndex]
        switch dragKind {
        case .selection:
            view.selection.drag(to: point)
            view.refresh()
        case .drawing:
            guard var current = gesture, let rect = view.selection.rect else { return }
            current.update(to: point, clip: rect)
            gesture = current
            view.showPreview(current.preview)
        case .none:
            break
        }
    }

    func mouseUp(at point: CGPoint) {
        guard !isFinished else { return }
        let view = views[dragIndex]
        switch dragKind {
        case .selection:
            view.selection.drag(to: point)
            view.selection.endDrag()
            if view.selection.rect == nil {
                if let stash, let index = stash.index, let model = stash.selection {
                    views[index].selection = model
                    annotations = stash.annotations
                    activeIndex = index
                } else if activeIndex == dragIndex {
                    activeIndex = nil
                }
            }
            stash = nil
        case .drawing:
            if var current = gesture, let rect = view.selection.rect {
                current.update(to: point, clip: rect)
                if let annotation = current.finish() { annotations.add(annotation) }
            }
            gesture = nil
            view.showPreview(nil)
        case .none:
            break
        }
        dragKind = .none
        isMoving = false
        refreshAll()
    }

    func cursor(display index: Int, at point: CGPoint) -> CursorKind {
        guard views.indices.contains(index) else { return .arrow }
        let view = views[index]
        if dragKind == .selection && isMoving { return .closedHand }
        if view.panelsContain(point) { return .arrow }
        guard activeIndex == index, dragKind != .selection else { return .crosshair }
        switch view.selection.hitTest(point, tolerance: OverlayStyle.handleTolerance) {
        case .handle(let handle): return .resize(handle)
        case .inside:
            guard let tool else { return .openHand }
            return tool == .text ? .iBeam : .crosshair
        case .outside: return .crosshair
        }
    }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    // MARK: Keys and buttons

    /// Runs a keyboard command. Returns false when the overlay does not take
    /// keys right now (a text is being edited, or the session is over).
    @discardableResult
    func perform(_ command: KeyCommand) -> Bool {
        guard !isFinished, editor == nil else { return false }
        switch command {
        case .cancel:
            finish(nil)
        case .action(let action):
            requestAction(action)
        case .undo:
            guard dragKind == .none else { return true }
            undo()
        case .selectAll:
            selectAll(display: mouseIndex)
        case .nudge(let dx, let dy):
            guard dragKind == .none, let index = activeIndex, views[index].selection.rect != nil else {
                beep()
                return true
            }
            views[index].selection.nudge(dx: dx, dy: dy)
            views[index].refresh()
        case .resize(let dw, let dh):
            guard dragKind == .none, let index = activeIndex, views[index].selection.rect != nil else {
                beep()
                return true
            }
            views[index].selection.resize(dw: dw, dh: dh)
            views[index].refresh()
        }
        return true
    }

    func press(_ item: ToolbarItem) {
        guard !isFinished, dragKind == .none else { return }
        switch item {
        case .tool(let picked):
            commitText()
            tool = tool == picked ? nil : picked
            refreshAll()
            views.forEach { $0.updateCursorFromMouse() }
        case .color:
            onColorButton?()
        case .undo:
            commitText()
            undo()
        case .action(let action):
            requestAction(action)
        case .close:
            finish(nil)
        }
    }

    private func undo() {
        if annotations.undo() {
            refreshAll()
        } else {
            beep()
        }
    }

    func selectAll(display index: Int) {
        guard !isFinished, dragKind == .none, views.indices.contains(index) else { return }
        commitText()
        if activeIndex != index {
            // A selection on another display is a new selection.
            for view in views { view.selection.clear() }
            annotations.clear()
            activeIndex = index
        }
        views[index].selection.selectAll()
        refreshAll()
    }

    func setColor(_ newColor: RGBAColor) {
        guard !isFinished, newColor != color else { return }
        color = newColor
        settings.drawingColor = newColor
        editor?.apply(color: newColor)
        refreshAll()
    }

    func requestAction(_ action: ScreenshotAction) {
        guard !isFinished else { return }
        guard dragKind == .none, activeRect != nil else {
            beep()
            return
        }
        commitText()
        finish(action)
    }

    func finish(_ action: ScreenshotAction?) {
        guard !isFinished else { return }
        isFinished = true
        let handler = onFinish
        onFinish = nil
        onColorButton = nil
        handler?(action)
    }

    /// The final picture for the display that holds the selection; nil when
    /// there is no selection or composing fails.
    func makeResult(action: ScreenshotAction) -> OverlayResult? {
        guard let index = activeIndex, let rect = views[index].selection.rect else { return nil }
        let snapshot = views[index].snapshot
        guard let image = try? ImageComposer.compose(snapshot: snapshot, selection: rect,
                                                     annotations: annotations.items) else { return nil }
        return OverlayResult(action: action, screenshot: FinishedScreenshot(image: image, scale: snapshot.display.scale))
    }

    // MARK: Text

    private func beginText(display index: Int, at point: CGPoint) {
        guard let rect = views[index].selection.rect else { return }
        let lineHeight = TextMetrics.lineHeight
        // The caret is centred on the click, but the box starts inside the selection.
        var origin = CGPoint(x: point.x, y: point.y - lineHeight / 2)
        origin.y = max(rect.minY, min(origin.y, rect.maxY - lineHeight))
        origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        let textView = AnnotationTextView.make(origin: origin, color: color)
        textView.onCommit = { [weak self] in self?.commitText() }
        textView.onCancel = { [weak self] in self?.discardText() }
        editor = textView
        editorIndex = index
        views[index].installEditor(textView)
        views[index].window?.makeFirstResponder(textView)
    }

    /// Turns the text being edited into an annotation (nothing when empty).
    func commitText() {
        guard let textView = editor else { return }
        let text = textView.normalizedText
        let origin = textView.frame.origin
        removeEditor()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.add(Annotation(shape: .text(text, origin: origin, fontSize: TextMetrics.fontSize),
                                       color: color, lineWidth: AnnotationStyle.lineWidth))
        }
        refreshAll()
    }

    /// Escape in the editor: drops only the text being edited.
    func discardText() {
        guard editor != nil else { return }
        removeEditor()
        refreshAll()
    }

    private func removeEditor() {
        guard let textView = editor else { return }
        editor = nil
        let view = views[editorIndex]
        textView.removeFromSuperview()
        if let window = view.window { window.makeFirstResponder(view) }
    }

    /// Ends the session for good: drops the editor and every reference to the views' content.
    func invalidate() {
        isFinished = true
        onFinish = nil
        onColorButton = nil
        if let textView = editor {
            editor = nil
            textView.removeFromSuperview()
        }
    }
}
